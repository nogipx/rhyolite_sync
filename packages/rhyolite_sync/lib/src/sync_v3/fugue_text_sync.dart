import 'package:convergent/fugue.dart';
import 'package:diff_match_patch/diff_match_patch.dart';

/// Translates a plain-text snapshot into Fugue insert/remove ops
/// against an existing [Fugue] tree.
///
/// The intended call site is `_onFileChanged`: Obsidian saves the
/// whole file every time, so the engine sees a fresh byte buffer
/// with no clue about which characters the user actually touched.
/// We reconstruct the edit by diffing the new text against the
/// projection of the locally-held [Fugue], then apply each diff
/// chunk as CRDT operations. The diff library stays **local** —
/// its output is converted to commutative CRDT ops, never shipped
/// as patches, so the asymmetric `patchApply` failure modes that
/// plagued the old resolver cannot recur here.
///
/// Element dots are minted from the device's global [LamportClock]
/// (owned by `FileStateStore`). A logical counter — not an [Hlc] —
/// is what lets a typed run coalesce into one Fugue block.
class FugueTextSync {
  const FugueTextSync._();

  /// Builds a [Fugue] representing initial plain text — content that
  /// has no prior CRDT history known to this device. Used whenever the
  /// engine encounters a file's bytes without a cached or pulled
  /// [Fugue] to diff against (first sync, post-wipe recovery,
  /// upgrade from a pre-Fugue plain-text blob).
  ///
  /// DETERMINISTIC by construction. The same [text] input always
  /// produces a byte-identical [Fugue], regardless of which device
  /// runs it or when. This is the convergence guarantee that prevents
  /// content duplication when two devices independently first-seed
  /// the same file: their two trees merge cleanly because they
  /// already ARE the same tree. Without it, a later CRDT `join`
  /// (which `_resolveTextConflict` performs whenever both devices
  /// push concurrently) would see two disjoint causal histories of
  /// identical content and concatenate them — the file's projection
  /// would become `text + text`.
  ///
  /// Real subsequent edits authored under a device's actual dots
  /// (via [observeDots] + the Lamport clock) strictly dominate this
  /// seed, so attribution is preserved for everything except the
  /// initial bytes. The whole forward run is exactly ONE block
  /// (replica `seed`, counters `1..N`, right children of the root).
  static Fugue<String> seedFromText(String text) {
    if (text.isEmpty) return Fugue<String>();
    final chars = [for (final r in text.runes) String.fromCharCode(r)];
    return Fugue.fromRawBlocks<String>([
      (Dot(1, _seedReplica), Dot.origin, Side.right, chars, const <int>[]),
    ]);
  }

  // Wire-format constant for [seedFromText]. PRIVATE on purpose —
  // exposing it as a parameter is what permitted the post-wipe
  // content-duplication bug: any caller could pass its own deviceId,
  // produce a tree with disjoint causal history, and break
  // cross-device convergence. The value is an opaque token; only its
  // stability across releases matters. Treat any change as a protocol
  // break.
  static const String _seedReplica = 'seed';

  /// Wall-clock deadline (seconds) for the local snapshot diff. Past this,
  /// diff_match_patch returns a VALID but non-minimal edit script instead of
  /// running Myers to completion — bounding the worst-case UI freeze on a
  /// large offline divergence. Crucially the result stays a real edit script
  /// (a deletion remains a tombstone), so a concurrent merge never resurrects
  /// deleted text. Matches the library's own default; tunable.
  static const double _diffDeadlineSeconds = 1.0;

