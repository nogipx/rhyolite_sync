
/// Turns a frontmatter region into [FmMap] or [FmRaw].
///
/// A hand-written recogniser for the modelled subset rather than
/// `package:yaml`.
///
/// Not for the reason first written down here — that a parsed tree lacks
/// source spans. It does not: `YamlNode.span` exposes them, the library is
/// built on `source_span`.
///
/// The reason is that the parser we must agree with is js-yaml, the one
/// Obsidian runs. `package:yaml` is a third implementation, so adopting it
/// would make us agree with Dart's YAML and inherit divergences nobody chose.
/// A narrow subset inverts that: we owe agreement on an enumerable set of
/// shapes, and everything else is held verbatim, where it cannot diverge at
/// all.
///
/// It would also close less of the work than it looks. A parser RESOLVES
/// anchors and aliases — `*alias` comes back as a copy of the value, and only
/// the source text still says it was an alias — so everything unmodelled would
/// be read from spans anyway, and the renderer has to be ours regardless: an
/// emitter reformats the whole block and drops comments.
///
/// The failure path is safe BY CONSTRUCTION, not by care: anything the
/// recogniser does not take becomes [FmOpaque] (one value) or [FmRaw] (the
/// whole region), and both are kept verbatim. Being wrong here costs merge
/// quality, never content.
library;

import 'frontmatter_document.dart';

/// Tokens whose bare form is a string under js-yaml's core schema — what
/// Obsidian reads — but a boolean or null under YAML 1.1, which plenty of
/// other readers still use.
///
/// Parsed as text, because that is what the user sees in Obsidian. Always
/// quoted on the way out, so a Dataview query or an external script does not
/// silently see a boolean where the user typed a word.
const ambiguousScalarTokens = <String>{
  'yes', 'no', 'on', 'off',
  'Yes', 'No', 'On', 'Off',
  'YES', 'NO', 'ON', 'OFF',
  'y', 'n', 'Y', 'N',
};

// Leading zeros included on purpose: js-yaml's core schema reads `007` as the
// number 7, so refusing it here would make us disagree with Obsidian about
// what the file says — the one thing §5 forbids. The renderer then quotes a
// TEXT value of "007", because its bare form would come back as a number.
final _numberPattern = RegExp(r'^[-+]?(\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?$');
final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _dateTimePattern = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$');

/// Parses the bare (unquoted) form of a scalar into its kind.
///
/// The inverse of the renderer's bare form, and the two are checked against
/// each other: a value is written bare only when this function reads it back
/// as the same kind and text.
FmScalar parseBareScalar(String bare) {
  if (bare == 'true' || bare == 'false') {
    return FmScalar(ScalarKind.boolean, bare);
  }
  if (_numberPattern.hasMatch(bare)) return FmScalar(ScalarKind.number, bare);
  if (_datePattern.hasMatch(bare)) return FmScalar(ScalarKind.date, bare);
  if (_dateTimePattern.hasMatch(bare)) {
    return FmScalar(ScalarKind.datetime, bare);
  }
  return FmScalar(ScalarKind.text, bare);
}

