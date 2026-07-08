import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_store.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_text_sync.dart';
import 'package:test/test.dart';

void main() {
  // A per-device Lamport clock. In production `FileStateStore` owns one of
  // these; here each test device gets its own.
  LamportClock clockOf(String node) => LamportClock(node);

  // Mirrors what `DiskReconciler._reconcileText` does on every edit: fold the
  // file's own dots into the clock (so the fresh dot dominates), THEN apply.
  Future<Fugue<String>> applyText(
    Fugue<String> old,
    String text,
    LamportClock clk,
  ) {
    clk.observeAll(old.dots);
    return FugueTextSync.applyTextSnapshot(
      oldFugue: old,
      newText: text,
      clock: clk,
    );
  }

  Fugue<String> seed(String text) => FugueTextSync.seedFromText(text);

  // "Byte-identical" is checked through the deterministic wire codec — Fugue
  // (unlike the old Sequence) intentionally has no value `==`.
  Matcher bytesOf(Fugue<String> f) =>
      equals(FugueStore.encodeBlob(f).toList());
  List<int> bytes(Fugue<String> f) => FugueStore.encodeBlob(f).toList();

  group('FugueTextSync.seedFromText', () {
    test('projection round-trips the original text', () {
      final seq = seed('hello, world');
      expect(seq.values.join(), 'hello, world');
      expect(seq.length, 'hello, world'.length);
    });

    test('is a single coalesced block', () {
      final seq = seed('hello, world');
      expect(seq.blockCount, 1, reason: 'a forward run must be one block');
    });

    test('preserves unicode codepoints across the rune iterator', () {
      const txt = 'тест ✓ ok';
      final seq = seed(txt);
      expect(seq.values.join(), txt);
    });

    test('empty text produces empty tree', () {
      final seq = seed('');
      expect(seq.length, 0);
      expect(seq.values, isEmpty);
      expect(seq.elementCount, 0);
    });

    // The convergence guarantee that makes [seedFromText] safe to call
    // independently on multiple devices. If this regresses, two devices
    // first-seeding the same file produce divergent trees and a later CRDT
    // `join` doubles the on-disk content (the post-wipe duplication
    // regression).
    test('same input → byte-identical tree (cross-device convergence)', () {
      const txt = 'some shared content that two devices see identically';
      final a = seed(txt);
      final b = seed(txt);
      expect(bytes(a), bytesOf(b));
      expect(bytes(a.join(b)), bytesOf(a)); // join is a no-op
      expect(a.join(b).values.join(), txt);
    });
  });

  group('FugueTextSync.applyTextSnapshot — basic edits', () {
    test('identical text is a no-op (returns same instance)', () async {
      final s = seed('hello');
      final after = await applyText(s, 'hello', clockOf('A'));
      expect(identical(after, s), isTrue);
    });

    test('a real edit returns a fresh instance (not the same object)',
        () async {
      final s = seed('hello');
      final after = await applyText(s, 'hellp', clockOf('A'));
      expect(identical(after, s), isFalse,
          reason: 'a changed tree must be a new instance for the identical() '
              'short-circuit in the reconciler to work');
    });

    test('insert into empty', () async {
      final after = await applyText(Fugue<String>(), 'hello', clockOf('A'));
      expect(after.values.join(), 'hello');
    });

    test('delete to empty keeps tombstone history', () async {
      final after = await applyText(seed('hello'), '', clockOf('A'));
      expect(after.values.join(), '');
      expect(after.length, 0);
      expect(after.elementCount, greaterThan(0),
          reason: 'tombstones remain so the delete converges with peers');
    });

    test('append at tail', () async {
      final after = await applyText(seed('hello'), 'hello world', clockOf('A'));
      expect(after.values.join(), 'hello world');
    });

    test('prepend at head', () async {
      final after = await applyText(seed('world'), 'hello world', clockOf('A'));
      expect(after.values.join(), 'hello world');
    });

    test('replace single character mid-string', () async {
      final after = await applyText(seed('hello'), 'hellp', clockOf('A'));
      expect(after.values.join(), 'hellp');
    });

    test('replace a word with a different one', () async {
      final after =
          await applyText(seed('hello world'), 'hello there', clockOf('A'));
      expect(after.values.join(), 'hello there');
    });

    test('delete a middle slice', () async {
      final after = await applyText(
          seed('hello beautiful world'), 'hello world', clockOf('A'));
      expect(after.values.join(), 'hello world');
    });
  });

  group('FugueTextSync.applyTextSnapshot — unicode', () {
    test('cyrillic edit', () async {
      final after =
          await applyText(seed('привет'), 'привет, мир', clockOf('A'));
      expect(after.values.join(), 'привет, мир');
    });

    test('emoji insertion (surrogate-pair codepoint)', () async {
      final after = await applyText(seed('done '), 'done 🚀', clockOf('A'));
      expect(after.values.join(), 'done 🚀');
    });
  });

  group('FugueTextSync.applyTextSnapshot — incremental sessions', () {
    test('many sequential edits each round-trip cleanly', () async {
      final clk = clockOf('A');
      var s = Fugue<String>();
      const snapshots = [
        'h', 'he', 'hel', 'hell', 'hello', 'hello!', 'hello world',
        'hello world!', 'hello there world!', 'hello there world',
        'hi there world',
      ];
      for (final snap in snapshots) {
        s = await applyText(s, snap, clk);
        expect(s.values.join(), snap,
            reason: 'projection diverges after snapshot=$snap');
      }
    });

    test('tombstones survive the diff loop without affecting projection',
        () async {
      final clk = clockOf('A');
      var s = seed('hello world');
      s = await applyText(s, 'hello', clk);
      s = await applyText(s, 'hi', clk);
      expect(s.values.join(), 'hi');
      // Structure must still carry enough metadata to converge with a peer
      // that hasn't seen the deletions yet.
      expect(s.elementCount, greaterThan(2));
    });

    test('a whole-file reconcile round-trips through the binary codec',
        () async {
      const text = '# Title\n\nA paragraph, then another line.\nDone.';
      final clk = clockOf('A');
      final tree = await applyText(Fugue<String>(), text, clk);
      // The projection is the disk text…
      expect(tree.values.join(), text);
      // …and it survives a serialize → deserialize round-trip unchanged.
      final restored = FugueStore.tryDecodeBlob(FugueStore.encodeBlob(tree));
      expect(restored, isNotNull);
      expect(restored!.values.join(), text);
    });
  });

  group('FugueTextSync.applyTextSnapshot — clock dominance (observe)', () {
    // Port of the skew test. An edit authored against peer-ahead content must
    // land at the requested visible index. `observe` is what makes the fresh
    // dot dominate the (higher-counter) existing content; without it the
    // insert can be misordered across the tree.
    test('edit against peer-ahead content lands at the requested index',
        () async {
      // Peer B seeded + typed a lot, so its dots carry high counters.
      final peer = clockOf('B');
      var remote = await applyText(Fugue<String>(), 'abcdef', peer);
      for (var i = 0; i < 50; i++) {
        remote = await applyText(remote, 'abcdef${'!' * (i + 1)}', peer);
      }
      // Local device pulls that tree and inserts 'X' at index 3.
      final local = clockOf('A');
      local.observeAll(remote.dots);
      final before = remote.values.join();
      final target = '${before.substring(0, 3)}X${before.substring(3)}';
      final edited = await FugueTextSync.applyTextSnapshot(
        oldFugue: remote,
        newText: target,
        clock: local,
      );
      expect(edited.values.join(), target,
          reason: 'the inserted char must land exactly at index 3');
      // The minted dot must dominate everything it was inserted next to.
      final maxExisting =
          remote.dots.map((d) => d.counter).fold<int>(0, (a, b) => a > b ? a : b);
      expect(local.value, greaterThan(maxExisting),
          reason: 'observe must lift the clock above peer-ahead counters');
    });
  });

  group('FugueTextSync.applyTextSnapshot — large offline edit', () {
    // Regression: the old hard diff-cost budget reseeded from disk on a big
    // divergence, which dropped the tree's tombstones. A deletion then
    // became "a shorter fresh seed" instead of a tombstone, and a concurrent
    // char-join resurrected the deleted text. A deadline-bounded diff keeps
    // the deletion as a real tombstone, so the merge honours it.
    test('a large deletion stays a tombstone and is not resurrected on merge',
        () async {
      // Big enough to have tripped the old budget ((old+new)*|Δlen| > 5e6):
      // 4000 -> 2000 chars ≈ 12e6.
      final baseText = 'x' * 2000 + 'y' * 2000;
      final base = seed(baseText); // peer B keeps this untouched
      // Device A deletes the whole 'y' half offline.
      final a = await applyText(base.clone(), 'x' * 2000, clockOf('A'));
      expect(a.values.join(), 'x' * 2000);
      // Merging A's deletion with B's untouched copy must keep it deleted.
      expect(a.join(base).values.join(), 'x' * 2000,
          reason: 'a large deletion must survive the merge, not resurrect');
    });

    test('a large edit still round-trips to the new text', () async {
      final base = seed('a' * 3000);
      final after = await applyText(base.clone(), 'b' * 50, clockOf('A'));
      expect(after.values.join(), 'b' * 50);
    });
  });

  group('FugueTextSync.applyTextSnapshot — convergence', () {
    test('two devices typing concurrently on top of a shared base merge',
        () async {
      final base = seed('hello world');
      final a = await applyText(base.clone(), 'hello beautiful world',
          clockOf('A'));
      final b = await applyText(base.clone(), 'hello world!', clockOf('B'));
      final merged = a.join(b);
      final out = merged.values.join();
      expect(out.contains('hello'), isTrue);
      expect(out.contains('beautiful'), isTrue);
      expect(out.contains('world'), isTrue);
      expect(out.contains('!'), isTrue);
      // Symmetric merge produces the same projection.
      expect(b.join(a).values.join(), out);
    });

    // Regression guard: the content-duplication bug observed on local-DB wipe
    // (2026-06-04). Two devices independently first-seed the SAME plain text
    // after wiping. Both go through the empty-oldFugue fast path. If it minted
    // device-local dots, the two trees would have disjoint histories and a
    // later `join` would concatenate them (`text + text`). The fix routes the
    // empty case through the deterministic [seedFromText].
    test(
      'two devices independently first-seeding the same text converge '
      '(regression: post-wipe content duplication)',
      () async {
        const text =
            '# Заметка\n\nКонтент который существует на обоих устройствах '
            'одинаково. Если CRDT не сходится, после wipe всё удвоится.';
        final a = await applyText(Fugue<String>(), text, clockOf('A'));
        final b = await applyText(Fugue<String>(), text, clockOf('B'));

        // Independent seeds of identical text must be byte-identical.
        expect(bytes(a), bytesOf(b),
            reason: 'independent first-seeds of the same text must produce '
                'identical trees (otherwise the join below duplicates)');

        // The user-visible check: joining the two seeds must NOT double.
        final merged = a.join(b);
        expect(merged.values.join(), text,
            reason: 'CRDT join of two first-seeds must project to the '
                'original text, not text+text');
        expect(b.join(a).values.join(), text);
      },
    );
  });
}
