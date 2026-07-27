import 'package:rhyolite_client_obsidian/src/settings/synced_dir_kind.dart';
import 'package:test/test.dart';

void main() {
  group('idOf — the only sanctioned source of a directory name', () {
    test('extracts the id of its own folder', () {
      expect(SyncedDirKind.plugin.idOf('plugins/dataview'), 'dataview');
      expect(SyncedDirKind.theme.idOf('themes/Minimal'), 'Minimal');
    });

    test('refuses anything that is not one safe path segment', () {
      // The apply path builds `.obsidian/<folder>/<id>/<file>` from this, so a
      // separator or a traversal here escapes the directory entirely.
      for (final id in ['..', '.', 'a/b', '../../etc', '', '.hidden']) {
        expect(SyncedDirKind.plugin.idOf('plugins/$id'), isNull, reason: id);
      }
    });

    test('refuses a resource id belonging to another folder', () {
      expect(SyncedDirKind.plugin.idOf('themes/Minimal'), isNull);
      expect(SyncedDirKind.theme.idOf('plugins/dataview'), isNull);
      expect(SyncedDirKind.plugin.idOf('app.json'), isNull);
    });
  });

  group('forResource', () {
    test('maps a resource id to its kind', () {
      expect(SyncedDirKind.forResource('plugins/x'), SyncedDirKind.plugin);
      expect(SyncedDirKind.forResource('themes/x'), SyncedDirKind.theme);
      expect(SyncedDirKind.forResource('snippets/x.css'), isNull);
      expect(SyncedDirKind.forResource('app.json'), isNull);
    });
  });

  group('isSafeDirName', () {
    test('accepts real plugin and theme directory names', () {
      for (final n in ['dataview', 'obsidian-excalidraw-plugin', 'Minimal']) {
        expect(SyncedDirKind.isSafeDirName(n), isTrue, reason: n);
      }
    });

    test('rejects separators, traversal and dotfiles', () {
      for (final n in ['', '.', '..', 'a/b', r'a\b', '.git']) {
        expect(SyncedDirKind.isSafeDirName(n), isFalse, reason: n);
      }
    });
  });
}
