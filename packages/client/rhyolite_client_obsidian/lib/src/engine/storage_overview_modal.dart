import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import '../i18n/i18n.dart';
import 'backup_modal.dart';
import 'device_management_modal.dart';
import 'orphan_sweep_modal.dart';
import 'storage_cleanup_modal.dart';

/// Read-only view of what's stored for this vault: current content (this
/// device), how many history versions the server retains, and the devices
/// syncing. Nothing here deletes — it's the hub the Clean up / Manage devices
/// actions launch from.
///
/// Server-side byte sizes (managed storage used) aren't shown yet — that needs
/// blob sizes from the server. The content size below is this device's local
/// footprint from the sync state.
Future<void> showStorageOverviewModal(
  PluginHandle plugin,
  ISyncEngine engine,
) async {
  if (engine is! StateSyncEngine) {
    showNotice(S.storageOverviewUnavailable);
    return;
  }

  final stats = engine.statsSnapshot();
  final janitor = engine.createBlobJanitor();
  final registry = engine.createDeviceRegistry();

  // Neutral window: keep everything, so scan just counts history + reports the
  // date range and devices without proposing any deletion.
  JanitorPlan? plan;
  try {
    plan = await janitor?.scan(olderThanDays: 100000);
  } catch (_) {
    plan = null;
  }
  List<SyncDevice> devices = const [];
  try {
    devices = await registry?.call() ?? const [];
  } catch (_) {}
  List<BackupSnapshotInfo> restorePoints = const [];
  var restorePointsUnavailable = false;
  try {
    restorePoints = await engine.listBackups();
  } catch (_) {
    restorePointsUnavailable = true;
  }

  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3(S.storageOverviewTitle);
      ctx.spaceVertical(px: 8);

      // ── Content (this device) ──
      ctx.createEl('p', text: S.contentThisDevice);
      if (stats == null) {
        ctx.createEl('p', cls: 'rhyolite-setting-desc', text: S.notSyncedYet);
      } else {
        final liveFiles = stats.totalFiles - stats.tombstones;
        _kv(ctx, S.files, '$liveFiles');
        _kv(ctx, S.contentSize, _fmtSize(stats.totalSizeBytes));
        _kv(ctx, S.uniqueBlobs, '${stats.uniqueBlobs}');
        if (stats.conflicting > 0) _kv(ctx, S.conflicts, '${stats.conflicting}');
        if (stats.tombstones > 0) {
          _kv(ctx, S.deletedTombstoned, '${stats.tombstones}');
        }
      }

      // ── History (server) ──
      ctx.spaceVertical(px: 12);
      ctx.createEl('p', text: S.historyServer);
      if (plan == null) {
        ctx.createEl('p',
            cls: 'rhyolite-setting-desc', text: S.couldNotReadHistory);
      } else {
        _kv(ctx, S.versionsKept, '${plan.totalEvents}');
        if (plan.oldestRemainingAt != null && plan.newestRemainingAt != null) {
          _kv(
            ctx,
            S.range,
            '${_fmtDate(plan.oldestRemainingAt!)} → '
                '${_fmtDate(plan.newestRemainingAt!)}',
          );
        }
      }

      // ── Devices ──
      ctx.spaceVertical(px: 12);
      ctx.createEl('p', text: S.devices);
      if (devices.isEmpty) {
        ctx.createEl('p',
            cls: 'rhyolite-setting-desc', text: S.noDevicesReported);
      } else {
        for (final d in devices) {
          final suffix = d.isCurrent ? S.thisDeviceSuffix : '';
          final behind = d.behindBySeq > 0 ? S.behindBy(d.behindBySeq) : '';
          ctx.createEl(
            'p',
            cls: 'rhyolite-setting-desc',
            text: S.deviceLine(d.name, suffix, _ago(d.lastSeen), behind),
          );
        }
      }

      // ── Restore points (server) ──
      ctx.spaceVertical(px: 12);
      ctx.createEl('p', text: S.restorePointsServer);
      if (restorePointsUnavailable) {
        ctx.createEl('p',
            cls: 'rhyolite-setting-desc',
            text: S.restorePointsUnavailableText);
      } else if (restorePoints.isEmpty) {
        ctx.createEl('p',
            cls: 'rhyolite-setting-desc', text: S.restorePointsNoneYet);
      } else {
        _kv(ctx, S.kept, '${restorePoints.length}');
        final oldest =
            DateTime.fromMillisecondsSinceEpoch(restorePoints.last.createdAtMs);
        final newest =
            DateTime.fromMillisecondsSinceEpoch(restorePoints.first.createdAtMs);
        _kv(ctx, S.range, '${_fmtDate(oldest)} → ${_fmtDate(newest)}');
        ctx.createEl('p',
            cls: 'rhyolite-setting-desc', text: S.restorePointsHoldBlobs);
      }

      ctx.spaceVertical(px: 16);
      final actions = <ButtonSpec>[
        ButtonSpec(S.cleanUpStorage, () async {
          ctx.close(null);
          await showStorageCleanupModal(plugin, engine);
        }),
        ButtonSpec(S.reclaimOrphans, () async {
          ctx.close(null);
          await showOrphanSweepModal(plugin, engine);
        }),
        ButtonSpec(S.manageDevices, () async {
          ctx.close(null);
          await showDeviceManagementModal(plugin, engine);
        }),
      ];
      if (!restorePointsUnavailable) {
        actions.add(ButtonSpec(S.restorePointsAction, () async {
          ctx.close(null);
          await showBackupModal(plugin, engine);
        }));
      }
      if (restorePoints.isNotEmpty) {
        actions.add(ButtonSpec(S.clearRestorePointsAction, () async {
          ctx.close(null);
          await _clearRestorePoints(plugin, engine, restorePoints.length);
        }));
      }
      actions.add(ButtonSpec(S.close, () => ctx.close(null)));
      ctx.buttonRow(actions);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

/// Confirms, then drops all restore points to release their blob pin. Space is
/// reclaimed by a subsequent orphan sweep, not immediately — so we point there.
Future<void> _clearRestorePoints(
  PluginHandle plugin,
  StateSyncEngine engine,
  int count,
) async {
  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3(S.clearRestorePointsTitle);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: S.clearRestorePointsBody(count),
      );
      ctx.spaceVertical(px: 12);
      ctx.buttonRow([
        ButtonSpec(S.clearVerb, () async {
          ctx.close(null);
          try {
            final n = await engine.clearBackups();
            showNotice(n == null
                ? S.notConnectedNothingCleared
                : S.clearedRestorePoints(n));
          } catch (e) {
            showNotice(S.clearRestorePointsFailed(e));
          }
        }, variant: ButtonVariant.destructive),
        ButtonSpec(S.cancel, () => ctx.close(null)),
      ]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

void _kv(ModalContext<void> ctx, String key, String value) {
  ctx.createEl('p', cls: 'rhyolite-setting-desc', text: '$key: $value');
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String _fmtDate(DateTime d) {
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)}';
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return S.justNow;
  if (d.inMinutes < 60) return S.minutesAgo(d.inMinutes);
  if (d.inHours < 24) return S.hoursAgo(d.inHours);
  return S.daysAgo(d.inDays);
}
