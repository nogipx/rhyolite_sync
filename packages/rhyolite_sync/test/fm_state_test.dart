import 'dart:math';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_state.dart';
import 'package:rhyolite_sync/src/frontmatter/frac_index.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_document.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_parser.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_render.dart';
import 'package:test/test.dart';

/// A device with its own node id — the join's tiebreak — drawing from one
/// shared, monotonic wall clock.
///
/// Shared on purpose. Concurrency in this model is not "clocks disagree", it
/// is "two states derived from a common base without seeing each other", which
/// every test below builds explicitly. The clock only decides who wins, and it
/// has to advance in call order or a test that means "b edited afterwards"
/// silently means the opposite.
int _wall = 1000;

class _Device {
  _Device(this.id);

  final String id;

  Hlc tick() => Hlc(++_wall, 0, id);
}

/// Applies what a file says to a state, as ingest will.
FmState ingest(FmState state, String region, Hlc now) =>
    applyDiskFrontmatter(state, parseFrontmatterRegion(region), now);

FmState emptyMap(Hlc at) =>
    FmMapState(entries: const {}, fmHlc: at, trailHlc: at);

String show(FmState s) => renderRegion(materializeFm(s));

void main() {
  group('frac index', () {
    test('between always lands strictly inside', () {
      final rnd = Random(7);
      var keys = <String>[midFracIndex];
      for (var i = 0; i < 400; i++) {
        final at = rnd.nextInt(keys.length + 1);
        final lo = at == 0 ? null : keys[at - 1];
        final hi = at == keys.length ? null : keys[at];
        final mid = fracIndexBetween(lo, hi);
        expect(isValidFracIndex(mid), isTrue, reason: 'lo=$lo hi=$hi -> $mid');
        if (lo != null) expect(lo.compareTo(mid) < 0, isTrue, reason: '$lo < $mid');
        if (hi != null) expect(mid.compareTo(hi) < 0, isTrue, reason: '$mid < $hi');
        keys = [...keys.sublist(0, at), mid, ...keys.sublist(at)];
      }
      final sorted = [...keys]..sort();
      expect(keys, sorted, reason: 'insertion order must stay sorted');
    });

    test('inserting at the front repeatedly stays valid', () {
      var first = midFracIndex;
      for (var i = 0; i < 200; i++) {
        final next = fracIndexBetween(null, first);
        expect(next.compareTo(first) < 0, isTrue);
        expect(isValidFracIndex(next), isTrue);
        first = next;
      }
    });

    test('positional indices are ordered and clock-free', () {
      for (final total in [1, 5, 61, 62, 200]) {
        final all = [
          for (var i = 0; i < total; i++) fracIndexForPosition(i, total),
        ];
        expect(all, [...all]..sort(), reason: 'total=$total');
        expect(all.toSet(), hasLength(total), reason: 'total=$total');
      }
    });
  });

  group('join — the algebra', () {
    /// A handful of states reachable by ordinary editing, built from two
    /// devices so their clocks interleave.
    List<FmState> corpus() {
      final a = _Device('device-a');
      final b = _Device('device-b');
      final base = ingest(emptyMap(a.tick()), 'x: 1\ntags:\n  - work\n', a.tick());
      return [
        base,
        ingest(base, 'x: 2\ntags:\n  - work\n', a.tick()),
        ingest(base, 'x: 1\ntags:\n  - work\n  - home\n', b.tick()),
        ingest(base, 'tags:\n  - work\n', b.tick()), // x deleted
        ingest(base, 'x: 1\ntags: hello\n', a.tick()), // kind change
        ingest(base, '# note\nx: 1\ntags:\n  - work\n', b.tick()), // lead
        ingest(base, 'x: 1\ntags:\n  - work\n# trail\n', a.tick()),
        ingest(emptyMap(b.tick()), 'y: 9\n', b.tick()),
        FmRawState(tree: seedFugueText('- not a mapping\n'), fmHlc: b.tick()),
      ];
    }

    test('commutative', () {
      final states = corpus();
      for (final x in states) {
        for (final y in states) {
          expect(show(joinFm(x, y)), show(joinFm(y, x)));
        }
      }
    });

    test('associative', () {
      final states = corpus();
      for (final x in states) {
        for (final y in states) {
          for (final z in states) {
            expect(
              show(joinFm(joinFm(x, y), z)),
              show(joinFm(x, joinFm(y, z))),
            );
          }
        }
      }
    });

    test('idempotent', () {
      for (final x in corpus()) {
        expect(show(joinFm(x, x)), show(x));
      }
    });
  });

  group('join — what it decides', () {
    test('THE BUG: two devices add to the same list offline', () {
      // The whole point. Under Fugue both `related:` lines survived and the
      // file held one key twice; the reader took one and the other was lost
      // with no conflict event anywhere.
      final a = _Device('device-a');
      final b = _Device('device-b');
      final base = ingest(
        emptyMap(a.tick()),
        'related:\n  - "[[2026-07-01]]"\n',
        a.tick(),
      );

      final onA = ingest(
        base,
        'related:\n  - "[[2026-07-01]]"\n  - "[[2026-07-31]]"\n',
        a.tick(),
      );
      final onB = ingest(
        base,
        'related:\n  - "[[2026-07-01]]"\n  - "[[2026-07-27]]"\n',
        b.tick(),
      );

      final merged = materializeFm(joinFm(onA, onB)) as FmMap;
      expect(merged.entries, hasLength(1), reason: 'one key, not two');
      final items = (merged.entries.single.value as FmList).items;
      expect(items, containsAll(['[[2026-07-01]]', '[[2026-07-31]]', '[[2026-07-27]]']));
      expect(items, hasLength(3));
    });

    test('concurrent edits to DIFFERENT keys both survive', () {
      final a = _Device('a');
      final b = _Device('b');
      final base = ingest(emptyMap(a.tick()), 'x: 1\ny: 1\n', a.tick());
      final onA = ingest(base, 'x: 2\ny: 1\n', a.tick());
      final onB = ingest(base, 'x: 1\ny: 2\n', b.tick());

      final merged = materializeFm(joinFm(onA, onB)) as FmMap;
      expect((merged.entries[0].value as FmScalar).text, '2');
      expect((merged.entries[1].value as FmScalar).text, '2');
    });

    test('a deleted key stays deleted against a stale peer', () {
      final a = _Device('a');
      final base = ingest(emptyMap(a.tick()), 'x: 1\ny: 2\n', a.tick());
      final deleted = ingest(base, 'y: 2\n', a.tick());

      // b never saw the delete and merely re-pushes what it had.
      final merged = materializeFm(joinFm(deleted, base)) as FmMap;
      expect(merged.entries.map((e) => e.key), ['y']);
    });

    test('a re-added key returns to its old place with its comment', () {
      final a = _Device('a');
      final base = ingest(
        emptyMap(a.tick()),
        '# about x\nx: 1\ny: 2\nz: 3\n',
        a.tick(),
      );
      final deleted = ingest(base, 'y: 2\nz: 3\n', a.tick());
      final readded = ingest(deleted, '# about x\nx: 9\ny: 2\nz: 3\n', a.tick());

      final doc = materializeFm(readded) as FmMap;
      expect(doc.entries.map((e) => e.key), ['x', 'y', 'z']);
      expect(doc.entries.first.lead, '# about x\n');
    });

    test('an unmodelled value is last-writer, and says so plainly', () {
      final a = _Device('a');
      final b = _Device('b');
      final base = ingest(
        emptyMap(a.tick()),
        'publish:\n  status: draft\nx: 1\n',
        a.tick(),
      );
      final onA = ingest(base, 'publish:\n  status: review\nx: 1\n', a.tick());
      final onB = ingest(base, 'publish:\n  status: done\nx: 2\n', b.tick());

      final merged = materializeFm(joinFm(onA, onB)) as FmMap;
      // b's clock is later, so its opaque block wins whole. x, a modelled key,
      // merges independently and keeps b's newer value too.
      final publish = merged.entries.firstWhere((e) => e.key == 'publish');
      expect((publish.value as FmOpaque).raw, contains('done'));
      final x = merged.entries.firstWhere((e) => e.key == 'x');
      expect((x.value as FmScalar).text, '2');
    });

    test('a shape change is decided whole, never blended', () {
      final a = _Device('a');
      final b = _Device('b');
      final asMap = ingest(emptyMap(a.tick()), 'x: 1\n', a.tick());
      final asRaw = FmRawState(
        tree: seedFugueText('- turned into a list\n'),
        fmHlc: b.tick(),
      );
      expect(materializeFm(joinFm(asMap, asRaw)), isA<FmRaw>());
    });
  });

  group('tombstone reclamation', () {
    test('drops deleted keys and deleted items, keeps the living', () {
      final a = _Device('a');
      final base = ingest(
        emptyMap(a.tick()),
        'keep: 1\ngone: 2\ntags:\n  - stay\n  - drop\n',
        a.tick(),
      );
      final after =
          ingest(base, 'keep: 1\ntags:\n  - stay\n', a.tick()) as FmMapState;

      expect(after.entries['gone']!.isLive, isFalse, reason: 'tombstone first');
      final pruned = pruneFmTombstones(after) as FmMapState;

      expect(pruned.entries.containsKey('gone'), isFalse);
      expect(pruned.entries.containsKey('keep'), isTrue);
      final items = (pruned.entries['tags']!.value! as FmListValue).items;
      expect(items.keys, ['stay']);
      // And the document it means is unchanged — pruning is invisible.
      expect(show(pruned), show(after));
    });

    test('returns the same instance when there is nothing to reclaim', () {
      final a = _Device('a');
      final clean = ingest(emptyMap(a.tick()), 'x: 1\n', a.tick());
      expect(identical(pruneFmTombstones(clean), clean), isTrue,
          reason: 'callers use identity to skip a pointless write');
    });

    test('pruning too early resurrects — which is why the caller gates it', () {
      // Not a defect in the function; a statement of what it costs to call it
      // before every device has seen the delete. The gate lives at the call
      // site, on the causal-stability barrier.
      final a = _Device('a');
      final base = ingest(emptyMap(a.tick()), 'x: 1\n', a.tick());
      final deleted = ingest(base, '', a.tick());

      expect((materializeFm(joinFm(deleted, base)) as FmMap).entries, isEmpty,
          reason: 'with the tombstone, the delete holds');
      expect(
        (materializeFm(joinFm(pruneFmTombstones(deleted), base)) as FmMap)
            .entries,
        hasLength(1),
        reason: 'without it, a peer that missed the delete adds the key back',
      );
    });

    test('a RawFm has nothing to reclaim', () {
      final raw = FmRawState(tree: seedFugueText('- list\n'), fmHlc: _Device('a').tick());
      expect(identical(pruneFmTombstones(raw), raw), isTrue);
    });
  });

  group('ingest — writing back what the file says', () {
    test('re-ingesting an unchanged file mutates nothing', () {
      final a = _Device('a');
      const region = '# lead\nx: 1\ntags:\n  - work\n# trail\n';
      final first = ingest(emptyMap(a.tick()), region, a.tick());
      final again = ingest(first, region, a.tick());

      final e1 = (first as FmMapState).entries['x']!;
      final e2 = (again as FmMapState).entries['x']!;
      expect(e2.hlc, e1.hlc, reason: 'an untouched key must not re-clock');
      expect(e2.order, e1.order);
      expect(e2.leadHlc, e1.leadHlc);
    });

    test('materialize ∘ ingest is the identity on the document', () {
      final a = _Device('a');
      for (final region in [
        'x: 1\ntags:\n  - work\n  - home\n',
        '# c\nx: hello\n\n# d\ny: 2026-08-03\n# trail\n',
        'publish:\n  nested: yes\nx: 1\n',
        'empty:\nlist: []\n',
      ]) {
        final doc = parseFrontmatterRegion(region);
        final state = applyDiskFrontmatter(emptyMap(a.tick()), doc, a.tick());
        expect(materializeFm(state), doc, reason: region);
      }
    });
  });
}
