// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../i18n/i18n.dart';
import 'plan_status.dart';
import 'server_rejections.dart';

/// Stylesheet for the docked sync panel. Injected once at plugin load through
/// `bootstrapPlugin(extraCss: ...)` and removed on unload, so the panel styles
/// itself with CSS classes instead of inline styles — themes and snippets can
/// override any of it.
///
/// Status colours are the same literal rgb() values the status-bar indicator
/// uses, so both surfaces always agree on what "green" means.
const kSyncPanelCss = r'''
/* ── Rhyolite sync panel ─────────────────────────────────────────────────── */
.view-content.rhyolite-sync-panel-content { padding: 0; }

.rh-panel {
  --rh-status: rgb(150, 150, 150);
  padding: 12px 12px 24px;
  color: var(--text-normal);
}
.rh-panel.is-ready      { --rh-status: rgb(48, 168, 96); }
.rh-panel.is-pending    { --rh-status: rgb(220, 180, 60); }
.rh-panel.is-connecting { --rh-status: rgb(200, 180, 90); }
.rh-panel.is-syncing    { --rh-status: rgb(48, 128, 240); }
.rh-panel.is-offline    { --rh-status: rgb(230, 110, 50); }
.rh-panel.is-auth       { --rh-status: rgb(240, 150, 48); }
.rh-panel.is-sub        { --rh-status: rgb(240, 150, 48); }
.rh-panel.is-error      { --rh-status: rgb(220, 56, 56); }
.rh-panel.is-stopped    { --rh-status: rgb(128, 128, 128); }
.rh-panel.is-blocked    { --rh-status: rgb(240, 150, 48); }
.rh-panel.is-paused     { --rh-status: rgb(150, 150, 150); }

.rh-hidden { display: none !important; }

/* Shown while the plugin is still booting and the panel has nothing yet */
.rh-booting { color: var(--text-muted); font-size: var(--font-ui-smaller, 11px); }

/* Header ─ vault identity */
.rh-head { display: flex; align-items: center; gap: 6px; min-width: 0; }
.rh-head .rh-icon { color: var(--text-faint); }
.rh-vault {
  font-size: var(--font-ui-medium, 15px);
  font-weight: 600;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* Trust chips */
.rh-chips { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 6px; }
.rh-chip {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  max-width: 100%;
  padding: 1px 8px;
  border-radius: 999px;
  font-size: var(--font-ui-smaller, 11px);
  line-height: 18px;
  color: var(--text-muted);
  background: var(--background-modifier-hover);
}
.rh-chip > span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rh-chip.mod-secure { color: rgb(48, 168, 96); background: rgba(48, 168, 96, 0.12); }

/* Status hero */
.rh-hero {
  position: relative;
  margin-top: 10px;
  padding: 10px 12px 10px 14px;
  border: 1px solid var(--background-modifier-border);
  border-radius: var(--radius-m, 8px);
  background: var(--background-secondary);
  overflow: hidden;
}
.rh-hero::before {
  content: '';
  position: absolute;
  top: 0;
  bottom: 0;
  left: 0;
  width: 3px;
  background: var(--rh-status);
}
.rh-hero-top { display: flex; align-items: center; gap: 8px; min-width: 0; }
.rh-dot {
  width: 9px;
  height: 9px;
  flex-shrink: 0;
  border-radius: 50%;
  background: var(--rh-status);
}
.rh-status { font-weight: 600; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rh-sub { margin-top: 2px; font-size: var(--font-ui-smaller, 11px); color: var(--text-muted); }
.rh-err {
  margin-top: 5px;
  font-size: var(--font-ui-smaller, 11px);
  color: var(--text-error);
  overflow-wrap: anywhere;
}
.rh-counters {
  display: flex;
  gap: 12px;
  margin-top: 7px;
  font-size: var(--font-ui-smaller, 11px);
  color: var(--text-muted);
}
.rh-counter { display: inline-flex; align-items: center; gap: 3px; font-variant-numeric: tabular-nums; }

/* Progress tracks */
.rh-track {
  height: 4px;
  margin-top: 8px;
  border-radius: 999px;
  background: var(--background-modifier-border);
  overflow: hidden;
}
.rh-fill {
  height: 100%;
  width: 0;
  border-radius: 999px;
  background: var(--rh-status);
  transition: width 0.3s ease;
}
.rh-track.is-indeterminate .rh-fill {
  width: 36%;
  transition: none;
  animation: rh-slide 1.4s ease-in-out infinite;
}
@keyframes rh-slide {
  0%   { transform: translateX(-110%); }
  100% { transform: translateX(310%); }
}

/* Stat tiles */
.rh-stats {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 6px;
  margin-top: 10px;
}
.rh-stat {
  min-width: 0;
  padding: 8px 10px;
  border: 1px solid var(--background-modifier-border);
  border-radius: var(--radius-m, 8px);
  background: var(--background-secondary);
}
.rh-stat-head { display: flex; align-items: center; gap: 4px; min-width: 0; color: var(--text-faint); }
.rh-stat-label {
  font-size: var(--font-ui-smaller, 11px);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.rh-stat-value {
  margin-top: 2px;
  font-size: 15px;
  font-weight: 600;
  line-height: 1.25;
  font-variant-numeric: tabular-nums;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

/* Quota meter */
.rh-meter { margin-top: 12px; }
.rh-meter-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 8px;
  font-size: var(--font-ui-smaller, 11px);
}
.rh-meter-title { color: var(--text-muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rh-meter-value { flex-shrink: 0; font-variant-numeric: tabular-nums; }
.rh-meter .rh-track { height: 6px; margin-top: 5px; }
.rh-meter .rh-fill { background: var(--interactive-accent); }
.rh-meter.is-near .rh-fill { background: rgb(230, 110, 50); }

/* Plan alert — shown only when there is something to act on. */
.rh-alert {
  display: flex; align-items: flex-start; gap: 8px;
  margin-top: 10px; padding: 8px 10px;
  border: 1px solid var(--background-modifier-border);
  border-left: 3px solid var(--text-muted);
  border-radius: 6px;
  background: var(--background-secondary);
}
.rh-alert.is-urgent { border-left-color: rgb(230, 110, 50); }
.rh-alert-body { flex: 1; min-width: 0; }
.rh-alert-title { font-size: var(--font-ui-smaller, 11px); font-weight: 600; }
.rh-alert-hint {
  margin-top: 2px;
  font-size: var(--font-ui-smaller, 11px);
  color: var(--text-muted);
  line-height: 1.35;
}
.rh-alert-btn { flex-shrink: 0; align-self: center; font-size: var(--font-ui-smaller, 11px); }

/* Links row */
.rh-links { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-top: 8px; }
.rh-link { font-size: var(--font-ui-smaller, 11px); color: var(--text-accent); cursor: pointer; }
.rh-link:hover { color: var(--text-accent-hover); text-decoration: underline; }
.rh-refresh {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 3px;
  border-radius: var(--radius-s, 4px);
  color: var(--text-muted);
  cursor: pointer;
}
.rh-refresh:hover { background: var(--background-modifier-hover); color: var(--text-normal); }
.rh-refresh.is-busy { color: var(--text-faint); cursor: default; animation: rh-spin 1s linear infinite; }
@keyframes rh-spin { to { transform: rotate(360deg); } }

/* Actions */
.rh-actions { display: flex; align-items: stretch; gap: 6px; margin-top: 12px; }
.rh-primary { flex: 1; display: inline-flex; align-items: center; justify-content: center; gap: 6px; }
.rh-iconbtn { display: inline-flex; align-items: center; justify-content: center; padding: 0 10px; }

/* Trust footer */
.rh-footer {
  display: flex;
  align-items: flex-start;
  gap: 6px;
  margin-top: 12px;
  font-size: var(--font-ui-smaller, 11px);
  line-height: 1.45;
  color: var(--text-faint);
}
.rh-footer .rh-icon { margin-top: 1px; }

/* Sections */
.rh-section { margin-top: 16px; padding-top: 12px; border-top: 1px solid var(--background-modifier-border); }
.rh-section-head { display: flex; align-items: center; gap: 6px; margin-bottom: 6px; color: var(--text-muted); }
.rh-section-title {
  font-size: var(--font-ui-smaller, 11px);
  font-weight: 600;
  letter-spacing: 0.05em;
  text-transform: uppercase;
}
.rh-badge {
  margin-left: auto;
  padding: 0 6px;
  border-radius: 999px;
  font-size: 10px;
  line-height: 16px;
  color: var(--text-muted);
  background: var(--background-modifier-hover);
  font-variant-numeric: tabular-nums;
}
.rh-section.mod-warn .rh-section-head { color: rgb(230, 110, 50); }
.rh-section.mod-error .rh-section-head { color: var(--text-error); }

/* File rows */
.rh-row { display: flex; align-items: center; gap: 6px; min-width: 0; padding: 3px 0; font-size: var(--font-ui-smaller, 12px); }
.rh-row-arrow { color: var(--text-faint); }
.rh-row-arrow.mod-up { color: var(--text-accent); }
.rh-row-arrow.mod-down { color: rgb(48, 168, 96); }
.rh-row-meta { flex-shrink: 0; margin-left: auto; padding-left: 6px; color: var(--text-faint); font-variant-numeric: tabular-nums; }
.rh-file { display: flex; min-width: 0; }
.rh-file-dir {
  flex: 0 999 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--text-faint);
}
.rh-file-name { flex: 0 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rh-empty { padding: 2px 0 4px; font-size: var(--font-ui-smaller, 11px); color: var(--text-faint); }

/* Transfers */
.rh-transfer { padding: 4px 0; }
.rh-transfer .rh-track { height: 3px; margin-top: 4px; }
.rh-transfer .rh-fill { background: var(--interactive-accent); }

/* Warning cards */
.rh-hint { margin-bottom: 6px; font-size: var(--font-ui-smaller, 11px); line-height: 1.45; color: var(--text-muted); }
.rh-card {
  margin-top: 4px;
  padding: 6px 8px;
  border-radius: var(--radius-s, 4px);
  border-left: 2px solid var(--rh-card-accent, var(--background-modifier-border));
  background: var(--background-secondary);
}
.rh-card.mod-warn { --rh-card-accent: rgb(230, 110, 50); }
.rh-card.mod-error { --rh-card-accent: var(--text-error); }
.rh-card-title { display: flex; align-items: center; gap: 5px; min-width: 0; font-size: var(--font-ui-smaller, 12px); }
.rh-card-meta { margin-top: 2px; font-size: var(--font-ui-smaller, 11px); color: var(--text-muted); }
.rh-more { margin-top: 6px; font-size: var(--font-ui-smaller, 11px); color: var(--text-faint); }

/* Icons */
.rh-icon { display: inline-flex; align-items: center; flex-shrink: 0; }
.rh-icon .svg-icon { width: 14px; height: 14px; }
.rh-chip .rh-icon .svg-icon,
.rh-stat-head .rh-icon .svg-icon,
.rh-section-head .rh-icon .svg-icon,
.rh-row-arrow .svg-icon,
.rh-counter .rh-icon .svg-icon { width: 12px; height: 12px; }

@media (prefers-reduced-motion: reduce) {
  .rh-track.is-indeterminate .rh-fill,
  .rh-refresh.is-busy { animation: none; }
  .rh-fill { transition: none; }
}
''';

