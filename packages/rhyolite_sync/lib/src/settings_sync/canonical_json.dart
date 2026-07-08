import 'dart:convert';
import 'dart:typed_data';

/// Canonical JSON serialization: object keys are sorted recursively so that
/// `render(parse(render(x)))` is byte-stable. This is load-bearing for the
/// settings sync echo-suppression (hash compare) and for idempotent
/// render → parse → render cycles. List order is preserved (it is
/// semantically meaningful).
Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _canonicalize(value[k])};
  }
  if (value is List) {
    return value.map(_canonicalize).toList();
  }
  return value;
}

/// Canonical JSON string (sorted keys, no insignificant whitespace).
String canonicalJson(Object? value) => jsonEncode(_canonicalize(value));

/// Canonical JSON encoded as UTF-8 bytes.
Uint8List canonicalJsonBytes(Object? value) =>
    Uint8List.fromList(utf8.encode(canonicalJson(value)));

/// True when [a] and [b] are the same JSON value up to object key order and
/// insignificant whitespace — i.e. they differ only in formatting. Used to
/// decide whether writing our canonical render over a file would actually
/// change anything, so Obsidian's own natural-order format is left in place
/// when nothing changed. Returns false if either side is not valid JSON.
bool jsonCanonicalEqual(Uint8List a, Uint8List b) {
  try {
    return canonicalJson(jsonDecode(utf8.decode(a))) ==
        canonicalJson(jsonDecode(utf8.decode(b)));
  } catch (_) {
    return false;
  }
}
