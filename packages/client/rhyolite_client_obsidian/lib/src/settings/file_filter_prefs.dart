import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Per-device sync filter, persisted under the `fileFilter` key of the
/// plugin's `data.json`.
///
/// Two independent axes, both device-local by design (data.json is not
/// synced), so each device decides what it can afford — a phone on a slow link
/// might carry only `Work/` and skip media while the desktop carries the whole
/// vault:
///   * [excludedExtensions] — file types this device skips.
///   * [pathScope] — the folders this device syncs, and holes punched in them.
///
/// Both default to empty, which means "sync everything". Neither is
/// destructive: a file the filter turns away stays on disk, stays on the
/// server, and keeps syncing on every other device.
class FileFilterPrefs {
  FileFilterPrefs({required this.excludedExtensions, PathScope? pathScope})
    : pathScope = pathScope ?? PathScope.everything;

  /// Lowercase extensions WITHOUT the leading dot (e.g. `pdf`, `zip`).
  final Set<String> excludedExtensions;

  /// Folder allowlist + denylist. [PathScope.everything] means no restriction.
  final PathScope pathScope;

  static const dataKey = 'fileFilter';

  static final FileFilterPrefs none = FileFilterPrefs(
    excludedExtensions: const {},
  );

  factory FileFilterPrefs.fromData(Object? rawData) {
    final root = rawData is Map ? rawData[dataKey] : null;
    if (root is! Map) return none;
    final raw = root['excludedExtensions'];
    return FileFilterPrefs(
      excludedExtensions: {
        if (raw is List)
          for (final e in raw)
            if (e is String && e.trim().isNotEmpty) _normalize(e),
      },
      // Reads the same `includePaths` / `excludePaths` keys PathScope writes.
      // A data.json predating the folder filter simply has neither, which
      // decodes to "the whole vault" — the behaviour that shipped before.
      pathScope: PathScope.fromJson(root),
    );
  }

  Map<String, Object?> toJson() => {
    'excludedExtensions': (excludedExtensions.toList()..sort()),
    ...pathScope.toJson(),
  };

  FileFilterPrefs copyWith({
    Set<String>? excludedExtensions,
    PathScope? pathScope,
  }) => FileFilterPrefs(
    excludedExtensions: excludedExtensions ?? this.excludedExtensions,
    pathScope: pathScope ?? this.pathScope,
  );

  /// Comma/space-separated display of the denylist, for the settings field.
  String get display => render(excludedExtensions);

  /// Stable comma-separated rendering of any extension set.
  static String render(Set<String> extensions) =>
      (extensions.toList()..sort()).join(', ');

  /// Parses a user string ("pdf, .zip mp4") into a normalized extension set.
  static Set<String> parse(String input) => {
    for (final part in input.split(RegExp(r'[,\s]+')))
      if (part.trim().isNotEmpty) _normalize(part),
  };

  static String _normalize(String ext) =>
      ext.trim().toLowerCase().replaceAll(RegExp(r'^\.+'), '');
}
