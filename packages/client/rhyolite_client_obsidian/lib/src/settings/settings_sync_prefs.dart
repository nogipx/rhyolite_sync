import 'obsidian_settings_registry.dart';

/// User preferences for `.obsidian` settings sync, persisted under the
/// `settingsSync` key of the plugin's `data.json`.
///
/// Settings sync is opt-in: [enabled] defaults to false so it never starts
/// touching `.obsidian` until the user turns it on. Per-category toggles
/// default to [ObsidianSettingsRegistry.defaultEnabledCategories] (everything
/// except plugin code).
class SettingsSyncPrefs {
  const SettingsSyncPrefs({required this.enabled, required this.categories});

  final bool enabled;
  final Set<SettingsCategory> categories;

  static const dataKey = 'settingsSync';

  static SettingsSyncPrefs defaults() => SettingsSyncPrefs(
        enabled: false,
        categories: ObsidianSettingsRegistry.defaultEnabledCategories,
      );

  /// Parses prefs from the raw `data.json` map (the whole document).
  factory SettingsSyncPrefs.fromData(Object? rawData) {
    final root = rawData is Map ? rawData[dataKey] : null;
    if (root is! Map) return defaults();

    final enabled = root['enabled'] == true;
    final cats = root['categories'];
    if (cats is! List) {
      return SettingsSyncPrefs(
        enabled: enabled,
        categories: ObsidianSettingsRegistry.defaultEnabledCategories,
      );
    }
    final categories = <SettingsCategory>{};
    for (final c in cats) {
      final parsed = _parseCategory(c?.toString());
      if (parsed != null) categories.add(parsed);
    }
    return SettingsSyncPrefs(enabled: enabled, categories: categories);
  }

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'categories': categories.map((c) => c.name).toList(),
      };

  SettingsSyncPrefs copyWith({bool? enabled, Set<SettingsCategory>? categories}) =>
      SettingsSyncPrefs(
        enabled: enabled ?? this.enabled,
        categories: categories ?? this.categories,
      );

  SettingsSyncPrefs withCategory(SettingsCategory category, bool on) {
    final next = Set<SettingsCategory>.of(categories);
    if (on) {
      next.add(category);
    } else {
      next.remove(category);
    }
    return copyWith(categories: next);
  }

  static SettingsCategory? _parseCategory(String? name) {
    if (name == null) return null;
    for (final c in SettingsCategory.values) {
      if (c.name == name) return c;
    }
    return null;
  }
}
