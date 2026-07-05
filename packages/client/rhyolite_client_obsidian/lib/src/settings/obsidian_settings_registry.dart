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
/// The rhyolite_sync self-exclusion and `workspace*.json` exclusion are
/// load-bearing safety invariants: syncing our own plugin would overwrite the
/// running engine and its credentials; `workspace.json` is device-specific and
/// changes on every interaction.
class ObsidianSettingsRegistry {
  const ObsidianSettingsRegistry._();

  static const selfPluginId = 'rhyolite_sync';

  /// Categories enabled by default. Plugin *code* (`main.js`/`manifest.json`/
  /// `styles.css`) is intentionally NOT a sync category at all: those files are
  /// multi-MB and overwrite a running plugin (Obsidian has no hot-reload). The
  /// enabled list + plugin settings are enough to provision a new device —
  /// Obsidian reinstalls the plugins themselves.
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
    if (rel == 'workspace.json' || rel == 'workspace-mobile.json') return null;
    if (segs.first == 'plugins' &&
        segs.length >= 2 &&
        segs[1] == selfPluginId) {
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

    // --- plugins/<id>/... ---
    if (segs.first == 'plugins' && segs.length >= 3) {
      final file = segs.last;
      if (file == 'data.json') {
        return const SettingsResourceClass(
          SettingsCrdtKind.wholeFile,
          SettingsCategory.communityPluginSettings,
        );
      }
      // Plugin code (main.js/manifest.json/styles.css) and everything else
      // under a plugin dir is never synced — too large, and overwrites a
      // running plugin. Obsidian reinstalls plugins from the enabled list.
      return null;
    }

    // --- themes / snippets (downloaded CSS) ---
    if (segs.first == 'themes' && segs.length >= 2) {
      return const SettingsResourceClass(
        SettingsCrdtKind.wholeFile,
        SettingsCategory.themesSnippets,
      );
    }
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
