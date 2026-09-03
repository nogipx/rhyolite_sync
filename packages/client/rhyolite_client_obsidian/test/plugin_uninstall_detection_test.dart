import 'package:rhyolite_client_obsidian/src/settings/plugin_uninstall_detection.dart';
import 'package:test/test.dart';

void main() {
  PluginUninstallDecision decide({
    List<String> vault = const ['dataview'],
    Set<String>? dirs = const {},
    Set<String>? enabled = const {},
    Set<String> hadHere = const {'dataview'},
  }) => detectPluginUninstalls(
    vaultPluginIds: vault,
    installedDirs: dirs,
    enabledInVault: enabled,
    hadItHere: hadHere.contains,
  );

  test(
    'a plugin removed from disk and from the enabled set is uninstalled',
    () {
      final d = decide();
      expect(d.aborted, isFalse);
      expect(d.tombstone, ['dataview']);
    },
  );

  group('guards', () {
    test('a failed listing concludes nothing', () {
      // The difference between "no plugins" and "could not look" is the whole
      // safety of this: flattening it would delete every plugin everywhere.
      final d = decide(dirs: null);
      expect(d.aborted, isTrue);
      expect(d.tombstone, isEmpty);
    });

    test('no enabled list means no corroboration', () {
      final d = decide(enabled: null);
      expect(d.aborted, isTrue);
    });

    test('still on disk here is not an uninstall', () {
      expect(decide(dirs: {'dataview'}).tombstone, isEmpty);
    });

    test('still enabled in the vault is not an uninstall', () {
      // Absent from disk but the vault wants it enabled = not downloaded yet.
      expect(decide(enabled: {'dataview'}).tombstone, isEmpty);
    });

    test('a device that never had it has no say', () {
      // A fresh device, or a phone that skipped a desktop-only plugin: the
      // directory is missing for a reason that has nothing to do with intent.
      expect(decide(hadHere: const {}).tombstone, isEmpty);
    });
  });

  group('mass-removal backstop', () {
    List<String> ids(int n) => [for (var i = 0; i < n; i++) 'p$i'];

    test('refuses when most of the vault would go at once', () {
      final all = ids(30);
      final d = decide(vault: all, hadHere: all.toSet());
      expect(d.aborted, isTrue);
      expect(d.abortReason, contains('30 of 30'));
      expect(d.tombstone, isEmpty);
    });

    test('allows an ordinary spree', () {
      final all = ids(30);
      final d = decide(
        vault: all,
        dirs: all.skip(5).toSet(), // five actually uninstalled
        hadHere: all.toSet(),
      );
      expect(d.aborted, isFalse);
      expect(d.tombstone, hasLength(5));
    });

    test('a small vault can still lose all of its plugins', () {
      // With two plugins installed, removing both is entirely plausible — the
      // proportional cap must not make small vaults un-manageable.
      final all = ids(2);
      final d = decide(vault: all, hadHere: all.toSet());
      expect(d.aborted, isFalse);
      expect(d.tombstone, hasLength(2));
    });
  });

  test('nothing to do reports no abort', () {
    final d = decide(vault: const []);
    expect(d.aborted, isFalse);
    expect(d.tombstone, isEmpty);
  });

  test('output is deterministic', () {
    final d = decide(
      vault: const ['zeta', 'alpha'],
      hadHere: const {'zeta', 'alpha'},
    );
    expect(d.tombstone, ['alpha', 'zeta']);
  });

  group('themes: no enabled list to corroborate with', () {
    PluginUninstallDecision decideTheme({
      List<String> vault = const ['Minimal'],
      Set<String>? dirs = const {},
      Set<String> hadHere = const {'Minimal'},
    }) => detectPluginUninstalls(
      vaultPluginIds: vault,
      installedDirs: dirs,
      enabledInVault: null,
      requiresEnabledList: false,
      hadItHere: hadHere.contains,
    );

    test('a removed theme is concluded without one', () {
      // Obsidian records the SELECTED theme, never the installed set, so there
      // is nothing to corroborate with and waiting for one means never
      // concluding anything.
      final d = decideTheme();
      expect(d.aborted, isFalse);
      expect(d.tombstone, ['Minimal']);
    });

    test('the remaining guards still hold', () {
      expect(
        decideTheme(dirs: null).aborted,
        isTrue,
        reason: 'a failed listing still concludes nothing',
      );
      expect(
        decideTheme(dirs: {'Minimal'}).tombstone,
        isEmpty,
        reason: 'still on disk here',
      );
      expect(
        decideTheme(hadHere: const {}).tombstone,
        isEmpty,
        reason: 'a device that never had it has no say',
      );
    });

    test('plugins still refuse without the list', () {
      // Same inputs, but the kind that HAS a list: its absence means we cannot
      // see the signal, which is different from there being none.
      final d = detectPluginUninstalls(
        vaultPluginIds: const ['dataview'],
        installedDirs: const {},
        enabledInVault: null,
        hadItHere: (_) => true,
      );
      expect(d.aborted, isTrue);
      expect(d.tombstone, isEmpty);
    });
  });
}
