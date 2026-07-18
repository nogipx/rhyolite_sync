// ignore_for_file: deprecated_member_use
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart' show PluginSettingsTab;

import '../i18n/i18n.dart';
import 'obsidian_settings_registry.dart';
import 'settings_sync_prefs.dart';

String _label(SettingsCategory c) {
  switch (c) {
    case SettingsCategory.appSettings:
      return S.settingsCatAppSettings;
    case SettingsCategory.appearance:
      return S.settingsCatAppearance;
    case SettingsCategory.hotkeys:
      return S.settingsCatHotkeys;
    case SettingsCategory.corePluginsEnabled:
      return S.settingsCatCorePluginsEnabled;
    case SettingsCategory.corePluginSettings:
      return S.settingsCatCorePluginSettings;
    case SettingsCategory.communityPluginsEnabled:
      return S.settingsCatCommunityPluginsEnabled;
    case SettingsCategory.communityPluginSettings:
      return S.settingsCatCommunityPluginSettings;
    case SettingsCategory.themesSnippets:
      return S.settingsCatThemesSnippets;
  }
}

String _description(SettingsCategory c) {
  switch (c) {
    case SettingsCategory.appSettings:
      return S.settingsCatAppSettingsDesc;
    case SettingsCategory.appearance:
      return S.settingsCatAppearanceDesc;
    case SettingsCategory.hotkeys:
      return S.settingsCatHotkeysDesc;
    case SettingsCategory.corePluginsEnabled:
      return S.settingsCatCorePluginsEnabledDesc;
    case SettingsCategory.corePluginSettings:
      return S.settingsCatCorePluginSettingsDesc;
    case SettingsCategory.communityPluginsEnabled:
      return S.settingsCatCommunityPluginsEnabledDesc;
    case SettingsCategory.communityPluginSettings:
      return S.settingsCatCommunityPluginSettingsDesc;
    case SettingsCategory.themesSnippets:
      return S.settingsCatThemesSnippetsDesc;
  }
}

/// Renders the "Settings sync" section into [tab] as a normal, always-open
/// section (like the other settings sections): a master toggle plus one toggle
/// per category (shown only when the master is on), and re-upload/download
/// buttons at the bottom.
///
/// [onChanged] is called with the updated prefs; the caller persists, relaunches
/// config sync, and refreshes the tab.
void addSettingsSyncSection(
  PluginSettingsTab tab, {
  required SettingsSyncPrefs prefs,
  required void Function(SettingsSyncPrefs next) onChanged,
  void Function()? onReset,
  void Function()? onRestore,
}) {
  tab.addSection(S.settingsSyncSection);

  tab.addToggle(
    name: S.syncSettingsName,
    description: S.syncSettingsDescription,
    initialValue: prefs.enabled,
    onChange: (v) => onChanged(prefs.copyWith(enabled: v)),
  );

  if (!prefs.enabled) return;

  for (final category in SettingsCategory.values) {
    tab.addToggle(
      name: _label(category),
      description: _description(category),
      initialValue: prefs.categories.contains(category),
      onChange: (v) => onChanged(prefs.withCategory(category, v)),
    );
  }

  // Force full re-send / re-download — the .obsidian analog of the notes
  // "Re-upload" / "Download from server".
  if (onReset != null) {
    _warningButton(
      tab,
      name: S.reuploadSettingsRowName,
      description: S.reuploadSettingsRowDesc,
      buttonText: S.reupload,
      onClick: onReset,
    );
  }
  if (onRestore != null) {
    _warningButton(
      tab,
      name: S.downloadSettingsRowName,
      description: S.downloadSettingsRowDesc,
      buttonText: S.download,
      onClick: onRestore,
    );
  }
}

/// One setting row with a warning-styled button, built into the tab's own
/// container. Mirrors [PluginSettingsTab.addButton] but applies the destructive
/// (warning) style, which the friendly wrapper doesn't expose.
void _warningButton(
  PluginSettingsTab tab, {
  required String name,
  required String description,
  required String buttonText,
  required void Function() onClick,
}) {
  tab.addCustom((setting) {
    setting
      ..setName(name)
      ..setDesc(description)
      ..addButton((button) {
        button
          ..setButtonText(buttonText)
          ..onClick(onClick);
        jsu.callMethod<void>(button.raw, 'setWarning', []);
      });
  });
}
