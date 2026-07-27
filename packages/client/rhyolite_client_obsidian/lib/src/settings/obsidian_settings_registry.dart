import 'package:rhyolite_sync/rhyolite_sync.dart' show SettingsCrdtKind;

/// Selective-sync categories, mirroring the Obsidian Sync toggle set.
enum SettingsCategory {
  appSettings, // app.json, graph.json
  appearance, // appearance.json (theme, dark mode, enabled snippets)
  hotkeys, // hotkeys.json
  corePluginsEnabled, // core-plugins.json
  corePluginSettings, // daily-notes.json, templates.json, ... (other *.json)
  communityPluginsEnabled, // community-plugins.json
  communityPluginSettings, // plugins/<id>/data.json
  communityPluginCode, // plugins/<id>/{manifest.json,main.js,styles.css}
  themesSnippets, // themes/**, snippets/*.css
}

/// The merge kind + category for one `.obsidian` resource.
class SettingsResourceClass {
  const SettingsResourceClass(this.kind, this.category);
  final SettingsCrdtKind kind;
  final SettingsCategory category;
}

/// Classifies `.obsidian` paths into sync resources. Pure path logic, no IO.
///
/// The rhyolite-sync self-exclusion and `workspace*.json` exclusion are
/// load-bearing safety invariants: syncing our own plugin would overwrite the
/// running engine and its credentials; `workspace.json` is device-specific and
/// changes on every interaction.
class ObsidianSettingsRegistry {
  const ObsidianSettingsRegistry._();

  static const selfPluginId = 'rhyolite-sync';

  /// Every directory name this plugin has ever installed under.
  ///
  /// `rhyolite_sync` is the pre-rename id (Obsidian rejects underscores at
  /// submission, so the plugin moved to kebab-case) and its directory is still
  /// sitting in vaults that predate the change. Matching only the current id
  /// would leave that one classified as an ordinary community plugin: we would
  /// sync OUR OWN old build into the vault, and on a device still running it
  /// the apply path would overwrite the live engine's `main.js` and cycle it —
  /// exactly what self-exclusion exists to prevent. Harmless today only
  /// because the leftover directory happens to be empty.
  static const selfPluginIds = <String>{'rhyolite-sync', 'rhyolite_sync'};

  /// Categories enabled by default.
  ///
  /// [SettingsCategory.communityPluginCode] is deliberately absent. Every other
  /// category is kilobytes of JSON; plugin code is tens to hundreds of
  /// megabytes, two to three orders of magnitude more. Turning settings sync on
  /// must not silently start moving that much data (and, on the managed free
  /// tier, blow the storage quota mid-transfer). It is its own opt-in.
  static const defaultEnabledCategories = <SettingsCategory>{
    SettingsCategory.appSettings,
    SettingsCategory.appearance,
    SettingsCategory.hotkeys,
    SettingsCategory.corePluginsEnabled,
    SettingsCategory.corePluginSettings,
    SettingsCategory.communityPluginsEnabled,
    SettingsCategory.communityPluginSettings,
    SettingsCategory.themesSnippets,
  };

