import 'package:convergent/convergent.dart';
import 'package:diff_match_patch/diff_match_patch.dart';

/// Translates a plain-text snapshot into Fugue insert/remove ops
/// against an existing [Sequence].
///
/// The intended call site is `_onFileChanged`: Obsidian saves the
/// whole file every time, so the engine sees a fresh byte buffer
/// with no clue about which characters the user actually touched.
/// We reconstruct the edit by diffing the new text against the
/// projection of the locally-held Sequence, then apply each diff
/// chunk as CRDT operations. The diff library stays **local** —
/// its output is converted to commutative CRDT ops, never shipped
/// as patches, so the asymmetric `patchApply` failure modes that
/// plagued the old resolver cannot recur here.
///
/// HLC dots are minted via [nextHlc] for every emitted insert; the
/// caller (usually `FileStateStore`) supplies a monotonic clock.
class FugueTextSync {
  const FugueTextSync._();

  /// Builds a [Sequence] representing initial plain text — content that
  /// has no prior CRDT history known to this device. Used whenever the
  /// engine encounters a file's bytes without a cached or pulled
  /// [Sequence] to diff against (first sync, post-wipe recovery,
  /// upgrade from a pre-Fugue plain-text blob).
  ///
  /// DETERMINISTIC by construction. The same [text] input always
  /// produces a byte-identical [Sequence], regardless of which device
  /// runs it or when. This is the convergence guarantee that prevents
  /// content duplication when two devices independently first-seed
  /// the same file: their two Sequences merge cleanly because they
  /// already ARE the same Sequence. Without it, a later CRDT `join`
  /// (which `_resolveTextConflict` performs whenever both devices
  /// push concurrently) would see two disjoint causal histories of
  /// identical content and concatenate them — the file's projection
  /// would become `text + text`.
  ///
  /// Real subsequent edits authored under a device's actual [Hlc]
  /// strictly dominate this seed in HLC order, so attribution is
  /// preserved for everything except the initial bytes.
  ///
  /// O(N) build via [Sequence.fromRaw]; sub-100ms on dart2js for
  /// multi-thousand-character notes.
  static Sequence<String> seedFromText(String text) {
    if (text.isEmpty) return Sequence<String>.empty();
    final entries = <Hlc, SeqEntry<String>>{};
    Hlc? prevDot;
    var counter = 0;
    for (final rune in text.runes) {
      counter += 1;
      final dot = Hlc(_seedMillis, counter, _seedNodeId);
      entries[dot] = SeqEntry<String>(
        id: dot,
        parent: prevDot,
        side: SequenceSide.right,
        value: String.fromCharCode(rune),
      );
      prevDot = dot;
    }
    return Sequence<String>.fromRaw(entries);
  }

  // Wire-format constants for [seedFromText]. PRIVATE on purpose —
  // exposing them as parameters is what permitted the post-wipe
  // content-duplication bug: any caller could pass its own deviceId,
  // produce a Sequence with disjoint causal history, and break
  // cross-device convergence. The values are opaque tokens; only
  // their stability across releases matters. Treat any change as a
  // protocol break.
  static const String _seedNodeId = 'seed';
  static const int _seedMillis = 0;

  /// Returns a new [Sequence] whose projection equals [newText].
  /// When [oldSequence] already projects to [newText], the same
  /// instance is returned (no allocations).
  ///
  /// Convergence guarantee: peers running this method on the same
  /// `(oldSequence, newText)` pair produce **byte-identical** ops on
  /// the same dots — but in real use each peer authors under its
  /// own deviceId, so blobs differ across devices. Convergence is
  /// restored when peers pull each other's Sequences and `join`.
  static Future<Sequence<String>> applyTextSnapshot({
    required Sequence<String> oldSequence,
    required String newText,
    required Hlc Function() nextHlc,
  }) async {
    // Yield before the projection — `oldSequence.values.join()` walks
    // every entry on the main thread (10-300ms on a multi-thousand-
    // entry Sequence). Without this yield a back-to-back reconcile of
    // many files freezes Obsidian visibly even when each individual
    // projection is "fast".
    await Future<void>.delayed(Duration.zero);
    final oldText = oldSequence.values.join();
    if (oldText == newText) return oldSequence;

    // Fast path: empty [oldSequence] means this device has no prior
    // CRDT history for the file. Delegate to [seedFromText] — both
    // for performance (O(N) bulk build vs O(N log N) append-loop) and
    // for the convergence discipline that lives there (deterministic
    // dots so two devices independently first-seeding the same text
    // produce identical Sequences and don't double on join).
    if (oldSequence.entries.isEmpty && newText.isNotEmpty) {
      return seedFromText(newText);
    }

    // Hard cap on diff cost. diff_match_patch is Myers' O((M+N)·D)
    // where D is the edit distance, and on dart2js the constants are
    // brutal — a 8k↔13k char divergence (~95M ops) pins the JS thread
    // for tens of seconds with no yield window. Above this threshold
    // we reseed from the disk text and accept losing CRDT history for
    // this file. Other devices that pulled the same disk content
    // converge by [seedFromText]'s deterministic-dot discipline; the
    // only loss is per-character attribution, not data.
    //
    // Threshold tuned so common edits (typing a paragraph, pasting a
    // few lines) stay on the diff path; full file rewrites and large
    // offline-edit windows fall over to the seed path.
    const diffCostBudget = 5_000_000;
    final lenDelta = (newText.length - oldText.length).abs();
    final diffCost = (oldText.length + newText.length) * lenDelta;
    if (diffCost > diffCostBudget) {
      return seedFromText(newText);
    }

    // Yield before the synchronous diff call itself. diff() and
    // cleanupSemantic() are both unbroken main-thread compute; the
    // yield gives Obsidian's UI a tick to render before the next burst.
    await Future<void>.delayed(Duration.zero);
    // checklines:true is the library's default — runs Myers over lines
    // first, then char-level only inside changed line groups. For
    // line-oriented texts (markdown, fountain, source code) this is
    // 10-100x faster than char-level Myers over the whole text.
    // Prose where the user typed inside a paragraph still falls back to
    // char-level diff on that paragraph alone, not the whole file.
    final diffs = diff(oldText, newText, checklines: true);
    await Future<void>.delayed(Duration.zero);
    cleanupSemantic(diffs);

    // Translate the diff into a single Sequence.applyOps batch. The
    // per-op loop used to materialise a fresh Sequence on every char
    // (drip pattern) — on dart2js that scaled as O(K · N log N) and
    // hung the UI for over a minute on 23k-char files. applyOps does
    // the whole batch with one O(N) Map copy + O(N + K) resolve, which
    // turns the same workload into tens of milliseconds.
    final ops = <SeqOp<String>>[];
    var idx = 0;
    for (final d in diffs) {
      switch (d.operation) {
        case DIFF_EQUAL:
          idx += d.text.runes.length;
        case DIFF_DELETE:
          final count = d.text.runes.length;
          for (var i = 0; i < count; i++) {
            ops.add(SeqOp.removeAt(idx));
          }
        case DIFF_INSERT:
          for (final rune in d.text.runes) {
            ops.add(SeqOp.insert(idx, String.fromCharCode(rune)));
            idx += 1;
          }
      }
    }
    await Future<void>.delayed(Duration.zero);
    return oldSequence.applyOps(ops, nextHlc);
  }
}
