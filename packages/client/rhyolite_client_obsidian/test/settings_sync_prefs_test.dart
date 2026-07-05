import 'package:rhyolite_client_obsidian/src/settings/obsidian_settings_registry.dart';
import 'package:rhyolite_client_obsidian/src/settings/settings_sync_prefs.dart';
import 'package:test/test.dart';

void main() {
  test('defaults: opt-in off, rest on', () {
    final d = SettingsSyncPrefs.defaults();
    expect(d.enabled, isFalse);
    expect(d.categories.contains(SettingsCategory.appearance), isTrue);
  });

  test('missing data.json key falls back to defaults', () {
    final p = SettingsSyncPrefs.fromData(null);
    expect(p.enabled, isFalse);
    expect(p.categories, SettingsSyncPrefs.defaults().categories);

    final p2 = SettingsSyncPrefs.fromData({'other': 1});
    expect(p2.enabled, isFalse);
  });

  test('round-trips through toJson/fromData', () {
    final prefs = SettingsSyncPrefs(
      enabled: true,
      categories: {SettingsCategory.hotkeys, SettingsCategory.themesSnippets},
    );
    final restored = SettingsSyncPrefs.fromData({
      SettingsSyncPrefs.dataKey: prefs.toJson(),
    });
    expect(restored.enabled, isTrue);
    expect(restored.categories,
        {SettingsCategory.hotkeys, SettingsCategory.themesSnippets});
  });

  test('unknown category names are ignored', () {
    final restored = SettingsSyncPrefs.fromData({
      SettingsSyncPrefs.dataKey: {
        'enabled': true,
        'categories': ['hotkeys', 'bogusCategory'],
      },
    });
    expect(restored.categories, {SettingsCategory.hotkeys});
  });

  test('withCategory toggles membership immutably', () {
    final base = SettingsSyncPrefs(enabled: true, categories: const {});
    final on = base.withCategory(SettingsCategory.appearance, true);
    expect(on.categories, {SettingsCategory.appearance});
    final off = on.withCategory(SettingsCategory.appearance, false);
    expect(off.categories, isEmpty);
    expect(base.categories, isEmpty); // original unchanged
  });
}
