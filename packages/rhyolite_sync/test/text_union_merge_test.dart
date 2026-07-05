import 'package:rhyolite_sync/src/sync_v3/text_union_merge.dart';
import 'package:test/test.dart';

/// All lines of [text] (split on newlines).
List<String> _lines(String text) => text.split('\n');

void main() {
  group('deterministicLineUnion', () {
    test('order-independent for two inputs', () {
      const a = 'shared\nalpha';
      const b = 'shared\nbeta';
      expect(deterministicLineUnion([a, b]),
          deterministicLineUnion([b, a]));
    });

    test('lossless — every line of every input survives', () {
      const a = 'h1\nbody A\nfooter';
      const b = 'h1\nbody B different\nfooter';
      final u = deterministicLineUnion([a, b]);
      final lines = _lines(u);
      for (final l in {..._lines(a), ..._lines(b)}) {
        expect(lines, contains(l), reason: 'line "$l" must survive in "$u"');
      }
    });

    test('shared context is de-duplicated, divergent lines both kept', () {
      const a = '## 2026-06-21\n\nMeeting at 3pm';
      const b = '## 2026-06-21\n\nBuy milk and eggs';
      final u = deterministicLineUnion([a, b]);
      // Header + blank line appear once.
      expect('## 2026-06-21'.allMatches(u).length, 1);
      // Both bodies present.
      expect(u, contains('Meeting at 3pm'));
      expect(u, contains('Buy milk and eggs'));
    });

    test('legitimately repeated identical lines are NOT collapsed', () {
      const a = '- [ ]\n- [ ]';
      const b = '- [ ]';
      final u = deterministicLineUnion([a, b]);
      // A has two checkboxes; union must keep two (no self-dedup).
      expect('- [ ]'.allMatches(u).length, greaterThanOrEqualTo(2));
    });

    test('identical inputs collapse to the input (idempotent)', () {
      const x = 'line one\nline two';
      expect(deterministicLineUnion([x, x]), x);
      expect(deterministicLineUnion([x]), x);
    });

    test('empty inputs contribute nothing', () {
      expect(deterministicLineUnion(['', '']), '');
      expect(deterministicLineUnion(['', 'only']), 'only');
    });

    test('three-way union is confluent across ALL permutations', () {
      const a = 'base\nfrom A';
      const b = 'base\nfrom B';
      const c = 'base\nfrom C';
      final perms = <List<String>>[
        [a, b, c],
        [a, c, b],
        [b, a, c],
        [b, c, a],
        [c, a, b],
        [c, b, a],
      ];
      final results = perms.map(deterministicLineUnion).toSet();
      expect(results, hasLength(1),
          reason: 'every device, whatever order it observed the values, '
              'must compute the same union: $results');
      // And it is lossless across all three.
      final u = results.single;
      expect(u, contains('from A'));
      expect(u, contains('from B'));
      expect(u, contains('from C'));
      expect('base'.allMatches(u).length, 1);
    });

    test('single-line divergent notes keep both as separate lines', () {
      const a = 'just my phone note';
      const b = 'totally different laptop note';
      final u = deterministicLineUnion([a, b]);
      expect(u, contains('phone note'));
      expect(u, contains('laptop note'));
    });
  });
}
