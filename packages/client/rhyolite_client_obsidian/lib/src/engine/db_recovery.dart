// ignore_for_file: deprecated_member_use
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';

/// Shows a modal informing the user that the local database is corrupted,
/// and offers to delete it so it can be recreated on next reload.
Future<void> showDbCorruptionModal(
  PluginHandle plugin, {
  required String dbFileName,
  required String dbName,
}) async {
  final confirmed = await showModalWith<bool>(
    plugin,
    build: (ctx) {
      ctx.h3('Database Corrupted');
      ctx.spaceVertical(px: 12);
      ctx.createEl(
        'p',
        text: 'The local sync database is corrupted and cannot be used.',
      );
      ctx.spaceVertical(px: 8);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text:
            'This can happen after a crash or an interrupted write. '
            'Resetting the database will delete local cached data — '
            'your files and server data are not affected. '
            'After reset, the plugin will reload and re-sync from the server.',
      );
      ctx.spaceVertical(px: 16);
      ctx.buttonRow([
        ButtonSpec(
          'Reset Database',
          () => ctx.close(true),
          variant: ButtonVariant.destructive,
        ),
        ButtonSpec('Cancel', () => ctx.close(false)),
      ]);
      ctx.onEscape(() => ctx.close(false));
    },
  );

  if (confirmed != true) return;

  await _deleteDb(dbFileName: dbFileName, dbName: dbName);
  reloadPlugin(plugin);
}

/// Attempts to delete the database file from OPFS, then falls back to IndexedDB.
Future<void> _deleteDb({
  required String dbFileName,
  required String dbName,
}) async {
  // Try OPFS first.
  try {
    final storage = jsu.getProperty<Object?>(jsu.globalThis, 'navigator');
    if (storage != null) {
      final storageManager = jsu.getProperty<Object?>(storage, 'storage');
      if (storageManager != null) {
        final rootHandle = await jsu.promiseToFuture<Object>(
          jsu.callMethod<Object>(storageManager, 'getDirectory', []),
        );
        await jsu.promiseToFuture<void>(
          jsu.callMethod<Object>(rootHandle, 'removeEntry', [dbFileName]),
        );
        return;
      }
    }
  } catch (_) {
    // OPFS not available or file not found — fall through to IndexedDB.
  }

  // Fallback: delete IndexedDB database.
  try {
    final idb = jsu.getProperty<Object?>(jsu.globalThis, 'indexedDB');
    if (idb != null) {
      jsu.callMethod<Object?>(idb, 'deleteDatabase', [dbName]);
    }
  } catch (_) {
    // Best-effort.
  }
}

/// Reloads the plugin by disabling and re-enabling it via Obsidian's plugin manager.
void reloadPlugin(PluginHandle plugin) {
  try {
    final manifest = jsu.getProperty<Object?>(
      (plugin.raw as Object),
      'manifest',
    );
    if (manifest == null) return;
    final id = jsu.getProperty<String?>(manifest, 'id');
    if (id == null) return;

    final plugins = jsu.getProperty<Object?>(plugin.appRaw, 'plugins');
    if (plugins == null) return;

    jsu.callMethod<Object?>(plugins, 'disablePlugin', [id]);
    jsu.callMethod<Object?>(plugins, 'enablePlugin', [id]);
  } catch (_) {
    // Last resort: hard reload.
    jsu.callMethod<Object?>(jsu.globalThis, 'location.reload', []);
  }
}
