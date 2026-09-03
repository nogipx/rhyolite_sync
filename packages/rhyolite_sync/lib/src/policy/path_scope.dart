import 'package:rhyolite_core/rhyolite_core.dart';

/// NOT domain, deliberately: this is the one rule in the system where two
/// devices disagreeing is CORRECT. Everything in rhyolite_core answers a
/// question that must come out identical everywhere or the vaults diverge —
/// how content is chunked, what a file is called, which resolver it takes. A
/// scope answers "what does THIS device bother with", and a phone carrying
/// only `Work/` while the desktop carries everything is the feature, not a
/// fault. Policy, applied by the harness at its edges.
///
/// Per-device folder filter: which vault-relative paths this device syncs.
///
/// Two lists, both optional:
///   * [include] — an ALLOWLIST. When non-empty, only paths inside these
///     folders (or exactly equal to these files) are synced; everything else
///     is invisible to this device. Empty means "the whole vault".
///   * [exclude] — a denylist applied after [include]. Lets a user say
///     "sync `Work/`, but not `Work/scratch/`".
///
/// Device-local by design, exactly like the extension denylist
/// ([`FileFilterPrefs`] in the plugin): a phone can carry only `Work/` while
/// the desktop carries everything. Nothing here is pushed to the server, so a
/// path leaving this device's scope is NOT a delete — the file stays on disk,
/// stays on the server, and peers are unaffected. It simply stops being
/// tracked here until the scope widens again.
///
/// Matching is prefix-by-segment, not glob: an entry `Work` matches `Work`
/// itself and everything under `Work/`, but never `Workbench/notes.md`.
/// Comparison is case-insensitive so a user typing `work` on a case-preserving
/// filesystem (macOS, Windows) still gets their `Work` folder — over-admitting
/// on a case-sensitive filesystem is harmless, silently syncing nothing is not.
class PathScope {
  PathScope({
    Iterable<String> include = const <String>[],
    Iterable<String> exclude = const <String>[],
  }) : include = _normalizeAll(include),
       exclude = _normalizeAll(exclude);

  /// Bypasses normalization so [everything] can be a compile-time constant and
  /// serve as a default parameter value in const constructors.
  const PathScope._raw(this.include, this.exclude);

  /// The whole vault — no filtering. The default everywhere.
  static const PathScope everything = PathScope._raw(<String>{}, <String>{});

  /// Normalized allowlist entries (NFC, no leading/trailing slash, no
  /// duplicate separators). Empty = the whole vault is in scope.
  final Set<String> include;

  /// Normalized denylist entries, applied on top of [include].
  final Set<String> exclude;

  /// True when this scope admits every path — the hot-path short-circuit.
  bool get isUnrestricted => include.isEmpty && exclude.isEmpty;

  /// Whether [relPath] (a vault-relative path, already NFC-normalized by
  /// [normalizeVaultPath]) is synced on this device.
  bool allows(String relPath) {
    if (isUnrestricted) return true;
    final lower = relPath.toLowerCase();
    if (include.isNotEmpty && !_matchesAny(lower, include)) return false;
    if (exclude.isNotEmpty && _matchesAny(lower, exclude)) return false;
    return true;
  }

  static bool _matchesAny(String lowerPath, Set<String> entries) {
    for (final entry in entries) {
      final e = entry.toLowerCase();
      if (lowerPath == e) return true;
      if (lowerPath.length > e.length &&
          lowerPath[e.length] == '/' &&
          lowerPath.startsWith(e)) {
        return true;
      }
    }
    return false;
  }

  /// Parses a user-entered list — comma or newline separated, e.g.
  /// `Work, Personal/Journal`. Blank entries are dropped; a lone `/` (the
  /// vault root) is dropped too, since "include the root" is the same as no
  /// filter at all and keeping it would silently defeat the allowlist.
  static Set<String> parse(String input) =>
      _normalizeAll(input.split(RegExp(r'[,\n]')));

  /// Comma-separated rendering for the settings field, stable across saves.
  static String render(Set<String> entries) =>
      (entries.toList()..sort()).join(', ');

  String get includeDisplay => render(include);
  String get excludeDisplay => render(exclude);

  PathScope copyWith({Set<String>? include, Set<String>? exclude}) => PathScope(
    include: include ?? this.include,
    exclude: exclude ?? this.exclude,
  );

  Map<String, Object?> toJson() => {
    'includePaths': (include.toList()..sort()),
    'excludePaths': (exclude.toList()..sort()),
  };

  factory PathScope.fromJson(Object? raw) {
    if (raw is! Map) return PathScope();
    final inc = raw['includePaths'];
    final exc = raw['excludePaths'];
    return PathScope(
      include: inc is List ? inc.whereType<String>() : const <String>[],
      exclude: exc is List ? exc.whereType<String>() : const <String>[],
    );
  }

  /// Normalizes one user-supplied entry, or null when it carries no location.
  ///
  /// Strips surrounding whitespace and slashes, collapses `//`, and NFC-folds
  /// so an entry typed on macOS (which hands back decomposed filenames)
  /// matches the NFC paths the engine stores — the same split that once turned
  /// one Russian-named file into two file ids.
  static String? normalizeEntry(String raw) {
    final collapsed = normalizeVaultPath(
      raw.trim(),
    ).replaceAll(r'\', '/').replaceAll(RegExp(r'/+'), '/');
    final trimmed = collapsed.replaceAll(RegExp(r'^/+|/+$'), '').trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static Set<String> _normalizeAll(Iterable<String> raw) {
    final out = <String>{};
    for (final entry in raw) {
      final normalized = normalizeEntry(entry);
      if (normalized != null) out.add(normalized);
    }
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is PathScope &&
      _setEquals(include, other.include) &&
      _setEquals(exclude, other.exclude);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(include),
    Object.hashAllUnordered(exclude),
  );

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  String toString() => isUnrestricted
      ? 'PathScope(everything)'
      : 'PathScope(include: {${includeDisplay}}, exclude: {${excludeDisplay}})';
}
