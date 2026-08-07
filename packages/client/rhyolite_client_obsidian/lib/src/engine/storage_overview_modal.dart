// ignore_for_file: deprecated_member_use
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import '../i18n/i18n.dart';
import '../settings/plugin_code_overview.dart';
import 'backup_modal.dart';
import 'device_management_modal.dart';
import 'format_bytes.dart';
import 'orphan_sweep_modal.dart';
import 'storage_cleanup_modal.dart';

/// What this vault holds and where it is kept: a summary strip, then one card
/// per store with its own action.
///
/// Laid out rather than listed. The previous version was a flat run of
/// `key: value` paragraphs ending in a row of seven buttons, which read as a
/// wall: the figures that matter (how much is stored, how much is left) sat
/// among the ones that rarely do, and every action competed equally for
/// attention. Now each figure sits next to the thing it describes, and each
/// action next to what it acts on.
///
/// Styling goes through Obsidian's own CSS variables so the modal follows the
/// user's theme instead of imposing one.
Future<void> showStorageOverviewModal(
  PluginHandle plugin,
  ISyncEngine engine, {
  PluginCodeOverview plugins = PluginCodeOverview.empty,
  ({int usedBytes, int quotaBytes})? usage,
  Future<void> Function()? onManagePlugins,
}) async {
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
  // What the plugin's own database weighs. A listing over blob descriptors,
  // not a read of their bodies — cheap enough to do on open, which is why it
  // lives here rather than behind another button.
  LocalCacheUsage? cache;
  try {
    cache = await engine.localCacheUsage();
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

      final root = ctx.createEl('div');
      _css(root, {
        'display': 'flex',
        'flexDirection': 'column',
        'gap': '14px',
        'marginTop': '10px',
        'maxHeight': '65vh',
        'overflowY': 'auto',
        'paddingRight': '4px',
      });
      final doc = jsu.getProperty<JSObject>(root, 'ownerDocument');

      // ── Summary strip ──
      // The three figures worth seeing before anything else.
      final liveFiles =
          stats == null ? null : stats.totalFiles - stats.tombstones;
      _tiles(doc, root, [
        (S.files, liveFiles == null ? '—' : '$liveFiles'),
        (
          S.contentSize,
          stats == null ? '—' : formatBytes(stats.totalSizeBytes),
        ),
        (S.devices, '${devices.length}'),
      ]);

      // ── Managed quota ──
      // Absent on self-host and bring-your-own, where there is no quota to
      // report — an empty meter there would invent a limit.
      if (usage != null && usage.quotaBytes > 0) {
        final body = _card(doc, root, S.storageSection);
        _meter(doc, body, usage);
      }

      // ── Content on this device ──
      final content = _card(doc, root, S.contentThisDevice);
      if (stats == null) {
        _muted(doc, content, S.notSyncedYet);
      } else {
        _kv(doc, content, S.uniqueBlobs, '${stats.uniqueBlobs}');
        if (stats.conflicting > 0) {
          _kv(doc, content, S.conflicts, '${stats.conflicting}');
        }
        if (stats.tombstones > 0) {
          _kv(doc, content, S.deletedTombstoned, '${stats.tombstones}');
        }
      }

      // ── Local database ──
      // The figure above is the vault's logical size; this is what the plugin
      // actually occupies on the device. They differ, sometimes by a factor of
      // two, and until now only the first was visible.
      if (cache != null && cache.totalBytes > 0) {
        final body = _card(doc, root, S.localDatabaseSection);
        _kv(doc, body, S.localDatabaseTotal, formatBytes(cache.totalBytes));
        if (cache.textBytes > 0) {
          _kv(doc, body, S.localDatabaseNotes, formatBytes(cache.textBytes));
        }
        if (cache.binaryBytes > 0) {
          _kv(
            doc,
            body,
            S.localDatabaseAttachments,
            formatBytes(cache.binaryBytes),
          );
        }
        if (cache.orphanBytes > 0) {
          _kv(doc, body, S.localDatabaseReclaimable,
              formatBytes(cache.orphanBytes));
        }
        _muted(doc, body, S.localDatabaseExplainer);
      }

      // ── Plugins and themes ──
      // A count and a total, not twenty lines: the detail belongs in the
      // management view, which is one click away and can also act on it.
      if (!plugins.isEmpty) {
        final body = _card(
          doc,
          root,
          S.pluginsSection,
          action: onManagePlugins == null
              ? null
              : (
                  S.manageAction,
                  () async {
                    ctx.close(null);
                    await onManagePlugins();
                  }
                ),
        );
        void line(String label, List<PluginCodeRow> rows) {
          if (rows.isEmpty) return;
          final bytes = rows.fold(0, (a, r) => a + r.sizeBytes);
          _kv(doc, body, label, '${rows.length} · ${formatBytes(bytes)}');
        }

        line(S.pluginsSection, plugins.plugins);
        line(S.themesSection, plugins.themes);
        final stale = plugins.outOfSyncHere.length;
        if (stale > 0) _muted(doc, body, S.pluginsOutOfSyncHere(stale));
      }

      // ── History ──
      final history = _card(
        doc,
        root,
        S.historyServer,
        action: (
          S.cleanUpStorage,
          () async {
            ctx.close(null);
            await showStorageCleanupModal(plugin, engine);
          }
        ),
      );
      if (plan == null) {
        _muted(doc, history, S.couldNotReadHistory);
      } else {
        _kv(doc, history, S.versionsKept, '${plan.totalEvents}');
        if (plan.oldestRemainingAt != null && plan.newestRemainingAt != null) {
          _kv(
            doc,
            history,
            S.range,
            '${_fmtDate(plan.oldestRemainingAt!)} → '
                '${_fmtDate(plan.newestRemainingAt!)}',
          );
        }
      }

      // ── Devices ──
      final deviceCard = _card(
        doc,
        root,
        S.devices,
        action: (
          S.manageAction,
          () async {
            ctx.close(null);
            await showDeviceManagementModal(plugin, engine);
          }
        ),
      );
      if (devices.isEmpty) {
        _muted(doc, deviceCard, S.noDevicesReported);
      } else {
        for (final d in devices) {
          final bits = <String>[
            _ago(d.lastSeen),
            if (d.behindBySeq > 0) S.behindPlain(d.behindBySeq),
          ];
          _kv(
            doc,
            deviceCard,
            d.isCurrent ? '${d.name}${S.thisDeviceSuffix}' : d.name,
            bits.join('  ·  '),
          );
        }
      }

      // ── Restore points ──
      final backups = _card(
        doc,
        root,
        S.restorePointsServer,
        action: restorePointsUnavailable
            ? null
            : (
                S.restorePointsAction,
                () async {
                  ctx.close(null);
                  await showBackupModal(plugin, engine);
                }
              ),
      );
      if (restorePointsUnavailable) {
        _muted(doc, backups, S.restorePointsUnavailableText);
      } else if (restorePoints.isEmpty) {
        _muted(doc, backups, S.restorePointsNoneYet);
      } else {
        _kv(doc, backups, S.kept, '${restorePoints.length}');
        final oldest =
            DateTime.fromMillisecondsSinceEpoch(restorePoints.last.createdAtMs);
        final newest = DateTime.fromMillisecondsSinceEpoch(
          restorePoints.first.createdAtMs,
        );
        _kv(doc, backups, S.range, '${_fmtDate(oldest)} → ${_fmtDate(newest)}');
        _muted(doc, backups, S.restorePointsHoldBlobs);
      }

      // Only what acts on the vault as a whole stays in the footer; everything
      // else moved next to the thing it operates on.
      ctx.spaceVertical(px: 14);
      final actions = <ButtonSpec>[
        ButtonSpec(S.reclaimOrphans, () async {
          ctx.close(null);
          await showOrphanSweepModal(plugin, engine);
        }),
      ];
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

// ── layout primitives ───────────────────────────────────────────────────────

/// The headline figures, side by side. Deliberately few: a summary that lists
/// everything summarises nothing.
void _tiles(JSObject doc, JSObject host, List<(String, String)> items) {
  final strip = _el(doc, host, 'div');
  _css(strip, {'display': 'flex', 'gap': '8px'});
  for (final (label, value) in items) {
    final tile = _el(doc, strip, 'div');
    _css(tile, {
      'flex': '1 1 0',
      'padding': '10px 12px',
      'borderRadius': '8px',
      'background': 'var(--background-secondary)',
      'minWidth': '0',
    });
    final v = _el(doc, tile, 'div', text: value);
    _css(v, {
      'fontSize': '18px',
      'fontWeight': '600',
      'whiteSpace': 'nowrap',
      'overflow': 'hidden',
      'textOverflow': 'ellipsis',
    });
    final l = _el(doc, tile, 'div', text: label);
    _css(l, {
      'fontSize': '11px',
      'color': 'var(--text-muted)',
      'textTransform': 'uppercase',
      'letterSpacing': '0.04em',
      'marginTop': '2px',
      'whiteSpace': 'nowrap',
      'overflow': 'hidden',
      'textOverflow': 'ellipsis',
    });
  }
}

/// One titled card. Returns the body to fill; [action] puts its button on the
/// title row, so it reads as belonging to this section rather than to the
/// modal.
JSObject _card(
  JSObject doc,
  JSObject host,
  String title, {
  (String, void Function())? action,
}) {
  final card = _el(doc, host, 'div');
  _css(card, {
    'border': '1px solid var(--background-modifier-border)',
    'borderRadius': '8px',
    'padding': '10px 12px',
  });

  final head = _el(doc, card, 'div');
  _css(head, {
    'display': 'flex',
    'alignItems': 'center',
    'gap': '8px',
    'marginBottom': '6px',
  });

  final h = _el(doc, head, 'div', text: title);
  _css(h, {'fontWeight': '600', 'flex': '1 1 auto', 'minWidth': '0'});

  if (action != null) {
    final btn = _el(doc, head, 'button', text: action.$1);
    _css(btn, {'flex': '0 0 auto', 'fontSize': '12px', 'padding': '2px 10px'});
    _onClick(btn, action.$2);
  }

  final body = _el(doc, card, 'div');
  _css(body, {'display': 'flex', 'flexDirection': 'column', 'gap': '2px'});
  return body;
}

/// A label on the left, its value right-aligned — so a column of them can be
/// read down the values alone.
void _kv(JSObject doc, JSObject host, String key, String value) {
  final row = _el(doc, host, 'div');
  _css(row, {
    'display': 'flex',
    'gap': '10px',
    'fontSize': '13px',
    'alignItems': 'baseline',
  });
  final k = _el(doc, row, 'div', text: key);
  _css(k, {
    'color': 'var(--text-muted)',
    'flex': '1 1 auto',
    'minWidth': '0',
    'overflow': 'hidden',
    'textOverflow': 'ellipsis',
    'whiteSpace': 'nowrap',
  });
  final v = _el(doc, row, 'div', text: value);
  _css(v, {'flex': '0 0 auto', 'fontVariantNumeric': 'tabular-nums'});
}

void _muted(JSObject doc, JSObject host, String text) {
  final el = _el(doc, host, 'div', text: text);
  _css(el, {'fontSize': '12px', 'color': 'var(--text-muted)'});
}

/// Used / quota, as a bar plus the figures. Warns at 90% using the theme's own
/// error colour rather than a hard-coded red.
void _meter(
  JSObject doc,
  JSObject host,
  ({int usedBytes, int quotaBytes}) usage,
) {
  final ratio = (usage.usedBytes / usage.quotaBytes).clamp(0.0, 1.0);
  final track = _el(doc, host, 'div');
  _css(track, {
    'height': '6px',
    'borderRadius': '3px',
    'background': 'var(--background-modifier-border)',
    'overflow': 'hidden',
    'marginBottom': '6px',
  });
  final fill = _el(doc, track, 'div');
  _css(fill, {
    'height': '100%',
    'width': '${(ratio * 100).toStringAsFixed(1)}%',
    'background':
        ratio >= 0.9 ? 'var(--text-error)' : 'var(--interactive-accent)',
  });
  _kv(
    doc,
    host,
    S.storageUsedLabel,
    '${formatBytes(usage.usedBytes)} / ${formatBytes(usage.quotaBytes)}'
        '  (${(ratio * 100).toStringAsFixed(0)}%)',
  );
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

JSObject _el(JSObject doc, JSObject parent, String tag, {String? text}) {
  final el = jsu.callMethod<JSObject>(doc, 'createElement', [tag]);
  if (text != null) jsu.setProperty(el, 'textContent', text);
  jsu.callMethod<void>(parent, 'appendChild', [el]);
  return el;
}

void _onClick(JSObject el, void Function() handler) {
  jsu.callMethod<void>(el, 'addEventListener', [
    'click',
    jsu.allowInterop((JSAny? _) => handler()),
  ]);
}

void _css(JSObject el, Map<String, String> styles) {
  final style = jsu.getProperty<JSObject>(el, 'style');
  styles.forEach((k, v) {
    jsu.setProperty(style, k, v);
  });
}
