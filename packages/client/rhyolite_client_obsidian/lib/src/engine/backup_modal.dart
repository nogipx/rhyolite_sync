import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import 'backup_inspect_modal.dart';

/// Manages this vault's server-side restore points: create one now, restore a
/// past one NON-destructively into a new `restore-<ts>/` folder (the live vault
/// is never touched), or delete individual ones / none.
///
/// Restore points are a Pro, server-driven feature (daily snapshots, 7 kept); a
/// free / self-host / disconnected vault simply lists none.
Future<void> showBackupModal(PluginHandle plugin, ISyncEngine engine) async {
  if (engine is! StateSyncEngine) {
    showNotice('Backups not available — engine is not connected');
    return;
  }

  final List<BackupSnapshotInfo> snapshots;
  try {
    snapshots = await engine.listBackups();
  } catch (e) {
    showNotice('Failed to load backups: $e');
    return;
  }

  await showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3('Vault backups');
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: 'Restore a snapshot into a new folder — your live vault is '
            'untouched, so nothing is overwritten.',
      );
      ctx.spaceVertical(px: 8);

      ctx.buttonRow([
        ButtonSpec(
          'Create restore point now',
          () => _capture(plugin, ctx, engine),
          variant: ButtonVariant.primary,
        ),
      ]);
      ctx.spaceVertical(px: 12);

      if (snapshots.isEmpty) {
        ctx.createEl(
          'p',
          cls: 'rhyolite-setting-desc',
          text: 'No restore points yet. Pro vaults keep daily ones (7 newest).',
        );
      } else {
        for (final s in snapshots) {
          final when =
              DateTime.fromMillisecondsSinceEpoch(s.createdAtMs).toLocal();
          ctx.createEl('p', text: '${_fmt(when)}  ·  ${s.recordCount} file(s)');
          ctx.buttonRow([
            ButtonSpec('Details', () async {
              ctx.close(null);
              await showBackupInspectModal(plugin, engine, s);
              await showBackupModal(plugin, engine);
            }),
            ButtonSpec(
              'Restore all…',
              () => _restoreAll(plugin, ctx, engine, s),
              variant: ButtonVariant.primary,
            ),
            ButtonSpec(
              'Delete',
              () => _delete(plugin, ctx, engine, s),
              variant: ButtonVariant.destructive,
            ),
          ]);
          ctx.spaceVertical(px: 4);
        }
      }

      ctx.spaceVertical(px: 8);
      ctx.buttonRow([ButtonSpec('Close', () => ctx.close(null))]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

Future<void> _capture(
  PluginHandle plugin,
  ModalContext<void> ctx,
  StateSyncEngine engine,
) async {
  ctx.close(null);
  showNotice('Creating restore point …');
  try {
    final snap = await engine.captureBackup();
    if (snap == null) {
      showNotice('Not connected — no restore point created.');
    } else {
      showNotice('Restore point created (${snap.recordCount} file(s)).');
    }
  } catch (e) {
    showNotice('Failed to create restore point: $e');
  }
  await showBackupModal(plugin, engine);
}

Future<void> _delete(
  PluginHandle plugin,
  ModalContext<void> ctx,
  StateSyncEngine engine,
  BackupSnapshotInfo snapshot,
) async {
  ctx.close(null);
  try {
    final ok = await engine.deleteBackup(snapshot.snapshotId);
    showNotice(ok ? 'Restore point deleted.' : 'Restore point not found.');
  } catch (e) {
    showNotice('Failed to delete restore point: $e');
  }
  await showBackupModal(plugin, engine);
}

/// Bulk restore, in place: overwrite current files with the snapshot version
/// wherever they differ. Reversible via file history; nothing is deleted.
Future<void> _restoreAll(
  PluginHandle plugin,
  ModalContext<void> ctx,
  StateSyncEngine engine,
  BackupSnapshotInfo snapshot,
) async {
  ctx.close(null);
  final when = DateTime.fromMillisecondsSinceEpoch(snapshot.createdAtMs).toLocal();
  await showModalWith<void>(
    plugin,
    build: (c) {
      c.h3('Restore all · ${_fmt(when)}');
      c.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: 'Overwrite current files with this restore point wherever they '
            'differ. Files identical to now are left alone; nothing is deleted. '
            'Each change syncs and stays reversible via file history.',
      );
      c.spaceVertical(px: 12);
      c.buttonRow([
        ButtonSpec('Restore all', () async {
          c.close(null);
          showNotice('Restoring …');
          try {
            final report = await engine.restoreBackup(snapshot.snapshotId);
            if (report == null) {
              showNotice('Restore unavailable — not connected.');
              return;
            }
            final parts = <String>['Restored ${report.restoredFiles} file(s)'];
            if (report.skippedIdentical > 0) {
              parts.add('${report.skippedIdentical} unchanged');
            }
            if (report.errors.isNotEmpty) {
              parts.add('${report.errors.length} error(s)');
            }
            showNotice(parts.join(' · '));
          } catch (e) {
            showNotice('Restore failed: $e');
          }
        }, variant: ButtonVariant.primary),
        ButtonSpec('Cancel', () => c.close(null)),
      ]);
      c.onEscape(() => c.close(null));
    },
  );
}

String _fmt(DateTime d) =>
    '${d.year}-${_pad(d.month)}-${_pad(d.day)} ${_pad(d.hour)}:${_pad(d.minute)}';
String _pad(int n) => n.toString().padLeft(2, '0');