/// Parses [region] — the text between the fences, without them.
///
/// [priorKinds] carries the kind each key had in the state being updated. It
/// exists for one rule (§6.5): an emptied value keeps its type. Without it an
/// empty list and an empty string render identically, read back as the same
/// type, and the kind flips between devices forever.
FmDocument parseFrontmatterRegion(
  String region, {
  Map<String, ScalarKind> priorKinds = const {},
  Set<String> priorListKeys = const {},
}) {
  if (region.isEmpty) return const FmMap([]);

  final lines = _splitLines(region);

  // Cheap region-wide disqualifiers, checked before any per-line work.
  for (final line in lines) {
    final text = line.text;
    // A second document, or an explicit document end, inside what we were
    // told is one region.
    if (text == '---' || text == '...') return FmRaw(region);
    // YAML forbids tabs in indentation; js-yaml errors, so must we.
    final firstNonSpace = text.indexOf(RegExp(r'[^ ]'));
    if (firstNonSpace > 0 && text.substring(0, firstNonSpace).contains('\t')) {
      return FmRaw(region);
    }
    if (text.startsWith('\t')) return FmRaw(region);
  }

  final entries = <FmEntry>[];
  var i = 0;
  var pendingLead = StringBuffer();

  while (i < lines.length) {
    final line = lines[i];
    final text = line.text;

    // Blank lines and whole-line comments belong to the key that follows.
    if (text.trim().isEmpty || text.trimLeft().startsWith('#')) {
      pendingLead.write(line.withNewline);
      i++;
      continue;
    }

    // Every key sits at column zero: this region is a FLAT mapping or it is
    // not a mapping we place.
    if (text.startsWith(' ')) return FmRaw(region);

    final key = _parseKey(text);
    if (key == null) return FmRaw(region);

    final valueStart = key.colonEnd;
    final parsed = _parseValue(
      region: region,
      lines: lines,
      keyLineIndex: i,
      valueStartOffset: line.start + valueStart,
      priorKind: priorKinds[key.key],
      priorIsList: priorListKeys.contains(key.key),
    );
    if (parsed == null) return FmRaw(region);

    entries.add(
      FmEntry(key: key.key, value: parsed.value, lead: pendingLead.toString()),
    );
    pendingLead = StringBuffer();
    i = parsed.nextLineIndex;
  }

  // A region holding only comments is not a mapping — it has no keys at all,
  // so there is nothing to attach them to. Consistent, not an exception.
  if (entries.isEmpty) {
    return region.trim().isEmpty ? const FmMap([]) : FmRaw(region);
  }

  return _collapseDuplicateKeys(entries, trail: pendingLead.toString());
}

/// §6.3 — the original bug, as it already exists in files on disk.
///
/// Two lists under one key merge; anything else is last-wins by position,
/// which every device computes identically because the file order is the same
/// everywhere.
FmDocument _collapseDuplicateKeys(List<FmEntry> entries, {required String trail}) {
  final byKey = <String, int>{};
  final out = <FmEntry>[];
  for (final e in entries) {
    final at = byKey[e.key];
    if (at == null) {
      byKey[e.key] = out.length;
      out.add(e);
      continue;
    }
    final existing = out[at];
    final a = existing.value;
    final b = e.value;
    if (a is FmList && b is FmList) {
      final merged = <String>[...a.items];
      for (final item in b.items) {
        if (!merged.contains(item)) merged.add(item);
      }
      out[at] = existing.copyWith(value: FmList(merged));
    } else {
      out[at] = existing.copyWith(value: b);
    }
  }
  return FmMap(out, trail: trail);
}

// ── Lines with offsets ──────────────────────────────────────────────────────

class _Line {
  _Line(this.text, this.start, this.hadNewline);

  final String text;
  final int start;
  final bool hadNewline;

  String get withNewline => hadNewline ? '$text\n' : text;
  int get end => start + text.length + (hadNewline ? 1 : 0);
}

List<_Line> _splitLines(String s) {
  final out = <_Line>[];
  var start = 0;
  while (start < s.length) {
    final nl = s.indexOf('\n', start);
    if (nl < 0) {
      out.add(_Line(s.substring(start), start, false));
      break;
    }
    out.add(_Line(s.substring(start, nl), start, true));
    start = nl + 1;
  }
  return out;
}

// ── Keys ────────────────────────────────────────────────────────────────────

class _Key {
  const _Key(this.key, this.colonEnd);

  final String key;

  /// Offset within the key's LINE, just past the colon. Where a value's raw
  /// span begins.
  final int colonEnd;
}

/// Parses `key:` at the start of [line]. Null when this is not a key line.
_Key? _parseKey(String line) {
  if (line.startsWith('"') || line.startsWith("'")) {
    final quoted = _readQuoted(line, 0);
    if (quoted == null) return null;
    var j = quoted.end;
    while (j < line.length && line[j] == ' ') {
      j++;
    }
    if (j >= line.length || line[j] != ':') return null;
    return _Key(quoted.value, j + 1);
  }
  // A plain key ends at the first colon that is followed by a space or by the
  // end of the line — YAML's own rule, and the reason `Re: text` is a key
  // named `Re` rather than a scalar.
  for (var j = 0; j < line.length; j++) {
    if (line[j] != ':') continue;
    final atEnd = j + 1 == line.length;
    if (atEnd || line[j + 1] == ' ') {
      final key = line.substring(0, j);
      if (key.isEmpty || key.trim() != key) return null;
      return _Key(key, j + 1);
    }
  }
  return null;
}

