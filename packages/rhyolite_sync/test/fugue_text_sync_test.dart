import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_text_sync.dart';
import 'package:test/test.dart';

void main() {
  // Helper: build a per-device monotonic HLC clock anchored at a base
  // millis value so each test is deterministic.
  Hlc Function() clockOf(String node, {int startMs = 1000}) {
    var counter = 0;
    return () {
      counter += 1;
      return Hlc(startMs, counter, node);
    };
  }

  Sequence<String> seed(String text) => FugueTextSync.seedFromText(text);

  group('FugueTextSync.seedFromText', () {
    test('projection round-trips the original text', () {
      final seq = FugueTextSync.seedFromText('hello, world');
      expect(seq.values.join(), 'hello, world');
      expect(seq.length, 'hello, world'.length);
    });

    test('preserves unicode codepoints across the rune iterator', () {
      const txt = 'тест ✓ ok';
      final seq = FugueTextSync.seedFromText(txt);
      expect(seq.values.join(), txt);
    });

    test('empty text produces empty sequence', () {
      final seq = FugueTextSync.seedFromText('');
      expect(seq.length, 0);
      expect(seq.values, isEmpty);
    });

    // The convergence guarantee that makes [seedFromText] safe to call
    // independently on multiple devices. If this regresses, two devices
    // first-seeding the same file produce divergent Sequences and a
    // later CRDT `join` doubles the on-disk content (the post-wipe
    // duplication regression).
    test('same input → byte-identical Sequence (cross-device convergence)',
        () {
      const txt = 'some shared content that two devices see identically';
      final a = FugueTextSync.seedFromText(txt);
      final b = FugueTextSync.seedFromText(txt);
      expect(a, equals(b));
      expect(a.join(b), equals(a)); // join is a no-op
      expect(a.join(b).values.join(), txt);
    });
  });

  group('FugueTextSync.applyTextSnapshot — basic edits', () {
    test('identical text is a no-op (returns same instance)', () async {
      final s = seed('hello');
      final after = await FugueTextSync.applyTextSnapshot(
        oldSequence: s,
        newText: 'hello',
        nextHlc: clockOf('A'),
      );
      expect(identical(after, s), isTrue);
    });

    test('insert into empty', () async {
      final after = await FugueTextSync.applyTextSnapshot(
        oldSequence: Sequence<String>.empty(),
        newText: 'hello',
        nextHlc: clockOf('A'),
      );
      expect(after.values.join(), 'hello');
    });

    test('delete to empty', () async {
      final after = await FugueTextSync.applyTextSnapshot(
        oldSequence: seed('hello'),
        newText: '',
        nextHlc: clockOf('A'),
      );
      expect(after.values.join(), '');
      expect(after.length, 0);
    });

    test('append at tail', () async {
      final after = await FugueTextSync.applyTextSnapshot(
        oldSequence: seed('hello'),
        newText: 'hello world',
        nextHlc: clockOf('A'),
      );
      expect(after.values.join(), 'hello world');
    });

    test('prepend at head', () async {
      final after = await FugueTextSync.applyTextSnapshot(
        oldSequence: seed('world'),
        newText: 'hello world',
        nextHlc: clockOf('A'),
      );
      expect(after.values.join(), 'hello world');
    });

    test('replace single character mid-string', () async {
      final after = await FugueTextSync.applyTextSnapshot(
        oldSequence: seed('hello'),
        newText: 'hellp',
        nextHlc: clockOf('A'),
      );
      expect(after.values.join(), 'hellp');
    });

    test('replace a word with a different one', () async {
      final after = await FugueTextSync.applyTextSnapshot(
        oldSequence: seed('hello world'),
        newText: 'hello there',
        nextHlc: clockOf('A'),
      );
      expect(after.values.join(), 'hello there');
    });

    test('delete a middle slice', () async {
      final after = await FugueTextSync.applyTextSnapshot(
        oldSequence: seed('hello beautiful world'),
        newText: 'hello world',
        nextHlc: clockOf('A'),
      );
      expect(after.values.join(), 'hello world');
    });
  });

  group('FugueTextSync.applyTextSnapshot — unicode', () {
    test('cyrillic edit', () async {
      final s = seed('привет');
      final after = await FugueTextSync.applyTextSnapshot(
        oldSequence: s,
        newText: 'привет, мир',
        nextHlc: clockOf('A'),
      );
      expect(after.values.join(), 'привет, мир');
    });

    test('emoji insertion (surrogate-pair codepoint)', () async {
      final s = seed('done ');
      final after = await FugueTextSync.applyTextSnapshot(
        oldSequence: s,
        newText: 'done 🚀',
        nextHlc: clockOf('A'),
      );
      expect(after.values.join(), 'done 🚀');
    });
  });

  group('FugueTextSync.applyTextSnapshot — incremental sessions', () {
    test('many sequential edits each round-trip cleanly', () async {
      final clk = clockOf('A');
      var s = Sequence<String>.empty();
      const snapshots = [
        'h',
        'he',
        'hel',
        'hell',
        'hello',
        'hello!',
        'hello world',
        'hello world!',
        'hello there world!',
        'hello there world',
        'hi there world',
      ];
      for (final snap in snapshots) {
        s = await FugueTextSync.applyTextSnapshot(
          oldSequence: s,
          newText: snap,
          nextHlc: clk,
        );
        expect(s.values.join(), snap,
            reason: 'projection diverges after snapshot=$snap');
      }
    });

    test('tombstones survive the diff loop without affecting projection',
        () async {
      final clk = clockOf('A');
      var s = seed('hello world');
      // Remove a substring twice via separate snapshots.
      s = await FugueTextSync.applyTextSnapshot(
        oldSequence: s,
        newText: 'hello',
        nextHlc: clk,
      );
      s = await FugueTextSync.applyTextSnapshot(
        oldSequence: s,
        newText: 'hi',
        nextHlc: clk,
      );
      expect(s.values.join(), 'hi');
      // The structure must still contain enough metadata to converge
      // with a peer that hasn't seen the deletions yet.
      expect(s.entries.length, greaterThan(2));
    });
  });

  group('FugueTextSync.applyTextSnapshot — convergence', () {
    test('two devices typing concurrently on top of a shared base merge',
        () async {
      final base = seed('hello world');
      // Device A inserts ' beautiful' before "world".
      final a = await FugueTextSync.applyTextSnapshot(
        oldSequence: base,
        newText: 'hello beautiful world',
        nextHlc: clockOf('A', startMs: 2000),
      );
      // Device B independently appends '!' at the end.
      final b = await FugueTextSync.applyTextSnapshot(
        oldSequence: base,
        newText: 'hello world!',
        nextHlc: clockOf('B', startMs: 3000),
      );
      final merged = a.join(b);
      // Both edits coexist losslessly. The exact character order
      // depends on Fugue tie-breaking but the multiset is preserved.
      final out = merged.values.join();
      expect(out.contains('hello'), isTrue);
      expect(out.contains('beautiful'), isTrue);
      expect(out.contains('world'), isTrue);
      expect(out.contains('!'), isTrue);
      // Symmetric merge produces the same final state.
      expect(b.join(a), merged);
    });

    // Regression guard: the content-duplication bug observed on
    // local-DB wipe (2026-06-04). Two devices independently first-seed
    // the SAME plain text after wiping local state. Each call goes
    // through the empty-oldSequence fast path inside applyTextSnapshot.
    // If that path mints dots from the local device's HLC (as it
    // briefly did), the two Sequences end up with disjoint causal
    // histories — a later CRDT `join` (which `_resolveTextConflict`
    // performs) concatenates them and the file's projection becomes
    // `text + text`.
    //
    // The fix routes the empty case through [seedFromText], whose
    // deterministic dot scheme guarantees identical Sequences across
    // devices and across calls.
    //
    // If this test regresses (someone re-introduces device-local dots
    // in the empty-Sequence fast path, or in [seedFromText] itself),
    // every user who deletes their local DB will silently double every
    // file on next sync.
    test(
      'two devices independently first-seeding the same text converge '
      '(regression: post-wipe content duplication)',
      () async {
        const text =
            '# Заметка\n\nКонтент который существует на обоих устройствах '
            'одинаково. Если CRDT не сходится, после wipe всё удвоится.';
        // Device A wipes → first-seeds from disk. Empty oldSequence.
        final a = await FugueTextSync.applyTextSnapshot(
          oldSequence: Sequence<String>.empty(),
          newText: text,
          nextHlc: clockOf('A', startMs: 9000),
        );
        // Device B independently wipes → first-seeds from disk with
        // identical content. Empty oldSequence.
        final b = await FugueTextSync.applyTextSnapshot(
          oldSequence: Sequence<String>.empty(),
          newText: text,
          nextHlc: clockOf('B', startMs: 9999),
        );

        // First check: identical content from independent seeds must
        // produce byte-identical Sequences. Anything else means the
        // seed minted device-local dots and the bug is back.
        expect(
          a,
          equals(b),
          reason: 'independent first-seeds of the same text must produce '
              'identical Sequences (otherwise CRDT join below duplicates)',
        );

        // Second check, the user-visible one: joining the two seeds
        // does NOT double the text. Projection equals the original.
        final merged = a.join(b);
        expect(
          merged.values.join(),
          text,
          reason: 'CRDT join of two first-seeds must project to the original '
              'text, not text+text. This is the post-wipe duplication '
              'regression — see comment above.',
        );

        // And symmetric, just to be sure tiebreaking is order-stable.
        expect(b.join(a).values.join(), text);
      },
    );
  });
}
