import 'package:rhyolite_sync/rhyolite_sync.dart'
    show pluginCodeFileNames, themeFileNames;

/// What kind of `.obsidian` directory a blob-backed resource is.
///
/// Plugins and themes are the same problem — a small fixed set of files, at
/// least one of which is far too large to inline into a settings record — and
/// differ only in the folder they live in, which files they carry, and whether
/// Obsidian needs to be told to reload them.
class SyncedDirKind {
  const SyncedDirKind._({
    required this.folder,
    required this.fileNames,
    required this.entryFile,
    required this.reloadable,
  });

  /// Community plugin: `manifest.json` + `main.js` + optional `styles.css`.
  static const plugin = SyncedDirKind._(
    folder: 'plugins',
    fileNames: pluginCodeFileNames,
    entryFile: 'main.js',
    reloadable: true,
  );

  /// Theme: `manifest.json` + `theme.css`. Obsidian watches theme files and
  /// re-applies the CSS itself, so there is nothing to cycle.
  static const theme = SyncedDirKind._(
    folder: 'themes',
    fileNames: themeFileNames,
    entryFile: 'theme.css',
    reloadable: false,
  );

  final String folder;
  final List<String> fileNames;

  /// The file whose absence means the directory is not a usable install — a
  /// leftover, or a download still in flight. Capturing one would propagate the
  /// breakage to every device.
  final String entryFile;

  final bool reloadable;

  /// The kind a `plugins/<id>` or `themes/<name>` resource id denotes.
  static SyncedDirKind? forResource(String resourceId) {
    if (resourceId.startsWith('${plugin.folder}/')) return plugin;
    if (resourceId.startsWith('${theme.folder}/')) return theme;
    return null;
  }

  /// `<id>` out of `<folder>/<id>`; null for anything else.
  ///
  /// This is the ONLY sanctioned source of a directory name, because it is the
  /// only one that has been through [ObsidianSettingsRegistry.classify] — which
  /// rejects `..` and our own plugin's ids. Anything taken from record content
  /// instead has been through nothing at all.
  String? idOf(String resourceId) {
    final prefix = '$folder/';
    if (!resourceId.startsWith(prefix)) return null;
    final id = resourceId.substring(prefix.length);
    return isSafeDirName(id) ? id : null;
  }

  /// Whether [name] is usable as a single on-disk directory segment: no
  /// separators, no traversal, no absolute path, no leading dot.
  static bool isSafeDirName(String name) =>
      name.isNotEmpty &&
      !name.startsWith('.') &&
      !name.contains('/') &&
      !name.contains(r'\') &&
      !name.contains('\u0000');
}
