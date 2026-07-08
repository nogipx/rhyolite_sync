import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

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
    showNotice('Storage overview not available — engine is not connected');
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

  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3('Storage overview');
      ctx.spaceVertical(px: 8);

      // ── Content (this device) ──
      ctx.createEl('p', text: 'Content (this device)');
      if (stats == null) {
        ctx.createEl('p', cls: 'rhyolite-setting-desc', text: 'Not synced yet.');
      } else {
        final liveFiles = stats.totalFiles - stats.tombstones;
        _kv(ctx, 'Files', '$liveFiles');
        _kv(ctx, 'Content size', _fmtSize(stats.totalSizeBytes));
        _kv(ctx, 'Unique blobs', '${stats.uniqueBlobs}');
        if (stats.conflicting > 0) _kv(ctx, 'Conflicts', '${stats.conflicting}');
        if (stats.tombstones > 0) {
          _kv(ctx, 'Deleted (tombstoned)', '${stats.tombstones}');
        }
      }

      // ── History (server) ──
      ctx.spaceVertical(px: 12);
      ctx.createEl('p', text: 'History (server)');
      if (plan == null) {
        ctx.createEl(
          'p',
          cls: 'rhyolite-setting-desc',
          text: 'Could not read history (not connected?).',
        );
      } else {
        _kv(ctx, 'Versions kept', '${plan.totalEvents}');
        if (plan.oldestRemainingAt != null && plan.newestRemainingAt != null) {
          _kv(
            ctx,
            'Range',
            '${_fmtDate(plan.oldestRemainingAt!)} → '
                '${_fmtDate(plan.newestRemainingAt!)}',
          );
        }
      }

      // ── Devices ──
      ctx.spaceVertical(px: 12);
      ctx.createEl('p', text: 'Devices');
      if (devices.isEmpty) {
        ctx.createEl(
          'p',
          cls: 'rhyolite-setting-desc',
          text: 'No devices have reported yet.',
        );
      } else {
        for (final d in devices) {
          final suffix = d.isCurrent ? '  (this device)' : '';
          final behind = d.behindBySeq > 0 ? '  ·  ${d.behindBySeq} behind' : '';
          ctx.createEl(
            'p',
            cls: 'rhyolite-setting-desc',
            text: '${d.name}$suffix  —  seen ${_ago(d.lastSeen)}$behind',
          );
        }
      }

      ctx.spaceVertical(px: 16);
      ctx.buttonRow([
        ButtonSpec('Clean up storage…', () async {
          ctx.close(null);
          await showStorageCleanupModal(plugin, engine);
        }),
        ButtonSpec('Reclaim orphans…', () async {
          ctx.close(null);
          await showOrphanSweepModal(plugin, engine);
        }),
        ButtonSpec('Manage devices…', () async {
          ctx.close(null);
          await showDeviceManagementModal(plugin, engine);
        }),
        ButtonSpec('Close', () => ctx.close(null)),
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
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}
