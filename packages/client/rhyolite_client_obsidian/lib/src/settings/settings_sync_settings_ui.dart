// ignore_for_file: deprecated_member_use
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart'
    show PluginSettingsTab, SettingHandle, createSetting;

import 'obsidian_settings_registry.dart';
import 'settings_sync_prefs.dart';

const _labels = <SettingsCategory, String>{
  SettingsCategory.appSettings: 'App settings',
  SettingsCategory.appearance: 'Appearance',
  SettingsCategory.hotkeys: 'Hotkeys',
  SettingsCategory.corePluginsEnabled: 'Core plugins (enabled list)',
  SettingsCategory.corePluginSettings: 'Core plugin settings',
  SettingsCategory.communityPluginsEnabled: 'Community plugins (enabled list)',
  SettingsCategory.communityPluginSettings: 'Community plugin settings',
  SettingsCategory.themesSnippets: 'Themes & snippets',
};

const _descriptions = <SettingsCategory, String>{
  SettingsCategory.appSettings: 'app.json, graph.json (editor, files & links)',
  SettingsCategory.appearance: 'Theme, dark mode, enabled snippets',
  SettingsCategory.hotkeys: 'Custom hotkeys',
  SettingsCategory.corePluginsEnabled: 'Which core plugins are enabled',
  SettingsCategory.corePluginSettings: 'Daily notes, templates, etc.',
  SettingsCategory.communityPluginsEnabled: 'Which community plugins are enabled',
  SettingsCategory.communityPluginSettings: "Each plugin's data.json",
  SettingsCategory.themesSnippets: 'Downloaded themes and CSS snippets',
};

/// Renders the "Settings sync" section into [tab] as a collapsed `<details>`
/// block (so it stays out of the way at the bottom of the tab): a master toggle
/// plus one toggle per category (shown only when the master is on).
///
/// [onChanged] is called with the updated prefs; the caller persists, relaunches
/// config sync, and refreshes the tab. Because a refresh rebuilds the whole tab,
/// the open/closed state is lifted to the caller via [expanded] /
/// [onExpandedChanged] so toggling a category does not collapse the section.
void addSettingsSyncSection(
  PluginSettingsTab tab, {
  required SettingsSyncPrefs prefs,
  required void Function(SettingsSyncPrefs next) onChanged,
  required bool expanded,
  required void Function(bool expanded) onExpandedChanged,
  void Function()? onReset,
  void Function()? onRestore,
}) {
  final details = jsu.callMethod<JSObject>(tab.containerEl, 'createEl', [
    'details',
  ]);
  jsu.setProperty(details, 'className', 'rhyolite-settings-sync');
  if (expanded) jsu.setProperty(details, 'open', true);
  // Persist the open/closed state so a tab re-render (any toggle triggers one)
  // restores it instead of snapping shut.
  jsu.callMethod<void>(details, 'addEventListener', [
    'toggle',
    jsu.allowInterop(
      (JSObject _) => onExpandedChanged(jsu.getProperty<bool>(details, 'open')),
    ),
  ]);

  final summary = jsu.callMethod<JSObject>(details, 'createEl', ['summary']);
  jsu.setProperty<Object?>(summary, 'textContent', 'Settings sync (.obsidian)');

  _toggleRow(
    details,
    name: 'Sync settings (.obsidian)',
    description:
        'Sync app settings, hotkeys, themes and plugin settings across your '
        'devices. Most changes apply after an Obsidian restart.',
    value: prefs.enabled,
    onChange: (v) => onChanged(prefs.copyWith(enabled: v)),
  );

  if (!prefs.enabled) return;

  for (final category in SettingsCategory.values) {
    _toggleRow(
      details,
      name: _labels[category] ?? category.name,
      description: _descriptions[category] ?? '',
      value: prefs.categories.contains(category),
      onChange: (v) => onChanged(prefs.withCategory(category, v)),
    );
  }

  // Force full re-send / re-download — the .obsidian analog of the notes
  // "Re-upload" / "Download from server". Tucked at the bottom of the
  // collapsed block since they are destructive and rarely needed.
  if (onReset != null) {
    _buttonRow(
      details,
      name: 'Re-upload settings from this device',
      description:
          'Use this device as the source of truth. Server settings are '
          'replaced with this device\'s .obsidian settings; other devices '
          're-sync automatically.',
      buttonText: 'Re-upload',
      onClick: onReset,
    );
  }
  if (onRestore != null) {
    _buttonRow(
      details,
      name: 'Download settings from server',
      description:
          "Replace this device's .obsidian settings with the server version. "
          'Use this if settings on this device are outdated or wrong. Most '
          'changes apply after an Obsidian restart.',
      buttonText: 'Download',
      onClick: onRestore,
    );
  }
}

/// One Obsidian setting row with a warning-styled button, built into the
/// `<details>` container (mirrors [_toggleRow]).
void _buttonRow(
  JSObject container, {
  required String name,
  required String description,
  required String buttonText,
  required void Function() onClick,
}) {
  final SettingHandle setting = createSetting(container)
    ..setName(name)
    ..setDesc(description);
  setting.addButton((button) {
    button
      ..setButtonText(buttonText)
      ..onClick(onClick);
    // Destructive styling — no wrapper for setWarning, call it on the raw
    // ButtonComponent.
    jsu.callMethod<void>(button.raw, 'setWarning', []);
  });
}

/// Builds one Obsidian setting row (name + description + toggle) directly into
/// [container] (the `<details>` element). Mirrors `PluginSettingsTab.addToggle`,
/// which can only target the tab's own container.
void _toggleRow(
  JSObject container, {
  required String name,
  required String description,
  required bool value,
  required void Function(bool) onChange,
}) {
  final SettingHandle setting = createSetting(container)
    ..setName(name)
    ..setDesc(description);
  setting.addToggle((toggle) => toggle
    ..setValue(value)
    ..onChange(onChange));
}