class _Quoted {
  const _Quoted(this.value, this.end);

  final String value;
  final int end;
}

/// Reads a single- or double-quoted scalar starting at [from].
_Quoted? _readQuoted(String s, int from) {
  final quote = s[from];
  final buf = StringBuffer();
  var i = from + 1;
  while (i < s.length) {
    final c = s[i];
    if (quote == '"' && c == r'\') {
      if (i + 1 >= s.length) return null;
      final next = s[i + 1];
      buf.write(switch (next) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '"' => '"',
        r'\' => r'\',
        _ => next,
      });
      i += 2;
      continue;
    }
    if (c == quote) {
      // In single quotes, '' is an escaped quote.
      if (quote == "'" && i + 1 < s.length && s[i + 1] == "'") {
        buf.write("'");
        i += 2;
        continue;
      }
      return _Quoted(buf.toString(), i + 1);
    }
    buf.write(c);
    i++;
  }
  return null;
}

// ── Values ──────────────────────────────────────────────────────────────────

class _ParsedValue {
  const _ParsedValue(this.value, this.nextLineIndex);

  final FmValue value;
  final int nextLineIndex;
}

_ParsedValue? _parseValue({
  required String region,
  required List<_Line> lines,
  required int keyLineIndex,
  required int valueStartOffset,
  required ScalarKind? priorKind,
  required bool priorIsList,
}) {
  final keyLine = lines[keyLineIndex];
  final afterColon = region.substring(valueStartOffset, keyLine.start + keyLine.text.length);
  final inline = afterColon.trimLeft();

  /// Everything from just past the colon up to the start of [untilLine],
  /// verbatim — the span [FmOpaque] is defined on.
  FmValue opaqueThrough(int untilLine) {
    final end = untilLine >= lines.length
        ? region.length
        : lines[untilLine].start;
    return FmOpaque(region.substring(valueStartOffset, end));
  }

  /// Index of the first line at column zero after the key line: where this
  /// value's block ends.
  int blockEnd() {
    var j = keyLineIndex + 1;
    while (j < lines.length) {
      final t = lines[j].text;
      if (t.trim().isEmpty) {
        // A blank line inside an indented block belongs to the block; a blank
        // line before the next key belongs to that key's lead. Decide by what
        // comes after.
        var k = j;
        while (k < lines.length && lines[k].text.trim().isEmpty) {
          k++;
        }
        if (k < lines.length && lines[k].text.startsWith(' ')) {
          j = k;
          continue;
        }
        return j;
      }
      if (!t.startsWith(' ')) return j;
      j++;
    }
    return lines.length;
  }

  // An inline comment is not modelled, and dropping it would delete text from
  // the user's file (§6.6). The opaque span already contains it.
  if (inline.isNotEmpty && _hasInlineComment(inline)) {
    return _ParsedValue(opaqueThrough(blockEnd()), blockEnd());
  }

  if (inline.isEmpty) {
    final end = blockEnd();
    if (end == keyLineIndex + 1) {
      // Nothing indented follows: an empty value. Keeping the previous kind is
      // what stops an emptied list and an emptied string from flip-flopping.
      //
      // The list case is the one that bites in practice: our renderer writes an
      // empty sequence as `key: []`, Obsidian's Properties panel rewrites it as
      // a bare `key:`, and reading that back as an empty STRING silently
      // changes the property's type — `aliases` stops being a list.
      if (priorIsList) return _ParsedValue(const FmList([]), end);
      return _ParsedValue(
        FmScalar(priorKind ?? ScalarKind.text, ''),
        end,
      );
    }
    final block = lines.sublist(keyLineIndex + 1, end);
    final list = _parseBlockList(block);
    if (list != null) return _ParsedValue(list, end);
    // Nested mapping, or anything else indented under the key.
    return _ParsedValue(opaqueThrough(end), end);
  }

  final first = inline[0];

  // Multi-line scalars, anchors, aliases, explicit tags and flow mappings all
  // carry structure this build does not place.
  if (first == '|' || first == '>' || first == '&' || first == '*' ||
      first == '!' || first == '{') {
    final end = blockEnd();
    return _ParsedValue(opaqueThrough(end), end);
  }

  if (first == '[') {
    final end = blockEnd();
    if (end != keyLineIndex + 1) return _ParsedValue(opaqueThrough(end), end);
    final flow = _parseFlowList(inline);
    if (flow == null) return _ParsedValue(opaqueThrough(end), end);
    return _ParsedValue(flow, end);
  }

  // A value that spans further lines is not a plain scalar.
  final end = blockEnd();
  if (end != keyLineIndex + 1) return _ParsedValue(opaqueThrough(end), end);

  final scalar = _parseInlineScalar(inline);
  if (scalar == null) return _ParsedValue(opaqueThrough(end), end);
  return _ParsedValue(scalar, end);
}

