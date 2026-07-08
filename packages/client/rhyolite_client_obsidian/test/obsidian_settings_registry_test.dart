import 'package:rhyolite_client_obsidian/src/settings/obsidian_settings_registry.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart' show SettingsCrdtKind;
import 'package:test/test.dart';

void main() {
  SettingsResourceClass? c(String p) => ObsidianSettingsRegistry.classify(p);

  group('denylist (always wins)', () {
    test('rhyolite-sync own plugin dir is never synced', () {
      expect(c('plugins/rhyolite-sync/data.json'), isNull);
      expect(c('plugins/rhyolite-sync/main.js'), isNull);
      expect(c('.obsidian/plugins/rhyolite-sync/data.json'), isNull);
    });

    test('workspace files are device-specific and excluded', () {
      expect(c('workspace.json'), isNull);
      expect(c('workspace-mobile.json'), isNull);
      // The Workspaces core plugin's SAVED layouts (plural) are just as
      // device-specific — pane sizes, active leaves, float positions — and
      // must not sync. Field-merging + canonical rewrite (sorted/minified)
      // fought Obsidian's own format on every write, so settings re-synced
      // constantly.
      expect(c('workspaces.json'), isNull);
      expect(c('.obsidian/workspaces.json'), isNull);
    });

    test('local artefacts excluded', () {
      expect(c('plugin.db'), isNull);
      expect(c('logs.sqlite'), isNull);
      expect(c('something.log'), isNull);
    });

    test('path traversal rejected', () {
      expect(c('../secrets.json'), isNull);
    });
  });

  group('known top-level files', () {
    void expectKind(String p, SettingsCrdtKind kind, SettingsCategory cat) {
      final r = c(p)!;
      expect(r.kind, kind);
      expect(r.category, cat);
    }

    test('app/appearance/hotkeys are fieldMap', () {
      expectKind(
        'app.json',
        SettingsCrdtKind.fieldMap,
        SettingsCategory.appSettings,
      );
      expectKind(
        'appearance.json',
        SettingsCrdtKind.fieldMap,
        SettingsCategory.appearance,
      );
      expectKind(
        'hotkeys.json',
        SettingsCrdtKind.fieldMap,
        SettingsCategory.hotkeys,
      );
    });

    test('core-plugins.json is fieldMap (modern object form {id: bool})', () {
      expectKind(
        'core-plugins.json',
        SettingsCrdtKind.fieldMap,
        SettingsCategory.corePluginsEnabled,
      );
    });

    test('community-plugins.json is orSet (array of enabled ids)', () {
      expectKind(
        'community-plugins.json',
        SettingsCrdtKind.orSet,
        SettingsCategory.communityPluginsEnabled,
      );
    });

    test('leading .obsidian/ prefix is tolerated', () {
      expectKind(
        '.obsidian/app.json',
        SettingsCrdtKind.fieldMap,
        SettingsCategory.appSettings,
      );
    });

    test('unknown top-level json is core-plugin settings (fieldMap)', () {
      expectKind(
        'daily-notes.json',
        SettingsCrdtKind.fieldMap,
        SettingsCategory.corePluginSettings,
      );
      expectKind(
        'templates.json',
        SettingsCrdtKind.fieldMap,
        SettingsCategory.corePluginSettings,
      );
    });
  });

  group('plugins / themes / snippets', () {
    test(
      'community plugin data.json is wholeFile (opaque, never field-merged)',
      () {
        final r = c('plugins/dataview/data.json')!;
        expect(r.kind, SettingsCrdtKind.wholeFile);
        expect(r.category, SettingsCategory.communityPluginSettings);
      },
    );

    test('plugin code files are never synced (too large, overwrites running '
        'plugin)', () {
      for (final f in ['main.js', 'manifest.json', 'styles.css']) {
        expect(c('plugins/dataview/$f'), isNull);
      }
    });

    test('themes and snippets are wholeFile', () {
      expect(
        c('themes/Minimal/theme.css')!.category,
        SettingsCategory.themesSnippets,
      );
      expect(
        c('snippets/custom.css')!.category,
        SettingsCategory.themesSnippets,
      );
    });

    test('non-css snippet files are ignored', () {
      expect(c('snippets/readme.txt'), isNull);
    });
  });

  group('v1 defaults', () {
    test('plugin code is never synced, everything else ON by default', () {
      final d = ObsidianSettingsRegistry.defaultEnabledCategories;
      expect(d.contains(SettingsCategory.appearance), isTrue);
      expect(d.contains(SettingsCategory.communityPluginSettings), isTrue);
      // A plugin's data.json syncs by default; its code does not.
      final kindOf = ObsidianSettingsRegistry.kindOf(d);
      expect(kindOf('plugins/dataview/data.json'), isNotNull);
      expect(kindOf('plugins/dataview/main.js'), isNull);
    });
  });

  group('selective sync (kindOf)', () {
    test('only enabled categories resolve to a kind', () {
      final kindOf = ObsidianSettingsRegistry.kindOf({
        SettingsCategory.appearance,
      });
      expect(kindOf('appearance.json'), SettingsCrdtKind.fieldMap);
      expect(kindOf('hotkeys.json'), isNull); // category disabled
      expect(kindOf('plugins/rhyolite-sync/data.json'), isNull); // denylisted
    });
  });
}
