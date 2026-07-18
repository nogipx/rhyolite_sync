import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import '../i18n/i18n.dart';
import 'backup_inspect_modal.dart';

/// Manages this vault's server-side restore points: create one now, restore a
/// past one in place (reversible via history), or delete individual ones.
///
/// Manual restore points work for any connected vault (free, Pro, self-host) —
/// only the *automatic* daily snapshot (once/24h, 7 kept) is Pro-gated, by the
/// managed server's BackupCaptureInterceptor. A disconnected vault lists none.
Future<void> showBackupModal(PluginHandle plugin, ISyncEngine engine) async {
  if (engine is! StateSyncEngine) {
    showNotice(S.backupsUnavailable);
    return;
  }

  final List<BackupSnapshotInfo> snapshots;
  try {
    snapshots = await engine.listBackups();
  } catch (e) {
    showNotice(S.backupsLoadFailed(e));
    return;
  }

  await showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3(S.backupsTitle);
      ctx.createEl('p', cls: 'rhyolite-setting-desc', text: S.backupsDescription);
      ctx.spaceVertical(px: 8);

      ctx.buttonRow([
        ButtonSpec(
          S.createRestorePointNow,
          () => _capture(plugin, ctx, engine),
          variant: ButtonVariant.primary,
        ),
      ]);
      ctx.spaceVertical(px: 12);

      if (snapshots.isEmpty) {
        ctx.createEl('p',
            cls: 'rhyolite-setting-desc', text: S.noRestorePointsYet);
      } else {
        for (final s in snapshots) {
          final when =
              DateTime.fromMillisecondsSinceEpoch(s.createdAtMs).toLocal();
          ctx.createEl('p',
              text: S.restorePointLine(_fmt(when), s.recordCount));
          ctx.buttonRow([
            ButtonSpec(S.details, () async {
              ctx.close(null);
              await showBackupInspectModal(plugin, engine, s);
              await showBackupModal(plugin, engine);
            }),
            ButtonSpec(
              S.restoreAllAction,
              () => _restoreAll(plugin, ctx, engine, s),
              variant: ButtonVariant.primary,
            ),
            ButtonSpec(
              S.delete,
              () => _delete(plugin, ctx, engine, s),
              variant: ButtonVariant.destructive,
            ),
          ]);
          ctx.spaceVertical(px: 4);
        }
      }

      ctx.spaceVertical(px: 8);
      ctx.buttonRow([ButtonSpec(S.close, () => ctx.close(null))]);
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
  showNotice(S.creatingRestorePoint);
  try {
    final snap = await engine.captureBackup();
    showNotice(snap == null
        ? S.notConnectedNoCapture
        : S.restorePointCreated(snap.recordCount));
  } catch (e) {
    showNotice(S.captureFailed(e));
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
    showNotice(ok ? S.restorePointDeleted : S.restorePointNotFound);
  } catch (e) {
    showNotice(S.deleteRestorePointFailed(e));
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
      c.h3(S.restoreAllTitle(_fmt(when)));
      c.createEl('p',
          cls: 'rhyolite-setting-desc', text: S.restoreAllConfirmBody);
      c.spaceVertical(px: 12);
      c.buttonRow([
        ButtonSpec(S.restoreAllConfirm, () async {
          c.close(null);
          showNotice(S.restoring);
          try {
            final report = await engine.restoreBackup(snapshot.snapshotId);
            if (report == null) {
              showNotice(S.restoreUnavailableNotConnected);
              return;
            }
            final parts = <String>[S.restoredFilesCount(report.restoredFiles)];
            if (report.skippedIdentical > 0) {
              parts.add(S.unchangedCount(report.skippedIdentical));
            }
            if (report.errors.isNotEmpty) {
              parts.add(S.errorsCount(report.errors.length));
            }
            showNotice(parts.join(' · '));
          } catch (e) {
            showNotice(S.restoreFailed(e));
          }
        }, variant: ButtonVariant.primary),
        ButtonSpec(S.cancel, () => c.close(null)),
      ]);
      c.onEscape(() => c.close(null));
    },
  );
}

String _fmt(DateTime d) =>
    '${d.year}-${_pad(d.month)}-${_pad(d.day)} ${_pad(d.hour)}:${_pad(d.minute)}';
String _pad(int n) => n.toString().padLeft(2, '0');
