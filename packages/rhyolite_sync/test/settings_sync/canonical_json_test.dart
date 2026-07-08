import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/src/settings_sync/canonical_json.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('jsonCanonicalEqual', () {
    test('same content, different key order -> equal', () {
      expect(
        jsonCanonicalEqual(_b('{"a":1,"b":2}'), _b('{"b":2,"a":1}')),
        isTrue,
      );
    });

    test('pretty vs minified -> equal', () {
      expect(
        jsonCanonicalEqual(
          _b('{\n  "a": 1,\n  "nested": { "x": true }\n}'),
          _b('{"nested":{"x":true},"a":1}'),
        ),
        isTrue,
      );
    });

    test('nested key order differs -> equal', () {
      expect(
        jsonCanonicalEqual(
          _b('{"o":{"type":"leaf","icon":"file"}}'),
          _b('{"o":{"icon":"file","type":"leaf"}}'),
        ),
        isTrue,
      );
    });

    test('different values -> not equal', () {
      expect(jsonCanonicalEqual(_b('{"a":1}'), _b('{"a":2}')), isFalse);
    });

    test('missing key -> not equal', () {
      expect(
        jsonCanonicalEqual(_b('{"a":1,"b":2}'), _b('{"a":1}')),
        isFalse,
      );
    });

    test('array order is significant -> not equal', () {
      expect(jsonCanonicalEqual(_b('[1,2]'), _b('[2,1]')), isFalse);
    });

    test('non-JSON input -> not equal (never claims a match)', () {
      expect(jsonCanonicalEqual(_b('not json'), _b('{"a":1}')), isFalse);
      expect(jsonCanonicalEqual(_b('{"a":1}'), _b('{bad')), isFalse);
    });
  });
}