  /// Returns a [Fugue] whose projection equals [newText].
  ///
  /// When [oldFugue] already projects to [newText], the **same
  /// instance** is returned (no allocations) — callers rely on
  /// `identical(result, oldFugue)` as the "nothing changed" signal.
  /// When the text changed, a fresh (cloned + mutated) instance is
  /// returned and [oldFugue] is left untouched.
  ///
  /// The caller MUST have folded [oldFugue]'s dots into [clock] via
  /// `store.observeDots(oldFugue.dots)` before calling: that lifts the
  /// clock above every counter already in the file, so each dot minted
  /// here strictly dominates existing content (skew-safety, and no dot
  /// reuse within the tree).
  ///
  /// Convergence guarantee: peers running this method on the same
  /// `(oldFugue, newText)` pair author under their own device dots, so
  /// blobs differ across devices. Convergence is restored when peers
  /// pull each other's trees and `join`.
  static Future<Fugue<String>> applyTextSnapshot({
    required Fugue<String> oldFugue,
    required String newText,
    required LamportClock clock,
    double deadlineSeconds = _diffDeadlineSeconds,
  }) async {
    // Yield before the projection — `oldFugue.values.join()` walks
    // every live element on the main thread (10-300ms on a large tree).
    // Without this yield a back-to-back reconcile of many files freezes
    // Obsidian visibly even when each individual projection is "fast".
    await Future<void>.delayed(Duration.zero);
    final oldText = oldFugue.values.join();
    if (oldText == newText) return oldFugue;

    // Fast path: [oldFugue] holds no elements at all (live or tombstoned)
    // → this device has no prior CRDT history for the file. Delegate to
    // [seedFromText] — both for performance (O(N) bulk build vs an
    // append-loop) and for the convergence discipline that lives there
    // (deterministic dots so two devices independently first-seeding the
    // same text produce identical trees and don't double on join).
    //
    // Guard on [elementCount], not [isEmpty]: a fully-deleted file has
    // tombstone blocks (isEmpty but elementCount > 0) whose causal
    // history must be preserved, so it takes the diff path below.
    if (oldFugue.elementCount == 0 && newText.isNotEmpty) {
      return seedFromText(newText);
    }

    // Yield before the synchronous diff call itself. diff() and
    // cleanupSemantic() are both unbroken main-thread compute; the
    // yield gives Obsidian's UI a tick to render before the next burst.
    await Future<void>.delayed(Duration.zero);
    // diff_match_patch is Myers' O((M+N)·D); a huge offline divergence would
    // otherwise pin the dart2js thread for tens of seconds. We bound it with
    // the library's own deadline ([_diffDeadlineSeconds]): past that it
    // returns a valid (non-minimal) diff rather than running to completion.
    //
    // This REPLACED an earlier hard cost cap that reseeded from disk on a big
    // divergence — that dropped the tree's tombstones, so a deletion became a
    // shorter fresh seed and a concurrent char-join could resurrect deleted
    // text. A deadline-bounded diff keeps the result a real edit script (a
    // deletion stays a tombstone), so the merge honours it.
    //
    // checklines:true runs a line-level pass first, then char-level only
    // inside changed line groups — 10-100x faster on line-oriented text. A
    // non-minimal (deadline-truncated) diff is fine here: each device authors
    // under its own dots, so convergence comes from join, not from the diff
    // being identical across peers.
    final diffs = diff(
      oldText,
      newText,
      checklines: true,
      timeout: deadlineSeconds,
    );
    await Future<void>.delayed(Duration.zero);
    cleanupSemantic(diffs);

    // Translate the diff into a single Fugue.applyOps batch. Applying the
    // whole batch mints consecutive counters, so a forward-typed run
    // coalesces into one block. We mutate a CLONE, not [oldFugue], so the
    // caller's `identical` check still distinguishes "changed" (a fresh
    // instance) from "unchanged" (the same instance returned above).
    final ops = <FugueOp<String>>[];
    var idx = 0;
    for (final d in diffs) {
      switch (d.operation) {
        case DIFF_EQUAL:
          idx += d.text.runes.length;
        case DIFF_DELETE:
          final count = d.text.runes.length;
          for (var i = 0; i < count; i++) {
            ops.add(FugueOp.removeAt(idx));
          }
        case DIFF_INSERT:
          for (final rune in d.text.runes) {
            ops.add(FugueOp.insert(idx, String.fromCharCode(rune)));
            idx += 1;
          }
      }
    }
    await Future<void>.delayed(Duration.zero);
    final next = oldFugue.clone();
    next.applyOps(ops, clock);
    return next;
  }
}
