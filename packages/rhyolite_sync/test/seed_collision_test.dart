import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_text_sync.dart';
import 'package:rhyolite_sync/src/sync_v3/remote_applier.dart';
import 'package:test/test.dart';

/// Locks the invariant `RemoteApplier.sharesGenuineHistory` guards: two
/// independently-seeded DIVERGENT versions of the same file must NOT be
/// char-joined. `seedFromText` is deterministic on the `seed` replica, so two
/// devices that first-seed the same fileId with different content reuse the
/// same `Dot(k, "seed")` positions for different characters — a "seed
/// collision". Joining such trees would corrupt (convergent's merge guard
/// catches it in checked mode; in release it silently mixes runs). The
/// resolver detects the collision and renders a union view instead of joining.
void main() {
  // Mirrors DiskReconciler._reconcileText: fold the file's own dots into the
  // clock (so each fresh dot dominates existing content), THEN apply.
  Future<Fugue<String>> applyText(
    Fugue<String> old,
    String text,
    String device,
  ) {
    final clk = LamportClock(device)..observeAll(old.dots);
    return FugueTextSync.applyTextSnapshot(
      oldFugue: old,
      newText: text,
      clock: clk,
    );
  }

  group('seed collision — divergent independent seeds must not char-join', () {
    test('two independent seeds of the same file are NOT genuine history', () {
      // Two devices FIRST-seed the same fileId with DIFFERENT content, having
      // never synced. Deterministic seeding reuses Dot(1,"seed"),
      // Dot(2,"seed")… on both, but with different chars — a collision on a
      // shared dot whose value differs. That is the exact signal the guard
      // uses to refuse a char-join and render a union view instead. (A naive
      // join here would be lossy and non-commutative — which is precisely why
      // the resolver must never reach it.)
      final a = FugueTextSync.seedFromText('alpha');
      final b = FugueTextSync.seedFromText('bravo');
      expect(RemoteApplier.sharesGenuineHistory([a, b]), isFalse);
    });

    test('edits off a common synced seed DO share genuine history', () async {
      // Both devices share a synced base, then edit concurrently. Their trees
      // share the base seed dots with identical values → genuine history →
      // a char-level Fugue join is lossless and safe.
      final base = FugueTextSync.seedFromText('hello world');
      final a = await applyText(base.clone(), 'hello brave world', 'A');
      final b = await applyText(base.clone(), 'hello world!', 'B');

      expect(RemoteApplier.sharesGenuineHistory([a, b]), isTrue);
      expect(a.join(b), b.join(a)); // converges both orders, no assert
    });

    test('prefix-compatible independent seeds are joinable (no false conflict)',
        () {
      // Edge: one seed is a prefix of the other. Same-dot values agree over the
      // overlap, so the join is prefix-compatible and lossless — the guard must
      // NOT flag this as a divergent conflict.
      final a = FugueTextSync.seedFromText('ab');
      final b = FugueTextSync.seedFromText('abc');
      expect(RemoteApplier.sharesGenuineHistory([a, b]), isTrue);
      expect(a.join(b).values.join(), 'abc');
    });

    test('disjoint trees (no shared dot) are not genuine history', () {
      // Real per-device dots never collide across devices, so two trees with no
      // shared dot have no common base — also not char-joinable as "history".
      final a = FugueTextSync.seedFromText('alpha'); // seed replica
      final b = Fugue<String>()..insert(0, 'z', const Dot(1, 'deviceB'));
      expect(RemoteApplier.sharesGenuineHistory([a, b]), isFalse);
    });
  });
}