import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

const _defaultDays = 30;
const _minDays = 1;
const _maxDays = 365;

/// Storage cleanup flow: scan → confirm → delete. Implemented as two
/// modals chained so the preview text lives in the second modal body.
///
/// 1. Input modal: user picks `days`, clicks Scan.
/// 2. Preview modal: shows counts + date range, Delete or Cancel.
/// 3. On Delete: execute, show a notice with the result.
Future<void> showStorageCleanupModal(
  PluginHandle plugin,
  ISyncEngine engine,
) async {
  final janitor = engine is StateSyncEngine ? engine.createBlobJanitor() : null;
  if (janitor == null) {
    showNotice('Storage cleanup not available — engine is not connected');
    return;
  }

  final daysSelected = await _askDays(plugin);
  if (daysSelected == null) return;

  // Scan with a transient spinner-only modal.
  final JanitorPlan plan;
  try {
    plan = await janitor.scan(olderThanDays: daysSelected);
  } catch (e) {
    showNotice('Storage cleanup scan failed: $e');
    return;
  }

  if (plan.isEmpty) {
    showNotice('Nothing to clean up older than $daysSelected days.');
    return;
  }

  final confirmed = await _confirmDeletion(plugin, plan);
  if (confirmed != true) return;

  try {
    final result = await janitor.execute(plan);
    showNotice(
      'Cleanup done: ${result.deletedEvents} history entries and '
      '${result.deletedBlobs} blobs deleted.',
    );
  } catch (e) {
    showNotice('Storage cleanup failed: $e');
  }
}

Future<int?> _askDays(PluginHandle plugin) {
  return showModalWith<int?>(
    plugin,
    build: (ctx) {
      ctx.h3('Storage Cleanup');
      ctx.spaceVertical(px: 8);

      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text:
            'Permanently remove history entries older than the chosen '
            'number of days. Blobs referenced only by those entries are '
            'also deleted from blob storage.',
      );
      ctx.spaceVertical(px: 12);

      ctx.createEl('p', text: 'Delete events older than (days):');
      final input = ctx.input(
        type: 'number',
        placeholder: '$_defaultDays',
      )..focus();
      ctx.spaceVertical(px: 16);

      void doScan() {
        final text = ctx.valueOf(input).trim();
        final days = int.tryParse(text) ?? _defaultDays;
        if (days < _minDays || days > _maxDays) {
          ctx.showError('Days must be between $_minDays and $_maxDays.');
          return;
        }
        ctx.close(days);
      }

      ctx.buttonRow([
        ButtonSpec('Scan', doScan, variant: ButtonVariant.primary),
        ButtonSpec('Cancel', () => ctx.close(null)),
      ]);
      ctx
        ..onEnter(input, doScan)
        ..onEscape(() => ctx.close(null));
    },
  );
}

Future<bool?> _confirmDeletion(PluginHandle plugin, JanitorPlan plan) {
  return showModalWith<bool>(
    plugin,
    build: (ctx) {
      ctx.h3('Confirm cleanup');
      ctx.spaceVertical(px: 12);
      ctx.createEl(
        'p',
        text: 'Events to delete: '
            '${plan.eventsToDelete} of ${plan.totalEvents}',
      );
      ctx.createEl(
        'p',
        text: 'Orphan blobs to delete: ${plan.orphanBlobCount}',
      );
      if (plan.oldestDeletedAt != null) {
        ctx.createEl(
          'p',
          cls: 'rhyolite-setting-desc',
          text: 'Oldest entry to delete: ${_fmt(plan.oldestDeletedAt!)}',
        );
      }
      if (plan.newestDeletedAt != null) {
        ctx.createEl(
          'p',
          cls: 'rhyolite-setting-desc',
          text: 'Newest entry to delete: ${_fmt(plan.newestDeletedAt!)}',
        );
      }
      if (plan.oldestRemainingAt != null) {
        ctx.spaceVertical(px: 8);
        ctx.createEl(
          'p',
          cls: 'rhyolite-setting-desc',
          text: 'Oldest entry remaining: ${_fmt(plan.oldestRemainingAt!)}',
        );
      }

      // Device-head safety section. Always surface this so the user
      // understands what's protecting their data (or what's missing).
      ctx.spaceVertical(px: 16);
      ctx.createEl('p', text: 'Device safety:');
      if (plan.knownDevices.isEmpty) {
        ctx.createEl(
          'p',
          cls: 'rhyolite-setting-desc',
          text: 'No devices have reported a history head yet. Only the '
              'age cutoff is protecting events from deletion.',
        );
      } else {
        for (final h in plan.knownDevices) {
          final age = DateTime.now().toUtc().millisecondsSinceEpoch -
              h.updatedAtMs;
          final ageDays = (age / 86400000).floor();
          final ageLabel = ageDays == 0
              ? '<1 day ago'
              : '$ageDays day${ageDays == 1 ? '' : 's'} ago';
          final tag = plan.activeDeviceCount > 0 && ageDays <= 30
              ? '[active]'
              : '[stale]';
          ctx.createEl(
            'p',
            cls: 'rhyolite-setting-desc',
            text: '$tag  ${h.deviceId.substring(0, 8)}…  '
                'head=${h.headSeq}  ($ageLabel)',
          );
        }
        if (plan.minSafeHead != null && plan.eventsProtectedByHead > 0) {
          ctx.createEl(
            'p',
            cls: 'rhyolite-setting-desc',
            text:
                'Protected by min head ${plan.minSafeHead}: ${plan.eventsProtectedByHead} '
                'event(s) older than the cutoff would be deletable but are '
                'kept because at least one active device has not seen them.',
          );
        } else if (plan.activeDeviceCount == 0) {
          ctx.createEl(
            'p',
            cls: 'rhyolite-setting-desc',
            text: 'No devices considered active (last seen within 30 days). '
                'Only the age cutoff applies.',
          );
        }
      }

      ctx.spaceVertical(px: 12);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: 'This cannot be undone.',
      );
      ctx.spaceVertical(px: 8);
      ctx.buttonRow([
        ButtonSpec(
          'Delete',
          () => ctx.close(true),
          variant: ButtonVariant.destructive,
        ),
        ButtonSpec('Cancel', () => ctx.close(false)),
      ]);
      ctx.onEscape(() => ctx.close(false));
    },
  );
}

String _fmt(DateTime d) {
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}';
}