  /// Returns the resource class for [path] (which may be vault-relative with a
  /// leading `.obsidian/`, or already config-dir-relative), or null when the
  /// path must never be synced.
  static SettingsResourceClass? classify(String path) {
    final norm = path.replaceAll('\\', '/');
    final rel = norm.startsWith('.obsidian/') ? norm.substring(10) : norm;
    if (rel.isEmpty || rel.contains('..')) return null;
    final segs = rel.split('/');

    // --- denylist: always wins ---
    // `workspace.json` (current layout) AND `workspaces.json` (the Workspaces
    // core plugin's saved named layouts) are both device-specific — pane
    // sizes, active leaves, float positions — and change on every interaction.
    // Field-merging + canonical rewrite fought Obsidian's own natural-order
    // format on every write, causing a constant settings re-sync loop.
    if (rel == 'workspace.json' ||
        rel == 'workspaces.json' ||
        rel == 'workspace-mobile.json') {
      return null;
    }
    if (segs.first == 'plugins' &&
        segs.length >= 2 &&
        selfPluginIds.contains(segs[1])) {
      return null;
    }
    if (rel.endsWith('.db') ||
        rel.endsWith('.log') ||
        rel.endsWith('.sqlite') ||
        rel.endsWith('.sqlite-journal')) {
      return null;
    }

    // --- exact top-level files ---
    switch (rel) {
      case 'app.json':
      case 'graph.json':
        return const SettingsResourceClass(
          SettingsCrdtKind.fieldMap,
          SettingsCategory.appSettings,
        );
      case 'appearance.json':
        return const SettingsResourceClass(
          SettingsCrdtKind.fieldMap,
          SettingsCategory.appearance,
        );
      case 'hotkeys.json':
        return const SettingsResourceClass(
          SettingsCrdtKind.fieldMap,
          SettingsCategory.hotkeys,
        );
      case 'core-plugins.json':
        // Modern Obsidian stores this as an object `{id: bool}` (the legacy
        // array form is long migrated). fieldMap merges per-plugin: concurrent
        // toggles of different plugins both survive, same plugin is LWW.
        return const SettingsResourceClass(
          SettingsCrdtKind.fieldMap,
          SettingsCategory.corePluginsEnabled,
        );
      case 'community-plugins.json':
        return const SettingsResourceClass(
          SettingsCrdtKind.orSet,
          SettingsCategory.communityPluginsEnabled,
        );
    }

    // --- plugins/<id> (the install itself) ---
    // The whole directory is ONE resource: its three code files move together
    // as a blob-backed unit. Per-file records could converge on `main.js` from
    // one release and `manifest.json` from another — a torn install that
    // breaks Obsidian's plugin updater.
    if (segs.first == 'plugins' && segs.length == 2) {
      return const SettingsResourceClass(
        SettingsCrdtKind.blobDir,
        SettingsCategory.communityPluginCode,
      );
    }

    // --- plugins/<id>/... ---
    if (segs.first == 'plugins' && segs.length >= 3) {
      final file = segs.last;
      if (file == 'data.json') {
        // JSON we don't field-merge (unknown schema), but stored canonically so
        // Obsidian re-serializing it (insertion-order keys, platform-dependent
        // indentation) doesn't churn the sync. Opaque CSS below stays wholeFile.
        //
        // Deliberately NOT part of the directory resource above: plugin state
        // merges per-field across devices, and a whole-directory LWW would keep
        // overwriting that merge.
        return const SettingsResourceClass(
          SettingsCrdtKind.jsonWholeFile,
          SettingsCategory.communityPluginSettings,
        );
      }
      // Individual code files are covered by the directory resource; anything
      // else under a plugin dir (caches, databases, downloaded assets) is
      // device-local junk of unbounded size and is never synced.
      return null;
    }

    // --- themes/<name> (the theme itself) ---
    // Blob-backed like a plugin directory, and for the same reason: a theme's
    // stylesheet routinely runs past a megabyte, which is where inlining
    // content into a settings record stops working. As one unit, so a theme
    // can never converge on a stylesheet from one release with the manifest
    // from another.
    if (segs.first == 'themes' && segs.length == 2) {
      return const SettingsResourceClass(
        SettingsCrdtKind.blobDir,
        SettingsCategory.themesSnippets,
      );
    }
    // Files inside a theme ride the directory resource above.
    if (segs.first == 'themes' && segs.length >= 3) return null;
    if (segs.first == 'snippets' && rel.endsWith('.css')) {
      return const SettingsResourceClass(
        SettingsCrdtKind.wholeFile,
        SettingsCategory.themesSnippets,
      );
    }

    // --- generic core-plugin settings: any other top-level *.json ---
    if (segs.length == 1 && rel.endsWith('.json')) {
      return const SettingsResourceClass(
        SettingsCrdtKind.fieldMap,
        SettingsCategory.corePluginSettings,
      );
    }

    return null;
  }

  /// Builds a `kindOf` classifier for [SettingsSync] that also enforces
  /// selective sync: a resource is synced only when its category is enabled.
  static SettingsCrdtKind? Function(String) kindOf(
    Set<SettingsCategory> enabled,
  ) {
    return (resourceId) {
      final c = classify(resourceId);
      if (c == null || !enabled.contains(c.category)) return null;
      return c.kind;
    };
  }
}
