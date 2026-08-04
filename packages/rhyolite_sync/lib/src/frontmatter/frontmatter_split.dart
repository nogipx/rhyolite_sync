/// Cuts a note into its frontmatter region and its body.
///
/// The predicate is PURELY syntactic — no size limits, no check that the
/// region parses. It has to agree with Obsidian's own parser: if we call a
/// region body while Obsidian shows it as properties, our idea of the file
/// differs from what the user sees, and every later argument about
/// correctness is built on sand.
library;

/// The two halves of a note. [region] is null when the file has no
/// frontmatter at all, and then [body] is the whole text.
typedef FrontmatterSplit = ({String? region, String body});

const _fence = '---';

/// Normalises line endings and strips a leading BOM.
///
/// Done before anything else so `\r\n` files and BOM'd files take the same
/// path as everyone else — otherwise the fence test fails on a file that
/// Obsidian happily shows as having properties.
String normalizeNewlines(String text) {
  final noBom = text.startsWith('﻿') ? text.substring(1) : text;
  return noBom.contains('\r') ? noBom.replaceAll('\r\n', '\n') : noBom;
}

/// Splits [text] into its frontmatter region and body.
///
/// A region is recognised if and only if the text opens with a line that is
/// exactly `---`, and some later line is exactly `---`. The FIRST such closing
/// line wins, which is what makes horizontal rules in the body safe: they are
/// always later than the real close.
///
/// The fences themselves belong to neither half. They are not stored anywhere
/// — the renderer emits them — so a state that contained `---` would be a bug.
FrontmatterSplit splitFrontmatter(String text) {
  final normalized = normalizeNewlines(text);
  if (!normalized.startsWith('$_fence\n') && normalized != _fence) {
    return (region: null, body: normalized);
  }
  // A file that is nothing but `---` has no closing fence.
  if (normalized == _fence) return (region: null, body: normalized);

  var searchFrom = _fence.length + 1;
  while (searchFrom <= normalized.length) {
    final lineEnd = normalized.indexOf('\n', searchFrom);
    final line = lineEnd < 0
        ? normalized.substring(searchFrom)
        : normalized.substring(searchFrom, lineEnd);
    if (line == _fence) {
      return (
        region: normalized.substring(_fence.length + 1, searchFrom),
        // Everything after the closing fence's newline. A fence on the last
        // line with no trailing newline leaves an empty body.
        body: lineEnd < 0 ? '' : normalized.substring(lineEnd + 1),
      );
    }
    if (lineEnd < 0) break;
    searchFrom = lineEnd + 1;
  }
  // Opened but never closed — the whole thing is body, exactly as Obsidian
  // treats it.
  return (region: null, body: normalized);
}