/// `globalThis` slot holding the panel view that is currently open, or null
/// when the panel is closed. Written by both the boot placeholder and the live
/// [SyncPanel] so whichever takes over next can adopt an already-open leaf
/// instead of waiting for the user to close and reopen it.
const _kOpenViewSlot = '__rhyolitePanelOpenView';

/// Registers the panel's view type. MUST run before the first `await` in the
/// plugin's `onLoad`.
///
/// Obsidian restores the workspace layout as soon as the plugin-load phase
/// finishes, and a leaf whose view type is not registered by then is replaced
/// with Obsidian's "plugin no longer active" placeholder for the rest of the
/// session. Registration therefore cannot wait for the session the panel
/// eventually displays (auth, database, engine) — which is why the view's
/// `onOpen`/`onClose` go through `globalThis` slots: this function installs a
/// placeholder into them, and [SyncPanel.register] re-points them at the real
/// panel once boot has something to show.
void registerSyncPanelView(PluginHandle plugin, {LogScope? logger}) {
  final ctor = jsu.getProperty<JSObject?>(
    jsu.globalThis,
    '__rhyoliteSyncPanelViewCtor',
  );
  if (ctor == null) {
    logger?.warning('sync panel: view ctor missing — build shim not injected');
    return;
  }

  // The slot lives on globalThis and therefore outlives a disable/enable
  // cycle. Layout restore happens after this runs, so nothing of ours can be
  // open yet: anything still in there is a detached view from the previous
  // load, and adopting it would render into a dead DOM node.
  jsu.setProperty(jsu.globalThis, _kOpenViewSlot, null);

  jsu.setProperty(
    jsu.globalThis,
    '__rhyolitePanelOnOpen',
    jsu.allowInterop((JSObject view) {
      jsu.setProperty(jsu.globalThis, _kOpenViewSlot, view);
      _renderBootPlaceholder(view);
    }),
  );
  jsu.setProperty(
    jsu.globalThis,
    '__rhyolitePanelOnClose',
    jsu.allowInterop((JSObject _) {
      jsu.setProperty(jsu.globalThis, _kOpenViewSlot, null);
    }),
  );

  // registerView must run exactly once per plugin load — Obsidian throws on a
  // duplicate view type, and a soft restart re-runs boot with the SAME plugin
  // object. The flag lives on the plugin (torn down on unload, fresh on
  // re-enable), so registration tracks the plugin lifecycle.
  final already =
      jsu.getProperty<bool?>(plugin.raw, '__rhyolitePanelRegistered') ?? false;
  if (already) return;
  jsu.callMethod<void>(plugin.raw, 'registerView', [
    SyncPanel.viewType,
    jsu.allowInterop(
      (JSObject leaf) => jsu.callConstructor<JSObject>(ctor, [leaf]),
    ),
  ]);
  jsu.setProperty(plugin.raw, '__rhyolitePanelRegistered', true);
}

/// What an open leaf shows between layout restore and the panel being ready.
/// Deliberately a single line: it exists so the sidebar isn't blank or, worse,
/// claiming the plugin is gone — not to preview a panel that has no data yet.
void _renderBootPlaceholder(JSObject view) {
  final contentEl = jsu.getProperty<JSObject?>(view, 'contentEl');
  if (contentEl == null) return;
  jsu.callMethod<void>(contentEl, 'empty', []);
  final el = jsu.callMethod<JSObject>(contentEl, 'createEl', ['div']);
  jsu.setProperty(el, 'className', 'rh-panel rh-booting');
  jsu.setProperty(el, 'textContent', S.panelStarting);
}

/// Docked right-side panel surfacing live sync state and the actions/warnings
/// that don't fit the status-bar dot. Deliberately leads with what a
/// managed-sync competitor *can't* show — end-to-end encryption, conflict-free
/// text merges, the storage tier — not just a stats table.
///
/// The view class itself (an Obsidian `ItemView` subclass) is authored in JS
/// and injected into `main.js` by `bin/build.dart` — dart2js can't subclass a
/// JS class. Its constructor lands on `globalThis.__rhyoliteSyncPanelViewCtor`;
/// its `onOpen`/`onClose` call back into the callbacks this class installs.
///
/// Rendering is split in two: a skeleton built once per view open (header,
/// hero, meter, actions) whose nodes are then updated in place, and the list
/// sections below it, rebuilt wholesale on every render. Keeping the animated
/// bits (status pulse, indeterminate bar, spinner) out of the rebuilt part is
/// what stops them from restarting on every engine event.
class SyncPanel {
  SyncPanel({
    required PluginHandle plugin,
    required ISyncEngine engine,
    required String vaultName,
    required bool encrypted,
    required String backendLabel,
    required String planLabel,
    required void Function() onOpenSettings,
    void Function()? onOpenFaq,
    required Future<void> Function() onBrowseVersions,
    required bool Function() isPaused,
    required Future<void> Function(bool paused) onSetPaused,
    SyncStartBlock? Function()? startBlock,
    Future<void> Function()? onSignIn,
    Future<void> Function()? onConnectVault,
    Future<void> Function()? onUnlock,
    Future<void> Function()? onReconnect,
    Future<({int usedBytes, int quotaBytes})?> Function()? onFetchUsage,
    Future<int> Function()? onSettingsSize,
    Future<({int count, int bytes})?> Function()? onPluginStats,
    void Function()? onStorageDetails,
    void Function()? onPlanAction,
    Future<void> Function(List<String> fileIds)? onConfirmVanished,
    LogScope? logger,
  }) : _plugin = plugin,
       _engine = engine,
       _vaultName = vaultName,
       _encrypted = encrypted,
       _backendLabel = backendLabel,
       _planLabel = planLabel,
       _onOpenSettings = onOpenSettings,
       _onOpenFaq = onOpenFaq,
       _onBrowseVersions = onBrowseVersions,
       _isPaused = isPaused,
       _onSetPaused = onSetPaused,
       _startBlock = startBlock,
       _onSignIn = onSignIn,
       _onConnectVault = onConnectVault,
       _onUnlock = onUnlock,
       _onReconnect = onReconnect,
       _onFetchUsage = onFetchUsage,
       _onSettingsSize = onSettingsSize,
       _onPluginStats = onPluginStats,
       _onStorageDetails = onStorageDetails,
       _onPlanAction = onPlanAction,
       _onConfirmVanished = onConfirmVanished,
       _log = logger;

