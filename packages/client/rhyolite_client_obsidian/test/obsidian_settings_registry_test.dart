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
    test('community plugin data.json is jsonWholeFile (canonical, not '
        'field-merged)', () {
      final r = c('plugins/dataview/data.json')!;
      expect(r.kind, SettingsCrdtKind.jsonWholeFile);
      expect(r.category, SettingsCategory.communityPluginSettings);
    });

    test('the plugin DIRECTORY is the code resource, not its files', () {
      final r = c('plugins/dataview')!;
      expect(r.kind, SettingsCrdtKind.blobDir);
      expect(r.category, SettingsCategory.communityPluginCode);

      // Individual code files stay unclassified: they ride the directory
      // resource as one atomic unit, so a vault can never converge on main.js
      // from one release and manifest.json from another.
      for (final f in ['main.js', 'manifest.json', 'styles.css']) {
        expect(c('plugins/dataview/$f'), isNull);
      }
    });

    test('our own plugin directory is still excluded, under any past id', () {
      expect(c('plugins/rhyolite-sync'), isNull);
      expect(c('.obsidian/plugins/rhyolite-sync'), isNull);
      // The pre-rename id. Its leftover directory is still in vaults that
      // predate the move to kebab-case, and syncing our own old build would
      // overwrite the running engine on any device still on it.
      expect(c('plugins/rhyolite_sync'), isNull);
      expect(c('plugins/rhyolite_sync/main.js'), isNull);
    });

    test('plugin junk under a dir is not a resource', () {
      expect(c('plugins/dataview/cache.db'), isNull);
      expect(c('plugins/dataview/assets/icon.png'), isNull);
    });

    test('a theme is a blob-backed directory, its files are not resources', () {
      final r = c('themes/Minimal')!;
      expect(r.kind, SettingsCrdtKind.blobDir);
      expect(r.category, SettingsCategory.themesSnippets);

      // Covered by the directory: a stylesheet routinely runs past the size at
      // which inlining content into a settings record stops working.
      expect(c('themes/Minimal/theme.css'), isNull);
      expect(c('themes/Minimal/manifest.json'), isNull);
    });

    test('snippets stay whole-file — single small CSS files', () {
      final r = c('snippets/custom.css')!;
      expect(r.kind, SettingsCrdtKind.wholeFile);
      expect(r.category, SettingsCategory.themesSnippets);
    });

    test('non-css snippet files are ignored', () {
      expect(c('snippets/readme.txt'), isNull);
    });
  });

  group('v1 defaults', () {
    test('plugin code is off by default, everything else ON', () {
      final d = ObsidianSettingsRegistry.defaultEnabledCategories;
      expect(d.contains(SettingsCategory.appearance), isTrue);
      expect(d.contains(SettingsCategory.communityPluginSettings), isTrue);
      // Plugin code is two to three orders of magnitude larger than every
      // other category, so enabling settings sync must not start moving it.
      expect(d.contains(SettingsCategory.communityPluginCode), isFalse);

      final kindOf = ObsidianSettingsRegistry.kindOf(d);
      expect(kindOf('plugins/dataview/data.json'), isNotNull);
      expect(kindOf('plugins/dataview'), isNull);
    });

    test('opting in resolves the directory resource', () {
      final kindOf = ObsidianSettingsRegistry.kindOf({
        ...ObsidianSettingsRegistry.defaultEnabledCategories,
        SettingsCategory.communityPluginCode,
      });
      expect(kindOf('plugins/dataview'), SettingsCrdtKind.blobDir);
      expect(kindOf('plugins/rhyolite-sync'), isNull);
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
