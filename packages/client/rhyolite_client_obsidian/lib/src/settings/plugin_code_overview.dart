/// One plugin as the UI sees it: what the vault holds, and how this device
/// compares.
class PluginCodeRow {
  const PluginCodeRow({
    required this.resourceId,
    required this.pluginId,
    required this.isTheme,
    required this.sizeBytes,
    this.vaultVersion,
    this.localVersion,
    this.updatedBy,
    this.updatedAtMs = 0,
    this.desktopOnly = false,
  });

  /// Full settings resource id (`plugins/<id>` or `themes/<name>`) — what the
  /// remove action needs, since both kinds are removable the same way.
  final String resourceId;

  final String pluginId;

  /// A theme rather than a community plugin. They share the whole transport
  /// and differ only in labelling and in having no enabled-list to consult.
  final bool isTheme;

  /// Total size of the plugin's files as the vault holds them.
  final int sizeBytes;

  /// Version the vault converged on.
  final String? vaultVersion;

  /// Version installed on this device, read from its own `manifest.json`.
  /// Null when the plugin is not installed here.
  final String? localVersion;

  /// Device that captured the vault's current version.
  final String? updatedBy;

  final int updatedAtMs;

  final bool desktopOnly;

  /// Not on this device at all — either it has not been pulled yet, or it was
  /// deliberately skipped (a desktop-only plugin on mobile).
  bool get missingHere => localVersion == null;

  /// Installed here, but at a different version than the vault's. Both
  /// directions count: this device may be behind a pull, or ahead of a push.
  bool get differsHere =>
      localVersion != null &&
      vaultVersion != null &&
      localVersion != vaultVersion;
}

/// What the vault holds in plugin code, ready to render.
class PluginCodeOverview {
  const PluginCodeOverview(this.entries);

  /// Every blob-backed directory the vault carries, plugins and themes alike.
  final List<PluginCodeRow> entries;

  static const empty = PluginCodeOverview(<PluginCodeRow>[]);

  bool get isEmpty => entries.isEmpty;

  int get count => entries.length;

  int get totalBytes => entries.fold(0, (a, p) => a + p.sizeBytes);

  List<PluginCodeRow> get plugins =>
      entries.where((e) => !e.isTheme).toList(growable: false);

  List<PluginCodeRow> get themes =>
      entries.where((e) => e.isTheme).toList(growable: false);

  /// Plugins whose local copy does not match the vault. What the user would
  /// want flagged: the rest is in sync and needs no attention.
  Iterable<PluginCodeRow> get outOfSyncHere =>
      entries.where((p) => p.missingHere || p.differsHere);
}