  static const viewType = 'rhyolite-sync-panel';

  final PluginHandle _plugin;
  final ISyncEngine _engine;
  final String _vaultName;
  final bool _encrypted;
  final String _backendLabel;
  final String _planLabel;
  final void Function() _onOpenSettings;

  /// Opens the public FAQ. Optional: a build with no site URL simply has no
  /// help button rather than one that leads nowhere.
  final void Function()? _onOpenFaq;
  final Future<void> Function() _onBrowseVersions;
  final bool Function() _isPaused;
  final Future<void> Function(bool paused) _onSetPaused;

  /// Live answer to "can the engine start at all?" — re-read on every render
  /// rather than captured, so a sign-in mid-session clears the banner.
  final SyncStartBlock? Function()? _startBlock;
  final Future<void> Function()? _onSignIn;
  final Future<void> Function()? _onConnectVault;
  final Future<void> Function()? _onUnlock;
  final Future<void> Function()? _onReconnect;
  final Future<({int usedBytes, int quotaBytes})?> Function()? _onFetchUsage;
  final Future<int> Function()? _onSettingsSize;
  final Future<({int count, int bytes})?> Function()? _onPluginStats;
  final void Function()? _onStorageDetails;

  /// Opens the account page from the plan-alert strip. Null in self-host,
  /// where there is no account and the strip never appears.
  final void Function()? _onPlanAction;

  /// The plan alert to show, pushed in by the host after each subscription
  /// lookup. Quiet by default: a panel must not invent an alert from the
  /// absence of an answer.
  PlanNotice _planNotice = PlanNotice.quiet;

  /// Shows (or clears) the plan alert. Cheap to call with an unchanged value —
  /// the host does so after every lookup.
  void setPlanNotice(PlanNotice notice) {
    if (notice == _planNotice) return;
    _planNotice = notice;
    _render();
  }

  /// Propagates the deletes the user approved from the vanished-files section.
  final Future<void> Function(List<String> fileIds)? _onConfirmVanished;
  final LogScope? _log;

  /// Approx synced-settings footprint, fetched once per open (null until then
  /// or when settings sync has never run).
  int? _settingsBytes;

  /// Synced plugin count + bytes, fetched once per open. Null when plugin-code
  /// sync is off, which is also why the tile disappears entirely rather than
  /// showing a zero.
  ({int count, int bytes})? _pluginStats;

  StreamSubscription<SyncEngineEvent>? _sub;
  Timer? _renderTimer;

  /// Keeps the relative timestamps ("synced 2m ago") honest while the panel
  /// sits open with no events coming in. Runs only while a view is open.
  Timer? _tickTimer;

  /// Short retry loop for the settings/plugin footprints, which are usually
  /// still empty when the panel first opens on a cold start.
  Timer? _sideStatsTimer;
  DateTime? _sideStatsAt;

  /// contentEl of the currently-open view, or null when the panel is closed.
  JSObject? _contentEl;

  // ── Skeleton nodes (alive while the view is open) ─────────────────────────
  JSObject? _panelEl;
  JSObject? _statusEl;
  JSObject? _subEl;
  JSObject? _errEl;
  JSObject? _progressEl;
  JSObject? _progressFillEl;
  JSObject? _countersEl;
  JSObject? _statsEl;
  JSObject? _meterEl;
  JSObject? _meterTitleEl;
  JSObject? _meterValueEl;
  JSObject? _meterFillEl;
  JSObject? _alertEl;
  JSObject? _alertTitleEl;
  JSObject? _alertHintEl;
  JSObject? _alertBtnEl;
  JSObject? _refreshEl;
  JSObject? _primaryBtnEl;
  JSObject? _primaryIconEl;
  JSObject? _primaryLabelEl;
  JSObject? _sectionsEl;

  // ── Live state ───────────────────────────────────────────────────────────
  // Connection/activity model — green ("ready") means genuinely connected with
  // no work pending. The engine emits no "sync finished" event, so activity is
  // a transient overlay cleared by an idle-debounce timer.
  bool _everStarted = false;

  /// A resume the user asked for, still in flight.
  ///
  /// Pause leaves the panel in `stopped`, and a resume produces no engine
  /// event until the engine actually starts — which waits on the single
  /// lifecycle lane and can therefore sit behind a stalled restart for as long
  /// as that one takes to time out. Through all of it the hero kept saying
  /// "sync stopped": the button had flipped, so the only thing on screen that
  /// answered the click was the button itself. Held until the first engine
  /// event, which knows better than we do.
  bool _resuming = false;
  bool _connected = false;
  bool _connecting = false;
  int _connectAttempt = 0;
  _Blocker _blocker = _Blocker.none;
  bool _activity = false;

  /// The engine says it is inside work the user must not interrupt.
  ///
  /// Distinct from [_activity], which is a 3 s idle debounce over whatever
  /// events happen to arrive: that made the indicator depend on how densely a
  /// phase reports progress. When the pull's prefetch started batching, its
  /// progress spread from every ~150 ms to roughly every 5 s and the debounce
  /// began lapsing mid-download — showing "up to date" while 47 seconds of
  /// transfer were still to come. Someone who believes that and quits loses
  /// the rest of it.
  bool _busy = false;
  Timer? _activityTimer;
  Timer? _errorTimer;

  bool _hasPending = false;
  ({int completed, int total})? _progress;
  String? _lastError;
  DateTime? _lastSyncedAt;
  int _uploaded = 0;
  int _downloaded = 0;

  /// Last ~8 synced files, newest first — proves sync is alive, per-file.
  final List<({bool up, String path, DateTime at})> _recent = [];

  /// Size-blocked files keyed by path (latest event per path wins).
  final Map<String, SyncFileSizeBlocked> _blocked = {};

  /// Paths the server holds in a format this build cannot read. Unlike an
  /// error this does not clear itself: it recurs on every reconcile and ends
  /// only when the user updates, so it lives in a list rather than a banner.
  final Set<String> _needsNewerClient = {};

  /// Files this device held and no longer does, reported at startup. Keyed by
  /// fileId because that is what the confirmation takes — the engine refuses
  /// to re-derive the set, so the user acts on exactly the list they saw.
  Map<String, String> _vanished = const {};

  /// Conflicts where a branch's bytes were unrecoverable — hard warnings.
  final List<SyncDataLoss> _dataLoss = [];

  /// In-flight blob transfers keyed by path — the active-transfers monitor.
  final Map<String, ({bool upload, int sent, int total})> _transfers = {};

  /// Cached managed-storage usage; null until first fetch (or not managed).
  ({int usedBytes, int quotaBytes})? _usage;
  bool _usageFetching = false;

  // ---------------------------------------------------------------------------
  // Registration / lifecycle
  // ---------------------------------------------------------------------------

  void register() {
    // Re-point the JS view's callbacks at THIS instance every boot, replacing
    // the placeholder [registerSyncPanelView] installed.
    jsu.setProperty(
      jsu.globalThis,
      '__rhyolitePanelOnOpen',
      jsu.allowInterop((JSObject view) => _onViewOpen(view)),
    );
    jsu.setProperty(
      jsu.globalThis,
      '__rhyolitePanelOnClose',
      jsu.allowInterop((JSObject _) => _onViewClose()),
    );

    // The view type is registered before boot starts, so a leaf restored with
    // the workspace can already be open by the time we get here — showing the
    // placeholder. Adopt it instead of waiting for the user to close and
    // reopen the panel.
    final pending = jsu.getProperty<JSObject?>(
      jsu.globalThis,
      _kOpenViewSlot,
    );
    if (pending != null) _onViewOpen(pending);

    _sub = _engine.events.listen(_onEvent);
  }

