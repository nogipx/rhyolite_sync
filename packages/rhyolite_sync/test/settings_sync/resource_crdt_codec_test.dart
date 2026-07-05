import 'dart:convert';
import 'dart:typed_data';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/src/settings_sync/canonical_json.dart';
import 'package:rhyolite_sync/src/settings_sync/resource_crdt_codec.dart';
import 'package:test/test.dart';

/// Monotonic per-device clock. Distinct [start] values let one device's
/// writes deterministically dominate another's.
Hlc Function() clock(String node, {int start = 1}) {
  var ms = start;
  return () => Hlc(ms++, 0, node);
}

Uint8List jb(Object? value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));

String renderStr(ResourceCrdtCodec c, Object state) =>
    utf8.decode(c.renderState(state));

void main() {
  group('FieldMapCodec', () {
    final c = const FieldMapCodec();

    test('render is canonical and key-order independent', () {
      final s1 = c.diffApply(c.emptyState(), jb({'b': 2, 'a': 1}), clock('A'));
      final s2 = c.diffApply(c.emptyState(), jb({'a': 1, 'b': 2}), clock('B'));
      expect(renderStr(c, s1), canonicalJson({'a': 1, 'b': 2}));
      expect(renderStr(c, s1), renderStr(c, s2));
    });

    test('render -> diffApply with same bytes is a no-op (idempotent)', () {
      final s = c.diffApply(c.emptyState(), jb({'a': 1, 'b': 2}), clock('A'));
      final bytes = c.renderState(s);
      final s2 = c.diffApply(s, bytes, clock('A', start: 999));
      expect(renderStr(c, s2), renderStr(c, s));
    });

    test('removal detection: key absent from snapshot is dropped', () {
      final base =
          c.diffApply(c.emptyState(), jb({'a': 1, 'b': 2}), clock('A'));
      final del = c.diffApply(base, jb({'a': 1}), clock('A', start: 100));
      expect(renderStr(c, del), canonicalJson({'a': 1}));
    });

    test('concurrent edits to DIFFERENT keys both survive', () {
      final base =
          c.diffApply(c.emptyState(), jb({'a': 1, 'b': 2}), clock('Z'));
      final a = c.diffApply(base, jb({'a': 10, 'b': 2}), clock('A', start: 100));
      final b = c.diffApply(base, jb({'a': 1, 'b': 20}), clock('B', start: 100));
      final merged = c.joinStates(a, b);
      expect(renderStr(c, merged), canonicalJson({'a': 10, 'b': 20}));
    });

    test('concurrent edits to SAME key resolve by HLC (higher wins)', () {
      final base = c.diffApply(c.emptyState(), jb({'x': 1}), clock('Z'));
      final a = c.diffApply(base, jb({'x': 2}), clock('A', start: 100));
      final b = c.diffApply(base, jb({'x': 3}), clock('B', start: 200));
      // join is commutative; both orders pick B's value (higher HLC).
      expect(renderStr(c, c.joinStates(a, b)), canonicalJson({'x': 3}));
      expect(renderStr(c, c.joinStates(b, a)), canonicalJson({'x': 3}));
    });

    test('nested objects merge per-leaf', () {
      final base = c.diffApply(
          c.emptyState(), jb({'g': {'x': 1, 'y': 2}}), clock('Z'));
      final a = c.diffApply(
          base, jb({'g': {'x': 9, 'y': 2}}), clock('A', start: 100));
      final b = c.diffApply(
          base, jb({'g': {'x': 1, 'y': 8}}), clock('B', start: 100));
      expect(renderStr(c, c.joinStates(a, b)),
          canonicalJson({'g': {'x': 9, 'y': 8}}));
    });

    test('genuine null value is distinct from deletion', () {
      final s = c.diffApply(c.emptyState(), jb({'a': null, 'b': 1}), clock('A'));
      expect(renderStr(c, s), canonicalJson({'a': null, 'b': 1}));
    });

    test('encode/decode round-trips through join', () {
      final s = c.diffApply(c.emptyState(), jb({'a': 1, 'b': 2}), clock('A'));
      final wire = jsonDecode(jsonEncode(c.encodeState(s)));
      final restored = c.decodeState(wire);
      expect(renderStr(c, restored), renderStr(c, s));
    });
  });

  group('OrSetResourceCodec', () {
    final c = const OrSetResourceCodec();

    test('render is a sorted array', () {
      final s = c.diffApply(c.emptyState(), jb(['y', 'x']), clock('A'));
      expect(renderStr(c, s), canonicalJson(['x', 'y']));
    });

    test('concurrent adds of different elements both survive', () {
      final base = c.diffApply(c.emptyState(), jb(['x']), clock('Z'));
      final a = c.diffApply(base, jb(['x', 'a']), clock('A', start: 100));
      final b = c.diffApply(base, jb(['x', 'b']), clock('B', start: 100));
      expect(renderStr(c, c.joinStates(a, b)), canonicalJson(['a', 'b', 'x']));
    });

    test('removal drops the element', () {
      final s = c.diffApply(c.emptyState(), jb(['x', 'y']), clock('A'));
      final d = c.diffApply(s, jb(['x']), clock('A', start: 100));
      expect(renderStr(c, d), canonicalJson(['x']));
    });

    test('encode/decode round-trips', () {
      final s = c.diffApply(c.emptyState(), jb(['x', 'y']), clock('A'));
      final restored = c.decodeState(jsonDecode(jsonEncode(c.encodeState(s))));
      expect(renderStr(c, restored), renderStr(c, s));
    });
  });

  group('WholeFileCodec', () {
    final c = const WholeFileCodec();

    test('round-trips bytes', () {
      final s = c.diffApply(c.emptyState(), jb({'hello': 1}), clock('A'));
      expect(c.renderState(s), jb({'hello': 1}));
    });

    test('last-write-wins by HLC', () {
      final base = c.diffApply(c.emptyState(), jb('base'), clock('Z'));
      final a = c.diffApply(base, jb('AAA'), clock('A', start: 100));
      final b = c.diffApply(base, jb('BBB'), clock('B', start: 200));
      expect(utf8.decode(c.renderState(c.joinStates(a, b))),
          jsonEncode('BBB'));
    });

    test('unchanged bytes produce no new write', () {
      final s = c.diffApply(c.emptyState(), jb('same'), clock('A'));
      final s2 = c.diffApply(s, jb('same'), clock('A', start: 100));
      expect(identical(s, s2), isTrue);
    });
  });
}
