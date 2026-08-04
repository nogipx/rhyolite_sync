/// The parsed, CRDT-free shape of a note's frontmatter region.
///
/// Deliberately holds no `Hlc`, no `FracIdx` and no tombstones: this is what
/// the bytes on disk MEAN, and the CRDT layer is what remembers who wrote what
/// when. Keeping them apart buys two things the spec leans on — the parser and
/// renderer are testable without a clock, and §8.6's "equality is decided on
/// the parsed model, not on bytes" has an actual type to compare.
library;

/// Which of the six Obsidian property types a scalar carries.
///
/// The kind is not decoration: it decides whether the renderer may write the
/// value bare. `text` holding "true" must be quoted, or reading it back yields
/// a checkbox.
enum ScalarKind { text, number, boolean, date, datetime }

/// A frontmatter value inside the modelled subset, or an opaque span.
sealed class FmValue {
  const FmValue();
}

/// A single scalar. [text] is the value as the USER means it — unquoted,
/// unescaped — and the renderer re-quotes only when the bare form would read
/// back as something else.
class FmScalar extends FmValue {
  const FmScalar(this.kind, this.text);

  final ScalarKind kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is FmScalar && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'FmScalar(${kind.name}, "$text")';
}

/// A sequence of scalar strings. Item identity is the item's own text, which
/// is what makes two devices adding the same tag converge on one entry rather
/// than two.
///
/// Parsed from both the block form and the flow form (`[a, b]`); the renderer
/// always emits block. See §3 — the original bug is about lists, so trading
/// per-element merge for bracket style would invert the priorities.
class FmList extends FmValue {
  const FmList(this.items);

  final List<String> items;

  @override
  bool operator ==(Object other) =>
      other is FmList &&
      other.items.length == items.length &&
      _sameOrder(other.items, items);

  static bool _sameOrder(List<String> a, List<String> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(items);

  @override
  String toString() => 'FmList($items)';
}

/// A value this build does not model, kept as the raw YAML text that followed
/// the key's colon — byte for byte, newlines and indentation included.
///
/// Covers nested mappings, multi-line scalars, lists of mappings, anchors,
/// aliases, explicit tags, and any value line carrying an inline comment
/// (§6.6). The point is that not modelling something is never a reason to lose
/// it: the key still participates in the map, so concurrent edits to OTHER
/// keys merge losslessly, and only this one value falls back to last-writer.
class FmOpaque extends FmValue {
  const FmOpaque(this.raw);

  /// Everything after the key's colon up to the next key's lead, verbatim.
  final String raw;

  @override
  bool operator ==(Object other) => other is FmOpaque && other.raw == raw;

  @override
  int get hashCode => raw.hashCode;

  @override
  String toString() => 'FmOpaque(${raw.length} chars)';
}

/// One key in a mapping-shaped region.
class FmEntry {
  const FmEntry({required this.key, required this.value, this.lead = ''});

  /// The key as parsed — any YAML string, including Cyrillic, spaces and an
  /// embedded colon. Quoting is a rendering decision, not part of identity.
  final String key;

  final FmValue value;

  /// Comments and blank lines standing immediately before this key, verbatim
  /// and including their trailing newlines. Empty for the common case.
  final String lead;

  FmEntry copyWith({String? key, FmValue? value, String? lead}) => FmEntry(
        key: key ?? this.key,
        value: value ?? this.value,
        lead: lead ?? this.lead,
      );

  @override
  bool operator ==(Object other) =>
      other is FmEntry &&
      other.key == key &&
      other.value == value &&
      other.lead == lead;

  @override
  int get hashCode => Object.hash(key, value, lead);

  @override
  String toString() => 'FmEntry($key: $value)';
}

/// A parsed frontmatter region.
sealed class FmDocument {
  const FmDocument();
}

/// The region is a flat mapping and every key was placed.
class FmMap extends FmDocument {
  const FmMap(this.entries, {this.trail = ''});

  final List<FmEntry> entries;

  /// Whatever followed the last key — comments, blank lines — verbatim.
  final String trail;

  @override
  bool operator ==(Object other) {
    if (other is! FmMap || other.trail != trail) return false;
    if (other.entries.length != entries.length) return false;
    for (var i = 0; i < entries.length; i++) {
      if (other.entries[i] != entries[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(Object.hashAll(entries), trail);

  @override
  String toString() => 'FmMap(${entries.length} keys)';
}

/// The region is not a mapping this build can place: a syntax error, a root
/// that is not a mapping, several YAML documents, tabs used for indentation,
/// or nothing but comments.
///
/// Held verbatim. In the CRDT layer this becomes its own small Fugue tree, so
/// such a region keeps exactly today's character-wise merge quality rather
/// than degrading to last-writer-wins.
class FmRaw extends FmDocument {
  const FmRaw(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is FmRaw && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'FmRaw(${text.length} chars)';
}