  /// Re-renders from the outside. The panel is otherwise event-driven, and the
  /// conditions behind [SyncStartBlock] produce no engine events — a sign-in
  /// while the engine is down would sit behind a stale banner until the 30s
  /// tick. No-op when no view is open.
  void refresh() => _scheduleRender();

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _renderTimer?.cancel();
    _renderTimer = null;
    _activityTimer?.cancel();
    _activityTimer = null;
    _errorTimer?.cancel();
    _errorTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    _sideStatsTimer?.cancel();
    _sideStatsTimer = null;
    _contentEl = null;
    _dropSkeleton();
  }

  /// Opens (or focuses) the panel in the right sidebar.
  Future<void> reveal() async {
    final workspace = jsu.getProperty<JSObject?>(_plugin.app.raw, 'workspace');
    if (workspace == null) return;

    JSObject? leaf;
    final existing = jsu.callMethod<JSObject?>(workspace, 'getLeavesOfType', [
      viewType,
    ]);
    if (existing != null &&
        (jsu.getProperty<int?>(existing, 'length') ?? 0) > 0) {
      leaf = jsu.callMethod<JSObject?>(existing, 'at', [0]);
    } else {
      leaf = jsu.callMethod<JSObject?>(workspace, 'getRightLeaf', [false]);
      if (leaf == null) return;
      await jsu.promiseToFuture<void>(
        jsu.callMethod(leaf, 'setViewState', [
          jsu.jsify(<String, Object?>{'type': viewType, 'active': true}),
        ]),
      );
    }
    if (leaf == null) return;
    jsu.callMethod<void>(workspace, 'revealLeaf', [leaf]);
  }

  // ---------------------------------------------------------------------------
  // View open/close
  // ---------------------------------------------------------------------------

  void _onViewOpen(JSObject view) {
    // Kept current for the same reason the placeholder writes it: a boot that
    // re-runs (soft restart) builds a new panel, which adopts this leaf.
    jsu.setProperty(jsu.globalThis, _kOpenViewSlot, view);
    _contentEl = jsu.getProperty<JSObject>(view, 'contentEl');
    _dropSkeleton();
    _render();
    _maybeFetchUsage();
    _fetchSideStats();
    _startSideStatsRetries();
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _scheduleRender(),
    );
  }

  /// Settings and plugin footprints, fetched together.
  ///
  /// On a cold start the panel usually opens before settings sync has produced
  /// anything, so a single fetch at open time leaves those tiles missing for
  /// the rest of the session. [_startSideStatsRetries] re-runs this until the
  /// stores answer with something — cheap, because both queries only get
  /// expensive once they have data to report, at which point retrying stops.
  void _fetchSideStats() {
    _sideStatsAt = DateTime.now();

    final settings = _onSettingsSize;
    if (settings != null) {
      settings()
          .then((n) {
            if (n == _settingsBytes) return;
            _settingsBytes = n;
            _scheduleRender();
          })
          .catchError((Object e) {
            _log?.warning('sync panel: settings size fetch failed: $e');
          });
    }

    final plugins = _onPluginStats;
    if (plugins != null) {
      plugins()
          .then((stats) {
            if (stats == null && _pluginStats == null) return;
            _pluginStats = stats;
            _scheduleRender();
          })
          .catchError((Object e) {
            _log?.warning('sync panel: plugin stats fetch failed: $e');
          });
    }
  }

  /// Polls the side stats while they have nothing to show, then stops. Bounded
  /// by attempt count so a vault that legitimately has no synced settings or
  /// plugins doesn't get queried forever.
  void _startSideStatsRetries() {
    _sideStatsTimer?.cancel();
    var attempts = 0;
    _sideStatsTimer = Timer.periodic(const Duration(seconds: 8), (t) {
      attempts++;
      if (_contentEl == null || _sideStatsSettled || attempts > 12) {
        t.cancel();
        _sideStatsTimer = null;
        return;
      }
      _fetchSideStats();
    });
  }

  /// True once every side stat that has something to report has reported it.
  bool get _sideStatsSettled {
    final settings =
        _onSettingsSize == null ||
        (_settingsBytes != null && _settingsBytes! > 0);
    final plugins = _onPluginStats == null || _pluginStats != null;
    return settings && plugins;
  }

  /// Re-reads the side stats after a sync burst settles — that's when new
  /// settings or plugin records land. Throttled so a chatty vault doesn't
  /// re-scan the settings store every few seconds.
  void _refreshSideStatsIfStale() {
    if (_contentEl == null) return;
    final at = _sideStatsAt;
    if (at != null &&
        DateTime.now().difference(at) < const Duration(seconds: 30)) {
      return;
    }
    _fetchSideStats();
  }

  /// Detaches any open panel leaves — call on plugin unload so a disabled
  /// plugin doesn't leave an orphaned, unbacked view in the sidebar.
  void closeLeaves() {
    final workspace = jsu.getProperty<JSObject?>(_plugin.app.raw, 'workspace');
    if (workspace == null) return;
    try {
      jsu.callMethod<void>(workspace, 'detachLeavesOfType', [viewType]);
    } catch (_) {}
  }

  void _onViewClose() {
    jsu.setProperty(jsu.globalThis, _kOpenViewSlot, null);
    _contentEl = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    _sideStatsTimer?.cancel();
    _sideStatsTimer = null;
    _dropSkeleton();
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  void _onEvent(SyncEngineEvent event) {
    switch (event) {
      case SyncStarted():
        // The engine is talking; it owns the status from here.
        _resuming = false;
        _everStarted = true;
        _connecting = true;
        _connected = false;
        _blocker = _Blocker.none;
      case SyncConnecting(:final attempt):
        _connecting = true;
        _connected = false;
        _connectAttempt = attempt;
      case SyncConnected():
        _connected = true;
        _connecting = false;
        _connectAttempt = 0;
        _blocker = _Blocker.none; // a live connection clears a transient error
        _lastError = null;
        _uploaded = 0;
        _downloaded = 0;
      case SyncStopped():
        _everStarted = false;
        _connected = false;
        _connecting = false;
        _busy = false;
        _clearActivity();
      case SyncDisconnected():
        _connected = false;
        _connecting = false;
        _busy = false;
        _clearActivity();
      case SyncBusy(:final busy):
        _busy = busy;
      case SyncPushing():
      case SyncPulling():
        _bumpActivity();
      case SyncFilePushed(:final path):
        _lastSyncedAt = event.timestamp;
        _uploaded++;
        _pushRecent(up: true, path: path, at: event.timestamp);
        _blocked.remove(path); // shrank below the limit and synced
        _bumpActivity();
      case SyncFilePulled(:final path):
        _lastSyncedAt = event.timestamp;
        _downloaded++;
        // It materialised, so this build understands it after all.
        _needsNewerClient.remove(path);
        if (path.isNotEmpty) {
          _pushRecent(up: false, path: path, at: event.timestamp);
        }
        _bumpActivity();
      case SyncPending(:final hasPending):
        _hasPending = hasPending;
      case SyncCursorAdvanced():
        _lastSyncedAt = event.timestamp;
      case SyncStartupBlobUploadProgress(:final completed, :final total):
        _progress = (completed: completed, total: total);
        _bumpActivity();
      case SyncBlobDownloadProgress(:final completed, :final total):
        _progress = (completed: completed, total: total);
        _bumpActivity();
      case SyncStartupBlobUploadDone():
        _progress = null;
        _clearActivity();
        _lastSyncedAt = event.timestamp;
        _usage = null; // storage changed — refetch on next render
        _maybeFetchUsage();
      case SyncBlobDownloadDone():
        _progress = null;
        _clearActivity();
      case SyncBlobTransfer(:final path, :final done):
        if (done) {
          _transfers.remove(path);
        } else {
          _transfers[path] = (
            upload: event.upload,
            sent: event.sentBytes,
            total: event.totalBytes,
          );
        }
        _bumpActivity();
      case SyncFileSizeBlocked():
        _blocked[event.path] = event;
      case SyncFileFormatUnsupported(:final path):
        _needsNewerClient.add(path);
      case SyncFilesVanished(:final pathsByFileId):
        _vanished = pathsByFileId;
      case SyncFileSizeUnblocked(:final path):
        _blocked.remove(path);
      case SyncFileDeleted(:final path):
        _blocked.remove(path);
        _needsNewerClient.remove(path);
      case SyncDataLoss():
        _dataLoss.add(event);
        // Bounded: data-loss is rare, but a very long session must not grow the
        // list without limit. Keep the most recent entries.
        if (_dataLoss.length > 100) {
          _dataLoss.removeRange(0, _dataLoss.length - 100);
        }
      case SyncError(:final message):
        _blocker = _Blocker.error;
        _lastError = message;
        // Transient errors shouldn't stick red forever (the engine stays
        // connected and keeps retrying). Auto-clear after a few seconds unless
        // a harder blocker (auth/sub) supersedes it meanwhile.
        _errorTimer?.cancel();
        _errorTimer = Timer(const Duration(seconds: 6), () {
          _errorTimer = null;
          if (_blocker == _Blocker.error) {
            _blocker = _Blocker.none;
            _lastError = null;
            _render();
          }
        });
      case SessionExpired():
        _blocker = _Blocker.auth;
      case SubscriptionRequired():
        _blocker = _Blocker.sub;
      case SyncServerRejected(:final code) when code.startsWith('auth.'):
        _blocker = _Blocker.auth;
      case SyncServerRejected(:final code) when code.startsWith('app_policy.'):
        _blocker = _Blocker.sub;
      default:
        return; // no visible change — skip the re-render
    }
    _scheduleRender();
  }

  /// Marks sync activity live and (re)arms the idle-debounce. The engine emits
  /// no "finished" event, so after 3s of silence we fall back to the base
  /// connection status (ready/pending) instead of showing "Syncing…" forever.
  void _bumpActivity() {
    _activity = true;
    _activityTimer?.cancel();
    _activityTimer = Timer(const Duration(seconds: 3), () {
      _activityTimer = null;
      _activity = false;
      // A burst that just finished may have brought in new settings or plugin
      // records — that's the cheapest moment to notice.
      _refreshSideStatsIfStale();
      _render();
    });
  }

  void _clearActivity() {
    _activityTimer?.cancel();
    _activityTimer = null;
    _activity = false;
    _progress = null;
  }

  void _pushRecent({
    required bool up,
    required String path,
    required DateTime at,
  }) {
    _recent.removeWhere((e) => e.path == path && e.up == up);
    _recent.insert(0, (up: up, path: path, at: at));
    if (_recent.length > 8) _recent.removeRange(8, _recent.length);
  }

  // ---------------------------------------------------------------------------
  // Storage usage (managed only)
  // ---------------------------------------------------------------------------

  /// Force a re-fetch of the managed usage meter (the refresh button).
  void _refreshUsage() {
    if (_usageFetching) return;
    _usage = null;
    _maybeFetchUsage(); // sets _usageFetching synchronously, kicks off the fetch
    _render(); // reflect the fetching state immediately
  }

  void _maybeFetchUsage() {
    final fetch = _onFetchUsage;
    if (fetch == null || _usageFetching || _contentEl == null) return;
    if (_usage != null) return; // have a fresh value
    _usageFetching = true;
    fetch()
        .then((u) {
          _usage = u;
        })
        .catchError((Object e) {
          _log?.warning('sync panel: usage fetch failed: $e');
        })
        .whenComplete(() {
          _usageFetching = false;
          _scheduleRender();
        });
  }

  // ---------------------------------------------------------------------------
  // Rendering — coalesced so a burst of events repaints once.
  // ---------------------------------------------------------------------------

  void _scheduleRender() {
    if (_contentEl == null || _renderTimer != null) return;
    _renderTimer = Timer(const Duration(milliseconds: 150), () {
      _renderTimer = null;
      _render();
    });
  }

  void _dropSkeleton() {
    _panelEl = null;
    _statusEl = null;
    _subEl = null;
    _errEl = null;
    _progressEl = null;
    _progressFillEl = null;
    _countersEl = null;
    _statsEl = null;
    _meterEl = null;
    _meterTitleEl = null;
    _meterValueEl = null;
    _meterFillEl = null;
    _alertEl = null;
    _alertTitleEl = null;
    _alertHintEl = null;
    _alertBtnEl = null;
    _refreshEl = null;
    _primaryBtnEl = null;
    _primaryIconEl = null;
    _primaryLabelEl = null;
    _sectionsEl = null;
  }

  /// Builds the parts that stay alive for the lifetime of the open view. Every
  /// node captured here is later updated in place by [_render].
  void _buildSkeleton(JSObject root) {
    jsu.callMethod<void>(root, 'empty', []);
    _addClass(root, 'rhyolite-sync-panel-content');

    final panel = _el(root, 'div', cls: 'rh-panel');
    _panelEl = panel;

    // ── Vault identity ──
    final head = _el(panel, 'div', cls: 'rh-head');
    _icon(head, 'vault');
    _el(
      head,
      'div',
      cls: 'rh-vault',
      text: _vaultName.isEmpty ? '—' : _vaultName,
    );

    // ── Trust chips: what a managed competitor can't claim ──
    final chips = _el(panel, 'div', cls: 'rh-chips');
    if (_encrypted) {
      final secure = _el(chips, 'span', cls: 'rh-chip mod-secure');
      _icon(secure, 'lock');
      _el(secure, 'span', text: S.endToEndEncrypted);
    }
    final backend = _el(chips, 'span', cls: 'rh-chip');
    _attr(backend, 'aria-label', S.panelStorageLabel);
    _icon(backend, 'server');
    _el(backend, 'span', text: _backendLabel);

    // ── Status hero ──
    final hero = _el(panel, 'div', cls: 'rh-hero');
    final top = _el(hero, 'div', cls: 'rh-hero-top');
    _el(top, 'span', cls: 'rh-dot');
    _statusEl = _el(top, 'span', cls: 'rh-status');
    _subEl = _el(hero, 'div', cls: 'rh-sub');
    _errEl = _el(hero, 'div', cls: 'rh-err rh-hidden');
    final progress = _el(hero, 'div', cls: 'rh-track rh-hidden');
    _progressEl = progress;
    _progressFillEl = _el(progress, 'div', cls: 'rh-fill');
    _countersEl = _el(hero, 'div', cls: 'rh-counters rh-hidden');

    // ── Stat tiles (contents rebuilt per render) ──
    _statsEl = _el(panel, 'div', cls: 'rh-stats');

    // ── Managed quota meter ──
    final meter = _el(panel, 'div', cls: 'rh-meter rh-hidden');
    _meterEl = meter;
    final meterHead = _el(meter, 'div', cls: 'rh-meter-head');
    _meterTitleEl = _el(meterHead, 'span', cls: 'rh-meter-title');
    _meterValueEl = _el(meterHead, 'span', cls: 'rh-meter-value');
    final meterTrack = _el(meter, 'div', cls: 'rh-track');
    _meterFillEl = _el(meterTrack, 'div', cls: 'rh-fill');

    // ── Plan alert ──
    //
    // Directly under the meter, because it is the answer to the question the
    // meter raises: a quota that shrank to the free tier looks like a bug
    // until something says the subscription ended. Hidden unless there is
    // something to act on — a standing free tier is a tier, not a warning.
    final alert = _el(panel, 'div', cls: 'rh-alert rh-hidden');
    _alertEl = alert;
    final alertBody = _el(alert, 'div', cls: 'rh-alert-body');
    _alertTitleEl = _el(alertBody, 'div', cls: 'rh-alert-title');
    _alertHintEl = _el(alertBody, 'div', cls: 'rh-alert-hint');
    _alertBtnEl = _el(alert, 'button', cls: 'rh-alert-btn mod-cta');
    _onClick(_alertBtnEl!, () => _onPlanAction?.call());

    // ── Storage details link (+ usage refresh) ──
    final onDetails = _onStorageDetails;
    if (onDetails != null) {
      // The refresh sits at the far right, away from the link — no mis-taps
      // between the two.
      final links = _el(panel, 'div', cls: 'rh-links');
      final link = _el(links, 'span', cls: 'rh-link', text: S.storageDetails);
      _onClick(link, onDetails);

      if (_onFetchUsage != null) {
        final refresh = _el(links, 'span', cls: 'rh-refresh');
        _attr(refresh, 'aria-label', S.refreshStorageUsage);
        _setIcon(refresh, 'refresh-cw');
        _refreshEl = refresh;
        _onClick(refresh, _refreshUsage); // no-ops while a fetch is in flight
      }
    }

    // ── Actions ──
    final actions = _el(panel, 'div', cls: 'rh-actions');
    final primary = _el(actions, 'button', cls: 'rh-primary');
    _primaryBtnEl = primary;
    _primaryIconEl = _el(primary, 'span', cls: 'rh-icon');
    _primaryLabelEl = _el(primary, 'span');
    _onClick(primary, _handlePrimaryAction);

    final settings = _el(actions, 'button', cls: 'rh-iconbtn');
    _attr(settings, 'aria-label', S.settingsButton);
    _setIcon(settings, 'settings');
    _onClick(settings, _onOpenSettings);

    // History is always reachable here — it used to hide until a file synced
    // in this session, which made a freshly-opened panel a dead end.
    final history = _el(actions, 'button', cls: 'rh-iconbtn');
    _attr(history, 'aria-label', S.browseVersions);
    _setIcon(history, 'history');
    _onClick(history, _onBrowseVersions);

    // Most "is it broken?" questions are really questions about what this
    // sync does differently — people arrive carrying habits from plugins that
    // behave otherwise. The answers live on the site; the panel is where the
    // doubt occurs, so it gets the shortest path to them.
    final faq = _onOpenFaq;
    if (faq != null) {
      final help = _el(actions, 'button', cls: 'rh-iconbtn');
      _attr(help, 'aria-label', S.faqButton);
      _setIcon(help, 'help-circle');
      _onClick(help, faq);
    }

    // ── Trust footer ──
    final footer = _el(panel, 'div', cls: 'rh-footer');
    _icon(footer, 'git-merge');
    _el(footer, 'span', text: S.textMergesLine);

    // ── Lists (rebuilt per render) ──
    _sectionsEl = _el(panel, 'div', cls: 'rh-sections');
  }

  void _render() {
    final root = _contentEl;
    if (root == null) return;
    if (_panelEl == null) _buildSkeleton(root);
    final panel = _panelEl;
    if (panel == null) return;

    final status = _effective();
    jsu.setProperty(panel, 'className', 'rh-panel ${_statusClass(status)}');

    _renderHero(status);
    _renderStats();
    _renderMeter();
    _renderAlert();
    _renderActions(status);
    _renderSections();
  }

  /// The plan strip: a plan that ended or is about to, else a full quota.
  ///
  /// The plan wins when both are true, because it is the cause and the quota
  /// is the symptom — "storage is full" under a lapsed subscription sends the
  /// user to delete notes when what they need is the renew button.
  void _renderAlert() {
    final alert = _alertEl;
    if (alert == null) return;

    final notice = _planNotice;
    final usage = _usage;
    final full = usage != null &&
        usage.quotaBytes > 0 &&
        usage.usedBytes >= usage.quotaBytes;

    final String title;
    final String hint;
    final String action;
    if (!notice.isQuiet) {
      final date = notice.date == null ? null : formatPlanDay(notice.date!);
      final ended = notice.alert == PlanAlert.ended;
      title = ended
          ? (date == null ? S.planEndedNoDate : S.planEndedOn(date))
          : S.planEndingOn(date ?? '');
      hint = ended ? S.planEndedHint : S.planEndingHint;
      action = S.planRenew;
    } else if (full) {
      title = S.planQuotaFull;
      hint = S.planQuotaFullHint;
      action = S.planSeePlans;
    } else {
      _setHidden(alert, true);
      return;
    }

    // Only the ended/full states are urgent. "Ends in a few days" is a
    // reminder, and colouring it like a failure would cry wolf.
    final urgent = full || notice.alert == PlanAlert.ended;
    _toggleClass(alert, 'is-urgent', urgent);
    _setText(_alertTitleEl!, title);
    _setText(_alertHintEl!, hint);
    _setText(_alertBtnEl!, action);
    // Without somewhere to send them, the strip still explains — it just
    // stops promising an action it cannot perform.
    _setHidden(_alertBtnEl!, _onPlanAction == null);
    _setHidden(alert, false);
  }

  void _renderHero(_Status status) {
    _setText(_statusEl!, _statusLabel(status));

    // "Not connected" is a claim about the connection, not about history — a
    // freshly-connected vault with nothing to transfer has no last-sync time
    // yet, and saying "not connected" under "Up to date" contradicts the dot.
    // In that case the sub-line simply stays out of the way.
    //
    // A missing precondition takes the sub-line outright, even when this vault
    // synced before: "synced 3h ago" under "Not signed in" reads as reassurance
    // when the whole point is that nothing is syncing now.
    final syncedAt = _lastSyncedAt;
    final offline = status == _Status.offline || status == _Status.stopped;
    final String sub;
    if (status == _Status.blocked) {
      sub = switch (_currentBlock()) {
        SyncStartBlock.signedOut => S.blockedSignedOutHint,
        SyncStartBlock.noVault => S.blockedNoVaultHint,
        SyncStartBlock.locked => S.blockedLockedHint,
        SyncStartBlock.noServer => S.blockedNoServerHint,
        SyncStartBlock.storageRefused => S.blockedStorageRefusedHint,
        null => '',
      };
    } else {
      sub = syncedAt != null
          ? S.syncedAgo(_ago(syncedAt))
          : (offline ? S.notConnected : '');
    }
    _setText(_subEl!, sub);
    _setHidden(_subEl!, sub.isEmpty);

    final error = _blocker == _Blocker.error ? _lastError : null;
    _setText(_errEl!, error ?? '');
    _setHidden(_errEl!, error == null);

    // Determinate while the engine reports counts, indeterminate while it's
    // merely busy — either way the element itself survives the render, so the
    // animation doesn't stutter.
    final progress = _progress;
    final busy = status == _Status.syncing;
    final determinate = progress != null && progress.total > 0;
    _setHidden(_progressEl!, !busy);
    _toggleClass(_progressEl!, 'is-indeterminate', busy && !determinate);
    if (determinate) {
      _setWidth(
        _progressFillEl!,
        (progress.completed / progress.total).clamp(0.0, 1.0),
      );
    } else {
      // Drop the inline width — it would otherwise beat the indeterminate
      // rule's 36% and freeze the sliding bar at the last known fraction.
      _clearWidth(_progressFillEl!);
    }

    final counters = _countersEl!;
    jsu.callMethod<void>(counters, 'empty', []);
    final hasCounters = _uploaded > 0 || _downloaded > 0;
    _setHidden(counters, !hasCounters);
    if (hasCounters) {
      _attr(
        counters,
        'aria-label',
        S.uploadDownloadReport(_uploaded, _downloaded),
      );
      final up = _el(counters, 'span', cls: 'rh-counter');
      _icon(up, 'arrow-up');
      _el(up, 'span', text: '$_uploaded');
      final down = _el(counters, 'span', cls: 'rh-counter');
      _icon(down, 'arrow-down');
      _el(down, 'span', text: '$_downloaded');
    }
  }

  void _renderStats() {
    final el = _statsEl!;
    jsu.callMethod<void>(el, 'empty', []);

    final stats = _engine.statsSnapshot();
    if (stats != null) {
      _stat(
        el,
        icon: 'file-text',
        label: S.files,
        value: '${stats.totalFiles - stats.tombstones}',
      );
      _stat(
        el,
        icon: 'hard-drive',
        label: S.vaultSizeLabel,
        value: _bytes(stats.totalSizeBytes),
      );
    }
    final settingsBytes = _settingsBytes;
    if (settingsBytes != null && settingsBytes > 0) {
      _stat(
        el,
        icon: 'settings',
        label: S.settingsSizeLabel,
        value: _bytes(settingsBytes),
      );
    }
    final pluginStats = _pluginStats;
    if (pluginStats != null && pluginStats.count > 0) {
      _stat(
        el,
        icon: 'package',
        label: S.pluginsSizeLabel,
        value: '${pluginStats.count} · ${_bytes(pluginStats.bytes)}',
      );
    }
  }

  void _renderMeter() {
    // Spins whenever a fetch is in flight — including the very first one, when
    // there is no meter to show yet.
    final refresh = _refreshEl;
    if (refresh != null) _toggleClass(refresh, 'is-busy', _usageFetching);

    final meter = _meterEl!;
    final usage = _usage;
    final show = usage != null && usage.quotaBytes > 0;
    _setHidden(meter, !show);
    if (!show) return;

    final frac = (usage.usedBytes / usage.quotaBytes).clamp(0.0, 1.0);
    _toggleClass(meter, 'is-near', frac >= 0.9);
    _setText(_meterTitleEl!, S.storageMeterTitle(_planLabel));
    _setText(
      _meterValueEl!,
      '${_bytes(usage.usedBytes)} / ${_bytes(usage.quotaBytes)}',
    );
    _setWidth(_meterFillEl!, frac);
  }

  void _renderActions(_Status status) {
    // When sync is stuck (offline / error / auth-expired) the primary control
    // becomes Reconnect — a Pause toggle is useless when we can't reach the
    // server, and the user's intent there is "get me back online". Otherwise
    // the primary control is the Pause/Resume toggle (Resume highlighted so a
    // paused vault is obviously actionable).
    //
    // A missing precondition overrides both: neither pausing nor reconnecting
    // means anything until the user signs in / picks a vault / unlocks, so the
    // button becomes that step and says so.
    final block = status == _Status.blocked ? _currentBlock() : null;
    if (block != null) {
      jsu.setProperty(_primaryBtnEl!, 'className', 'rh-primary mod-cta');
      _setIcon(_primaryIconEl!, _blockIcon(block));
      _setText(_primaryLabelEl!, _blockAction(block));
      return;
    }

    final reconnect = _isReconnectAction(status);
    final paused = _isPaused();
    final label = reconnect
        ? S.reconnect
        : (paused ? S.resumeSync : S.pauseSync);
    final icon = reconnect ? 'refresh-cw' : (paused ? 'play' : 'pause');
    final cta = reconnect || paused;

    jsu.setProperty(
      _primaryBtnEl!,
      'className',
      cta ? 'rh-primary mod-cta' : 'rh-primary',
    );
    _setIcon(_primaryIconEl!, icon);
    _setText(_primaryLabelEl!, label);
  }

  void _renderSections() {
    final root = _sectionsEl!;
    jsu.callMethod<void>(root, 'empty', []);

    // ── Active transfers ──
    if (_transfers.isNotEmpty) {
      final section = _section(
        root,
        icon: 'arrow-up-down',
        title: S.activeTransfers(_transfers.length),
      );
      for (final entry in _transfers.entries) {
        _transferRow(section, entry.key, entry.value);
      }
    }

    // ── Recent activity ──
    if (_recent.isNotEmpty) {
      final section = _section(
        root,
        icon: 'clock',
        title: S.recent,
        count: _recent.length,
      );
      for (final e in _recent) {
        final row = _el(section, 'div', cls: 'rh-row');
        _icon(
          row,
          e.up ? 'arrow-up' : 'arrow-down',
          cls: e.up ? 'rh-row-arrow mod-up' : 'rh-row-arrow mod-down',
        );
        _path(row, e.path);
        _el(row, 'span', cls: 'rh-row-meta', text: _ago(e.at));
      }
    }

    // ── Size-blocked files ──
    if (_blocked.isNotEmpty) {
      final section = _section(
        root,
        icon: 'alert-triangle',
        title: S.tooLargeToSync(_blocked.length),
        mod: 'mod-warn',
      );
      _el(section, 'div', cls: 'rh-hint', text: S.tooLargeHint);
      final entries = _blocked.values.toList()
        ..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
      for (final b in entries.take(20)) {
        final card = _el(section, 'div', cls: 'rh-card mod-warn');
        _path(_el(card, 'div', cls: 'rh-card-title'), b.path);
        _el(
          card,
          'div',
          cls: 'rh-card-meta',
          text: S.blockedMeta(_bytes(b.sizeBytes), _bytes(b.limitBytes)),
        );
      }
      if (_blocked.length > 20) {
        _el(
          section,
          'div',
          cls: 'rh-more',
          text: S.andMore(_blocked.length - 20),
        );
      }
    }

    // ── Files this build cannot read ──
    // ── Files gone since last run ──
    // A question, not a notice. The engine deliberately refuses to decide
    // this: a vault that failed to mount produces the same list as a folder
    // the user emptied, and propagating the wrong answer deletes their notes
    // everywhere. So both outcomes are spelled out and neither is default.
    if (_vanished.isNotEmpty) {
      final section = _section(
        root,
        icon: 'trash-2',
        title: S.vanishedFiles(_vanished.length),
        mod: 'mod-warn',
      );
      _el(section, 'div', cls: 'rh-hint', text: S.vanishedFilesHint);
      final paths = _vanished.values.toList()..sort();
      for (final p in paths.take(20)) {
        final card = _el(section, 'div', cls: 'rh-card mod-warn');
        _path(_el(card, 'div', cls: 'rh-card-title'), p);
      }
      if (paths.length > 20) {
        _el(section, 'div', cls: 'rh-more', text: S.andMore(paths.length - 20));
      }
      final row = _el(section, 'div', cls: 'rh-links');
      final confirm = _el(row, 'span', cls: 'rh-link', text: S.vanishedDelete);
      _onClick(confirm, () async {
        final ids = _vanished.keys.toList();
        _vanished = const {};
        _scheduleRender();
        await _onConfirmVanished?.call(ids);
      });
      final keep = _el(row, 'span', cls: 'rh-link', text: S.vanishedKeep);
      _onClick(keep, () async {
        // Dismissed for this session only. Nothing is written: if they really
        // are gone, the next start asks again, which is the right nagging.
        _vanished = const {};
        _scheduleRender();
      });
    }

    // Above the data-loss section on purpose: nothing was lost here, and the
    // fix is one the user can actually perform.
    if (_needsNewerClient.isNotEmpty) {
      final section = _section(
        root,
        icon: 'alert-triangle',
        title: S.needsNewerClient(_needsNewerClient.length),
        mod: 'mod-warn',
      );
      _el(section, 'div', cls: 'rh-hint', text: S.needsNewerClientHint);
      final paths = _needsNewerClient.toList()..sort();
      for (final p in paths.take(20)) {
        final card = _el(section, 'div', cls: 'rh-card mod-warn');
        _path(_el(card, 'div', cls: 'rh-card-title'), p);
      }
      if (paths.length > 20) {
        _el(
          section,
          'div',
          cls: 'rh-more',
          text: S.andMore(paths.length - 20),
        );
      }
    }

    // ── Hard conflict / data-loss warnings ──
    if (_dataLoss.isNotEmpty) {
      final section = _section(
        root,
        icon: 'file-warning',
        title: S.conflictsLostContent(_dataLoss.length),
        mod: 'mod-error',
      );
      for (final d in _dataLoss.reversed.take(20)) {
        final card = _el(section, 'div', cls: 'rh-card mod-error');
        _path(
          _el(card, 'div', cls: 'rh-card-title'),
          d.path.isEmpty ? d.fileId : d.path,
        );
        _el(card, 'div', cls: 'rh-card-meta', text: d.reason);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// Label of the step that unblocks [block].
  static String _blockAction(SyncStartBlock block) => switch (block) {
    SyncStartBlock.signedOut => S.signInButton,
    SyncStartBlock.noVault => S.connectVaultButton,
    SyncStartBlock.storageRefused => S.blockedStorageRefusedAction,
    SyncStartBlock.locked => S.unlock,
    SyncStartBlock.noServer => S.settingsButton,
  };

  static String _blockIcon(SyncStartBlock block) => switch (block) {
    SyncStartBlock.signedOut => 'log-in',
    SyncStartBlock.noVault => 'database',
    SyncStartBlock.locked => 'key',
    SyncStartBlock.noServer => 'settings',
    SyncStartBlock.storageRefused => 'cloud-off',
  };

  /// The primary button is one element whose meaning follows the status, so the
  /// handler re-derives that meaning at click time.
  Future<void> _handlePrimaryAction() async {
    final status = _effective();
    final block = status == _Status.blocked ? _currentBlock() : null;
    if (block != null) {
      await _handleBlockAction(block);
      return;
    }

    final reconnect = _isReconnectAction(status);
    if (reconnect) {
      final onReconnect = _onReconnect;
      if (onReconnect == null) return;
      try {
        await onReconnect();
      } catch (e) {
        _log?.warning('sync panel: reconnect failed: $e');
      }
      return;
    }
    await _handleTogglePause();
  }

  bool _isReconnectAction(_Status status) =>
      _onReconnect != null &&
      !_isPaused() &&
      (status == _Status.offline ||
          status == _Status.error ||
          status == _Status.authExpired);

  /// Runs the step that clears [block]. Every branch falls back to opening
  /// settings, which is where all four are also fixable — a button that does
  /// nothing would be worse than the grey banner this replaces.
  Future<void> _handleBlockAction(SyncStartBlock block) async {
    final direct = switch (block) {
      SyncStartBlock.signedOut => _onSignIn,
      SyncStartBlock.noVault => _onConnectVault,
      SyncStartBlock.locked => _onUnlock,
      SyncStartBlock.noServer => null,
      // Straight to settings: the credentials are what has to change, and no
      // shorter path exists.
      SyncStartBlock.storageRefused => null,
    };
    if (direct == null) {
      _onOpenSettings();
      return;
    }
    try {
      await direct();
    } catch (e) {
      _log?.warning('sync panel: unblock action failed: $e');
    }
    _render();
  }

  Future<void> _handleTogglePause() async {
    final next = !_isPaused();
    // Resuming has nothing to show until the engine emits, so say what is
    // actually happening in the meantime rather than leaving the pre-resume
    // status on screen.
    _resuming = !next;
    // _onSetPaused flips the shared pause flag synchronously (before its first
    // await), so an immediate re-render already reflects the new state.
    final done = _onSetPaused(next);
    _render();
    try {
      await done;
    } catch (e) {
      _log?.warning('sync panel: toggle pause failed: $e');
    } finally {
      // Cleared even when the engine never emitted: a resume that finished
      // without starting anything must not leave a permanent "Connecting...".
      _resuming = false;
    }
    _render();
  }

  // ---------------------------------------------------------------------------
  // DOM helpers (Obsidian's createEl/empty — no innerHTML, review-safe)
  // ---------------------------------------------------------------------------

  JSObject _el(JSObject parent, String tag, {String? text, String? cls}) {
    final opts = <String, Object?>{};
    if (text != null) opts['text'] = text;
    if (cls != null) opts['cls'] = cls;
    return jsu.callMethod<JSObject>(parent, 'createEl', [tag, jsu.jsify(opts)]);
  }

  /// Renders `dir/` muted + `name` normal, with the directory truncating first
  /// so the filename — the part that identifies the file — stays readable.
  void _path(JSObject parent, String path) {
    final wrap = _el(parent, 'span', cls: 'rh-file');
    final slash = path.lastIndexOf('/');
    if (slash > 0) {
      _el(wrap, 'span', cls: 'rh-file-dir', text: path.substring(0, slash + 1));
    }
    _el(
      wrap,
      'span',
      cls: 'rh-file-name',
      text: slash >= 0 ? path.substring(slash + 1) : path,
    );
  }

  void _stat(
    JSObject parent, {
    required String icon,
    required String label,
    required String value,
  }) {
    final tile = _el(parent, 'div', cls: 'rh-stat');
    final head = _el(tile, 'div', cls: 'rh-stat-head');
    _icon(head, icon);
    _el(head, 'span', cls: 'rh-stat-label', text: label);
    final valueEl = _el(tile, 'div', cls: 'rh-stat-value', text: value);
    _attr(valueEl, 'aria-label', '$label: $value');
  }

  /// [count] renders as a trailing badge — pass it only for sections whose
  /// title doesn't already spell the number out, or the header reads "Active
  /// transfers (2)  2".
  JSObject _section(
    JSObject root, {
    required String icon,
    required String title,
    int? count,
    String? mod,
  }) {
    final section = _el(
      root,
      'div',
      cls: mod == null ? 'rh-section' : 'rh-section $mod',
    );
    final head = _el(section, 'div', cls: 'rh-section-head');
    _icon(head, icon);
    _el(head, 'span', cls: 'rh-section-title', text: title);
    if (count != null) _el(head, 'span', cls: 'rh-badge', text: '$count');
    return section;
  }

  void _transferRow(
    JSObject parent,
    String path,
    ({bool upload, int sent, int total}) t,
  ) {
    final frac = t.total > 0 ? (t.sent / t.total).clamp(0.0, 1.0) : 0.0;
    final wrap = _el(parent, 'div', cls: 'rh-transfer');

    final row = _el(wrap, 'div', cls: 'rh-row');
    _icon(
      row,
      t.upload ? 'arrow-up' : 'arrow-down',
      cls: t.upload ? 'rh-row-arrow mod-up' : 'rh-row-arrow mod-down',
    );
    _path(row, path);
    _el(
      row,
      'span',
      cls: 'rh-row-meta',
      text: '${_bytes(t.sent)} / ${_bytes(t.total)}',
    );

    final track = _el(wrap, 'div', cls: 'rh-track');
    _setWidth(_el(track, 'div', cls: 'rh-fill'), frac);
  }

  /// Creates a span and fills it with a Lucide icon. A missing icon name (older
  /// Obsidian) leaves an empty span rather than breaking the render.
  JSObject _icon(JSObject parent, String name, {String? cls}) {
    final el = _el(
      parent,
      'span',
      cls: cls == null ? 'rh-icon' : 'rh-icon $cls',
    );
    _setIcon(el, name);
    return el;
  }

  void _setIcon(JSObject el, String name) {
    try {
      jsu.callMethod<void>(el, 'empty', []);
      jsu.callMethod<void>(obsidianModule(), 'setIcon', [el, name]);
    } catch (e) {
      _log?.debug('sync panel: setIcon($name) failed: $e');
    }
  }

  void _setText(JSObject el, String text) {
    jsu.setProperty(el, 'textContent', text);
  }

  void _setWidth(JSObject el, double frac) {
    jsu.setProperty(
      jsu.getProperty<JSObject>(el, 'style'),
      'width',
      '${(frac * 100).toStringAsFixed(1)}%',
    );
  }

  void _clearWidth(JSObject el) {
    jsu.setProperty(jsu.getProperty<JSObject>(el, 'style'), 'width', '');
  }

  /// Attribute, not property — `aria-label` has no same-named DOM property, so
  /// setting it as one would silently do nothing and Obsidian's tooltip
  /// (driven by the attribute) would never appear.
  void _attr(JSObject el, String name, String value) {
    jsu.callMethod<void>(el, 'setAttribute', [name, value]);
  }

  void _addClass(JSObject el, String cls) {
    jsu.callMethod<void>(jsu.getProperty<JSObject>(el, 'classList'), 'add', [
      cls,
    ]);
  }

  void _toggleClass(JSObject el, String cls, bool on) {
    jsu.callMethod<void>(
      jsu.getProperty<JSObject>(el, 'classList'),
      on ? 'add' : 'remove',
      [cls],
    );
  }

  void _setHidden(JSObject el, bool hidden) =>
      _toggleClass(el, 'rh-hidden', hidden);

  void _onClick(JSObject el, FutureOr<void> Function() handler) {
    jsu.callMethod<void>(el, 'addEventListener', [
      'click',
      jsu.allowInterop((JSAny? _) => handler()),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Presentation
  // ---------------------------------------------------------------------------

  /// Derives the shown status from the connection/activity/blocker flags.
  /// Priority: paused > missing precondition > hard blocker > live activity >
  /// connection state. Green ("ready") is reserved for a genuine
  /// connected-and-idle state.
  _Status _effective() {
    if (_isPaused()) return _Status.paused;
    // A missing precondition outranks everything below: the engine is not
    // merely disconnected, it was never able to run, and no amount of
    // reconnecting will change that.
    if (_currentBlock() != null) return _Status.blocked;
    switch (_blocker) {
      case _Blocker.auth:
        return _Status.authExpired;
      case _Blocker.sub:
        return _Status.subExpired;
      case _Blocker.error:
        return _Status.error;
      case _Blocker.none:
        break;
    }
    // Before the connection checks: the engine being mid-operation outranks
    // both "connecting" and "up to date", and unlike the debounce it does not
    // go quiet just because a phase reports progress sparsely.
    if (_busy || _activity) return _Status.syncing;
    if (_connected) return _hasPending ? _Status.pending : _Status.ready;
    if (_connecting || _resuming) return _Status.connecting;
    if (_everStarted) return _Status.offline;
    return _Status.stopped;
  }

  /// The host's live verdict, or null when nothing is missing. Guarded because
  /// the callback reads engine/auth state that a teardown may have dropped.
  SyncStartBlock? _currentBlock() {
    final probe = _startBlock;
    if (probe == null) return null;
    try {
      return probe();
    } catch (e) {
      _log?.warning('sync panel: start-block probe failed: $e');
      return null;
    }
  }

  String _statusLabel(_Status status) => switch (status) {
    _Status.stopped => S.syncStopped,
    _Status.blocked => switch (_currentBlock()) {
      SyncStartBlock.signedOut => S.blockedSignedOut,
      SyncStartBlock.noVault => S.blockedNoVault,
      SyncStartBlock.locked => S.blockedLocked,
      SyncStartBlock.noServer => S.blockedNoServer,
      SyncStartBlock.storageRefused => S.blockedStorageRefused,
      null => S.syncStopped,
    },
    _Status.connecting => _connectAttempt <= 2 ? S.connecting : S.reconnecting,
    _Status.offline => S.offlineCantReach,
    _Status.ready => S.upToDate,
    _Status.pending => S.pendingChanges,
    _Status.syncing =>
      _progress != null
          ? S.syncingProgress(_progress!.completed, _progress!.total)
          : S.syncingEllipsis,
    _Status.error => S.syncErrorStatus,
    _Status.authExpired => S.sessionExpiredStatus,
    _Status.subExpired => S.subscriptionRequiredStatus,
    _Status.paused => S.pausedStatus,
  };

  /// Status → panel modifier class. The actual colours live in
  /// [kSyncPanelCss] and mirror the status-bar indicator's palette.
  static String _statusClass(_Status status) => switch (status) {
    _Status.blocked => 'is-blocked',
    _Status.ready => 'is-ready',
    _Status.pending => 'is-pending',
    _Status.connecting => 'is-connecting',
    _Status.syncing => 'is-syncing',
    _Status.offline => 'is-offline',
    _Status.authExpired => 'is-auth',
    _Status.subExpired => 'is-sub',
    _Status.error => 'is-error',
    _Status.stopped => 'is-stopped',
    _Status.paused => 'is-paused',
  };

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 45) return S.justNow;
    if (d.inMinutes < 60) return S.minutesAgo(d.inMinutes);
    if (d.inHours < 24) return S.hoursAgo(d.inHours);
    return S.daysAgo(d.inDays);
  }

  static String _bytes(int n) {
    if (n < 1024) return '$n B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var v = n / 1024;
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v >= 100 || v == v.roundToDouble() ? 0 : 1)} '
        '${units[i]}';
  }
}

enum _Status {
  stopped,
  blocked,
  connecting,
  offline,
  ready,
  pending,
  syncing,
  error,
  authExpired,
  subExpired,
  paused,
}

/// Sticky sync-blocking condition, cleared when a live connection is
/// (re)established (error) or the underlying state is fixed (auth/sub).
enum _Blocker { none, error, auth, sub }

/// A precondition the engine needs before it can start AT ALL — as opposed to
/// a connection it had and lost.
///
/// The distinction matters because it decides what the panel may say. Without
/// it every one of these ended up as the same grey "sync stopped / not
/// connected", which names a symptom the user cannot act on and hides the one
/// thing they can: a plugin that is simply signed out looked identical to a
/// server outage.
///
/// Resolved live by the host (see `plugin.dart`), not latched at construction:
/// signing in or unlocking clears it without rebuilding the panel.
enum SyncStartBlock {
  /// Managed edition with no account session — the plugin is signed out.
  signedOut,

  /// Signed in (or self-host) but no remote vault is connected yet.
  noVault,

  /// A vault is configured but its key is absent: the passphrase prompt was
  /// dismissed, so nothing can be encrypted or decrypted.
  locked,

  /// The blob backend refused this device — wrong credentials, or no
  /// permission. Nothing retries its way out of it, and until someone changes
  /// the storage settings every edit is dropped, so it belongs here with the
  /// other missing preconditions rather than in an error that scrolls past.
  storageRefused,

  /// Self-host without a usable server URL/token, or a build with no account
  /// service compiled in.
  noServer,
}
