import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import '../i18n/i18n.dart';
import 'device_management_modal.dart';

const _defaultDays = 30;
const _minDays = 0; // 0 = delete all history the device-safety head allows
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
    showNotice(S.storageCleanupUnavailable);
    return;
  }

  final daysSelected = await _askDays(plugin);
  if (daysSelected == null) return;

  // Scan with a transient spinner-only modal.
  final JanitorPlan plan;
  try {
    plan = await janitor.scan(olderThanDays: daysSelected);
  } catch (e) {
    showNotice(S.cleanupScanFailed(e));
    return;
  }

  if (plan.isEmpty) {
    showNotice(S.nothingToCleanOlderThan(daysSelected));
    return;
  }

  final confirmed = await _confirmDeletion(plugin, engine, plan);
  if (confirmed != true) return;

  try {
    final result = await janitor.execute(plan);
    if (result.hadFailures) {
      showNotice(
        S.cleanupIncomplete(result.deletedBlobs, result.failedBlobs) +
            (result.firstError != null ? '\n${result.firstError}' : ''),
        timeoutMs: 12000,
      );
    } else {
      showNotice(S.cleanupDone(result.deletedEvents, result.deletedBlobs));
    }
  } catch (e) {
    showNotice(S.cleanupFailed(e));
  }
}

Future<int?> _askDays(PluginHandle plugin) {
  return showModalWith<int?>(
    plugin,
    build: (ctx) {
      ctx.h3(S.storageCleanupTitle);
      ctx.spaceVertical(px: 8);

      ctx.createEl('p',
          cls: 'rhyolite-setting-desc', text: S.storageCleanupDescription);
      ctx.spaceVertical(px: 12);

      ctx.createEl('p', text: S.deleteEventsOlderThanLabel);
      final input = ctx.input(
        type: 'number',
        placeholder: '$_defaultDays',
      )..focus();
      ctx.spaceVertical(px: 16);

      void doScan() {
        final text = ctx.valueOf(input).trim();
        final days = int.tryParse(text) ?? _defaultDays;
        if (days < _minDays || days > _maxDays) {
          ctx.showError(S.daysMustBeBetween(_minDays, _maxDays));
          return;
        }
        ctx.close(days);
      }

      ctx.buttonRow([
        ButtonSpec(S.scanAction, doScan, variant: ButtonVariant.primary),
        ButtonSpec(S.cancel, () => ctx.close(null)),
      ]);
      ctx
        ..onEnter(input, doScan)
        ..onEscape(() => ctx.close(null));
    },
  );
}

Future<bool?> _confirmDeletion(
  PluginHandle plugin,
  ISyncEngine engine,
  JanitorPlan plan,
) {
  return showModalWith<bool>(
    plugin,
    build: (ctx) {
      ctx.h3(S.confirmCleanupTitle);
      ctx.spaceVertical(px: 12);
      ctx.createEl('p',
          text: S.eventsToDelete(plan.eventsToDelete, plan.totalEvents));
      ctx.createEl('p', text: S.orphanBlobsToDelete(plan.orphanBlobCount));
      if (plan.oldestDeletedAt != null) {
        ctx.createEl('p',
            cls: 'rhyolite-setting-desc',
            text: S.oldestEntryToDelete(_fmt(plan.oldestDeletedAt!)));
      }
      if (plan.newestDeletedAt != null) {
        ctx.createEl('p',
            cls: 'rhyolite-setting-desc',
            text: S.newestEntryToDelete(_fmt(plan.newestDeletedAt!)));
      }
      if (plan.oldestRemainingAt != null) {
        ctx.spaceVertical(px: 8);
        ctx.createEl('p',
            cls: 'rhyolite-setting-desc',
            text: S.oldestEntryRemaining(_fmt(plan.oldestRemainingAt!)));
      }

      // Device-head safety section. Always surface this so the user
      // understands what's protecting their data (or what's missing).
      ctx.spaceVertical(px: 16);
      ctx.createEl('p', text: S.deviceSafety);
      if (plan.knownDevices.isEmpty) {
        ctx.createEl('p',
            cls: 'rhyolite-setting-desc', text: S.noDeviceHeadYet);
      } else {
        for (final h in plan.knownDevices) {
          final age = DateTime.now().toUtc().millisecondsSinceEpoch -
              h.updatedAtMs;
          final ageDays = (age / 86400000).floor();
          final ageLabel =
              ageDays == 0 ? S.ageLessThanDay : S.cleanupDaysAgo(ageDays);
          final tag = plan.activeDeviceCount > 0 && ageDays <= 30
              ? S.activeTag
              : S.staleTag;
          ctx.createEl(
            'p',
            cls: 'rhyolite-setting-desc',
            text: S.deviceHeadLine(
                tag, h.deviceId.substring(0, 8), h.headSeq, ageLabel),
          );
        }
        if (plan.minSafeHead != null && plan.eventsProtectedByHead > 0) {
          ctx.createEl('p',
              cls: 'rhyolite-setting-desc',
              text: S.protectedByMinHead(
                  plan.minSafeHead!, plan.eventsProtectedByHead));
        } else if (plan.activeDeviceCount == 0) {
          ctx.createEl('p',
              cls: 'rhyolite-setting-desc',
              text: S.noActiveDevicesForCleanup);
        }
      }

      ctx.spaceVertical(px: 12);
      ctx.createEl('p', cls: 'rhyolite-setting-desc', text: S.cannotBeUndone);
      ctx.spaceVertical(px: 8);
      ctx.buttonRow([
        ButtonSpec(
          S.delete,
          () => ctx.close(true),
          variant: ButtonVariant.destructive,
        ),
        // Jump to device management to forget a stale device that's pinning
        // events, then re-run cleanup.
        ButtonSpec(S.manageDevices, () async {
          ctx.close(false);
          await showDeviceManagementModal(plugin, engine);
        }),
        ButtonSpec(S.cancel, () => ctx.close(false)),
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