/// True when [s] carries a comment outside quotes — ` #` or a leading `#`.
bool _hasInlineComment(String s) {
  var inSingle = false;
  var inDouble = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == r'\' && inDouble) {
      i++;
      continue;
    }
    if (c == "'" && !inDouble) inSingle = !inSingle;
    if (c == '"' && !inSingle) inDouble = !inDouble;
    if (c == '#' && !inSingle && !inDouble && (i == 0 || s[i - 1] == ' ')) {
      return true;
    }
  }
  return false;
}

/// Parses a one-line value into a scalar. Null when it is not one.
FmScalar? _parseInlineScalar(String inline) {
  if (inline.startsWith('"') || inline.startsWith("'")) {
    final quoted = _readQuoted(inline, 0);
    if (quoted == null) return null;
    if (inline.substring(quoted.end).trim().isNotEmpty) return null;
    // Quoted means the author asked for a string, whatever it looks like.
    return FmScalar(ScalarKind.text, quoted.value);
  }
  final plain = inline.trimRight();
  if (plain.isEmpty) return null;
  // `null`/`~` is an explicit null, which is neither a value we model nor an
  // empty string. Left opaque so it round-trips untouched.
  if (plain == 'null' || plain == 'Null' || plain == 'NULL' || plain == '~') {
    return null;
  }
  // A plain scalar cannot contain `: ` — js-yaml rejects it, so must we.
  if (plain.contains(': ')) return null;
  if (ambiguousScalarTokens.contains(plain)) {
    return FmScalar(ScalarKind.text, plain);
  }
  return parseBareScalar(plain);
}

/// Parses an indented block of `- item` lines into a list of scalars.
FmList? _parseBlockList(List<_Line> block) {
  final items = <String>[];
  for (final line in block) {
    final t = line.text;
    if (t.trim().isEmpty) continue;
    final trimmed = t.trimLeft();
    if (!trimmed.startsWith('- ') && trimmed != '-') return null;
    final itemText = trimmed == '-' ? '' : trimmed.substring(2).trimLeft();
    // `- key: value` is a list of mappings.
    if (_hasInlineComment(itemText)) return null;
    final scalar = _parseInlineScalar(itemText);
    if (itemText.isEmpty) {
      items.add('');
      continue;
    }
    if (scalar == null) return null;
    items.add(scalar.text);
  }
  return FmList(items);
}

/// Parses `[a, b, "c"]` into a list of scalars. Null when it holds anything
/// that is not a scalar, or is malformed.
FmList? _parseFlowList(String inline) {
  final s = inline.trimRight();
  if (!s.startsWith('[') || !s.endsWith(']')) return null;
  final inner = s.substring(1, s.length - 1).trim();
  if (inner.isEmpty) return const FmList([]);
  if (inner.contains('{') || inner.contains('[')) return null;

  final items = <String>[];
  var buf = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  for (var i = 0; i < inner.length; i++) {
    final c = inner[i];
    if (c == r'\' && inDouble) {
      buf.write(c);
      if (i + 1 < inner.length) buf.write(inner[++i]);
      continue;
    }
    if (c == "'" && !inDouble) inSingle = !inSingle;
    if (c == '"' && !inSingle) inDouble = !inDouble;
    if (c == ',' && !inSingle && !inDouble) {
      items.add(buf.toString());
      buf = StringBuffer();
      continue;
    }
    buf.write(c);
  }
  items.add(buf.toString());

  final out = <String>[];
  for (final raw in items) {
    final item = raw.trim();
    if (item.isEmpty) return null;
    final scalar = _parseInlineScalar(item);
    if (scalar == null) return null;
    out.add(scalar.text);
  }
  return FmList(out);
}
