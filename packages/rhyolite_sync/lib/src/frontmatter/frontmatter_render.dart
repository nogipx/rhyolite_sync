/// Renders a parsed frontmatter document back to note bytes.
///
/// The quoting rule is a DEFINITION, not a list of special cases: a value is
/// written bare exactly when reading the bare form back yields the same kind
/// and text. An implementation may short-circuit with a predicate, but this
/// round-trip is the reference, and it is what the property tests check.
///
/// The rendering is pinned to the blob tag it belongs to. A better renderer is
/// a NEW tag, never a change to this one — `materializeFileContent` is the
/// single source of "blob to file content" for history restore, backup restore
/// and the diff view, so changing how old blobs render turns every historical
/// diff into noise.
library;

import 'frontmatter_document.dart';
import 'frontmatter_parser.dart';

const _fence = '---';

/// Renders a whole note: fences, region, body.
///
/// A map with no live keys renders as the body alone, with no fences and
/// without its lead or trail — otherwise a region of nothing but comments
/// would read back as [FmRaw] and the shape would oscillate.
String renderNote(FmDocument fm, String body) {
  switch (fm) {
    case FmMap(:final entries):
      if (entries.isEmpty) return body;
      return '$_fence\n${renderRegion(fm)}$_fence\n$body';
    case FmRaw(:final text):
      return '$_fence\n$text$_fence\n$body';
  }
}

/// Renders the region only — everything that sits between the fences,
/// including its trailing newline.
String renderRegion(FmDocument fm) {
  switch (fm) {
    case FmRaw(:final text):
      return text;
    case FmMap(:final entries, :final trail):
      final buf = StringBuffer();
      for (final e in entries) {
        buf.write(e.lead);
        buf.write(renderEntry(e));
      }
      buf.write(trail);
      return buf.toString();
  }
}

/// Renders one `key: value` (plus any list lines), newline included.
String renderEntry(FmEntry entry) {
  final key = renderKey(entry.key);
  switch (entry.value) {
    case FmOpaque(:final raw):
      // Verbatim, including the space after the colon it was captured with.
      return '$key:$raw';
    case FmScalar(:final text) when text.isEmpty:
      return '$key:\n';
    case FmScalar scalar:
      return '$key: ${renderScalar(scalar)}\n';
    case FmList(:final items):
      // The one place a list is not written block: block syntax cannot express
      // an empty sequence at all, and `key:` alone reads back as an empty
      // STRING. Writing `[]` keeps the kind in the file instead of relying on
      // the previous state to remember it, so render → parse reaches a fixed
      // point on its own. Obsidian writes `key:` here; that difference is
      // cosmetic and covered by the fixture corpus, not by correctness.
      if (items.isEmpty) return '$key: []\n';
      final buf = StringBuffer('$key:\n');
      for (final item in items) {
        buf.write('  - ${renderScalar(FmScalar(ScalarKind.text, item))}\n');
      }
      return buf.toString();
  }
}

/// Renders a key, quoting only when the bare form would not read back as the
/// same key. Cyrillic and other non-ASCII need no quotes — a bare form reads
/// back as itself.
String renderKey(String key) {
  if (key.isEmpty) return '""';
  if (key.trim() != key) return _quote(key);
  if (key.contains(':') || key.contains('#') || key.contains('\n')) {
    return _quote(key);
  }
  // A key that opens with YAML punctuation would start a different construct.
  if (_opensAConstruct(key[0])) return _quote(key);
  return key;
}

/// Renders a scalar, bare when that round-trips and quoted otherwise.
String renderScalar(FmScalar scalar) {
  final bare = scalar.text;
  if (bare.isEmpty) return '""';
  if (bare.trim() != bare) return _quote(bare);
  if (bare.contains('\n')) return _quote(bare);
  // A line equal to a fence would be read as the end of the region — the one
  // hard prohibition in the format.
  if (bare == _fence || bare == '...') return _quote(bare);
  if (_opensAConstruct(bare[0])) return _quote(bare);
  // `a: b` cannot be a plain scalar, and ` #` starts a comment.
  if (bare.contains(': ') || bare.contains(' #')) return _quote(bare);
  if (bare.endsWith(':')) return _quote(bare);
  // Reads as a string under js-yaml but as a boolean under YAML 1.1. Quoted so
  // no other reader disagrees with Obsidian about what the user wrote.
  if (ambiguousScalarTokens.contains(bare)) return _quote(bare);
  if (bare == 'null' || bare == 'Null' || bare == 'NULL' || bare == '~') {
    return _quote(bare);
  }
  // The definition: bare is allowed exactly when it reads back unchanged.
  return parseBareScalar(bare) == scalar ? bare : _quote(bare);
}

/// The characters that, in first position, start something other than a plain
/// scalar: collections, anchors, aliases, tags, block scalars, directives,
/// comments, quotes, and the reserved `@` and backtick.
bool _opensAConstruct(String c) => '[]{}>|*&!%@#,?:-\'"`'.contains(c);

String _quote(String s) {
  final buf = StringBuffer('"');
  for (final rune in s.runes) {
    final c = String.fromCharCode(rune);
    buf.write(switch (c) {
      '"' => r'\"',
      r'\' => r'\\',
      '\n' => r'\n',
      '\t' => r'\t',
      '\r' => r'\r',
      _ => c,
    });
  }
  buf.write('"');
  return buf.toString();
}
