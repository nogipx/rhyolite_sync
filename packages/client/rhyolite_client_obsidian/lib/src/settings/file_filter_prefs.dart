/// Per-device file-type sync filter, persisted under the `fileFilter` key of
/// the plugin's `data.json`.
///
/// A denylist of file extensions this device chooses NOT to sync — neither
/// uploading its own nor downloading peers'. Device-local by design (data.json
/// is not synced): each device decides what it can afford (a phone on a slow
/// link might exclude media while a desktop syncs everything). Default: empty
/// (sync everything).
class FileFilterPrefs {
  const FileFilterPrefs({required this.excludedExtensions});

  /// Lowercase extensions WITHOUT the leading dot (e.g. `pdf`, `zip`).
  final Set<String> excludedExtensions;

  static const dataKey = 'fileFilter';

  static const FileFilterPrefs none = FileFilterPrefs(excludedExtensions: {});

  factory FileFilterPrefs.fromData(Object? rawData) {
    final root = rawData is Map ? rawData[dataKey] : null;
    if (root is! Map) return none;
    final raw = root['excludedExtensions'];
    if (raw is! List) return none;
    return FileFilterPrefs(
      excludedExtensions: {
        for (final e in raw)
          if (e is String && e.trim().isNotEmpty) _normalize(e),
      },
    );
  }

  Map<String, Object?> toJson() => {
        'excludedExtensions': (excludedExtensions.toList()..sort()),
      };

  FileFilterPrefs copyWith({Set<String>? excludedExtensions}) => FileFilterPrefs(
        excludedExtensions: excludedExtensions ?? this.excludedExtensions,
      );

  /// Comma/space-separated display of the denylist, for the settings field.
  String get display => (excludedExtensions.toList()..sort()).join(', ');

  /// Parses a user string ("pdf, .zip mp4") into a normalized extension set.
  static Set<String> parse(String input) => {
        for (final part in input.split(RegExp(r'[,\s]+')))
          if (part.trim().isNotEmpty) _normalize(part),
      };

  static String _normalize(String ext) =>
      ext.trim().toLowerCase().replaceAll(RegExp(r'^\.+'), '');
}
