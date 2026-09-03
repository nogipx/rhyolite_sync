// ignore_for_file: deprecated_member_use
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';

import '../i18n/i18n.dart';

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
      ctx.h3(S.dbRecoveryTitle);
      ctx.spaceVertical(px: 12);
      ctx.createEl('p', text: S.dbCorruptedText);
      ctx.spaceVertical(px: 8);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: S.dbRecoveryDescription,
      );
      ctx.spaceVertical(px: 16);
      ctx.buttonRow([
        ButtonSpec(
          S.resetDatabase,
          () => ctx.close(true),
          variant: ButtonVariant.destructive,
        ),
        ButtonSpec(S.cancel, () => ctx.close(false)),
      ]);
      ctx.onEscape(() => ctx.close(false));
    },
  );

  if (confirmed != true) return;

  await _deleteDb(dbFileName: dbFileName, dbName: dbName);
  await reloadPlugin(plugin);
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

/// Reloads the plugin by disabling and re-enabling it via Obsidian's plugin
/// manager.
///
/// `disablePlugin` and `enablePlugin` are BOTH async. Firing them back to back
/// without awaiting the first let the new instance's `onload` register its
/// settings tab and status-bar item while the old instance was still being torn
/// down — the user ended up with one extra "Rhyolite Sync" entry and one extra
/// sync circle per reload, and they accumulated for the whole session.
///
/// So the enable is chained onto the disable. `whenComplete`, not `then`: a
/// disable that rejects must still be followed by the enable, or a failed
/// reload leaves the plugin switched off entirely.
Future<void> reloadPlugin(PluginHandle plugin) async {
  Object? plugins;
  String? id;
  try {
    final manifest = jsu.getProperty<Object?>(
      (plugin.raw as Object),
      'manifest',
    );
    if (manifest == null) return;
    id = jsu.getProperty<String?>(manifest, 'id');
    if (id == null) return;

    plugins = jsu.getProperty<Object?>(plugin.appRaw, 'plugins');
    if (plugins == null) return;
  } catch (_) {
    _hardReload();
    return;
  }

  try {
    await _awaitMaybePromise(
      jsu.callMethod<Object?>(plugins, 'disablePlugin', [id]),
    );
  } catch (_) {
    // Fall through: the enable below is what actually gets the user running
    // again, and skipping it on a failed disable is the worse outcome.
  }
  try {
    await _awaitMaybePromise(
      jsu.callMethod<Object?>(plugins, 'enablePlugin', [id]),
    );
  } catch (_) {
    _hardReload();
  }
}

/// Awaits [value] when it is a thenable, otherwise returns at once. Obsidian's
/// plugin-manager methods are async today, but this survives a build where they
/// are not — [jsu.promiseToFuture] on a plain value throws.
Future<void> _awaitMaybePromise(Object? value) async {
  if (value == null) return;
  final then = jsu.getProperty<Object?>(value, 'then');
  if (then == null) return;
  await jsu.promiseToFuture<Object?>(value);
}

/// `callMethod(globalThis, 'location.reload')` looked up a property literally
/// named "location.reload" — there is none, so the old last-resort path never
/// actually reloaded anything.
void _hardReload() {
  try {
    final location = jsu.getProperty<Object?>(jsu.globalThis, 'location');
    if (location == null) return;
    jsu.callMethod<Object?>(location, 'reload', []);
  } catch (_) {
    // Nothing left to try.
  }
}
