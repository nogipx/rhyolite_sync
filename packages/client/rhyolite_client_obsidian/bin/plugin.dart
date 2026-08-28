// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_client_account/rhyolite_client_account.dart'
    hide VaultInfo;
import 'package:rhyolite_client_obsidian/rhyolite_client_obsidian.dart';
import 'package:rhyolite_client_obsidian/src/engine/auth_recovery.dart';
import 'package:rhyolite_client_obsidian/src/engine/auth_session_state.dart';
import 'package:rhyolite_client_obsidian/src/engine/backup_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/build_env.dart';
import 'package:rhyolite_client_obsidian/src/engine/frontmatter_audit_binding.dart';
import 'package:rhyolite_client_obsidian/src/engine/db_recovery.dart';
import 'package:rhyolite_client_obsidian/src/engine/diagnostics_logging.dart';
import 'package:rhyolite_client_obsidian/src/engine/device_management_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/file_version_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/modal_lock.dart';
import 'package:rhyolite_client_obsidian/src/engine/orphan_sweep_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/plugin_management_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/self_host_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/server_rejections.dart';
import 'package:rhyolite_client_obsidian/src/engine/storage_cleanup_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/storage_overview_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/plan_status.dart';
import 'package:rhyolite_client_obsidian/src/engine/sync_panel.dart';
import 'package:rhyolite_client_obsidian/src/engine/sync_status_indicator.dart';
import 'package:rhyolite_client_obsidian/src/engine/vault_picker_modal.dart';
import 'package:rhyolite_client_obsidian/src/i18n/i18n.dart';
import 'package:rhyolite_client_obsidian/src/platform/obsidian_http_client.dart';
import 'package:rpc_blob_sqlite/rpc_blob_sqlite.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_compression/rpc_dart_compression.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:rpc_dart_log/rpc_dart_log.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';

// Silent baseline level: dev builds stream everything; release builds sit at
// warning. When the user enables remote diagnostics, [DiagnosticsLogging] drops
// the level to debug and restores this on disable.
const _baselineLogLevel = kDebug ? RpcLogLevel.debug : RpcLogLevel.warning;

// Release builds start with NO outputs — nothing is written anywhere until the
// user explicitly enables remote diagnostics (see [DiagnosticsLogging]). Dev
// builds (RHYOLITE_DEBUG=true) keep the console for local debugging.
final _logController = LogController(
  outputs: kDebug ? [ConsoleOutput()] : [],
  minLevel: _baselineLogLevel,
);
final _log = _logController.scope('plugin');

/// Manages the optional remote log sink. Off until the user opts in; installed
/// during boot from the persisted [DiagnosticsPrefs] and re-applied live from
/// the settings tab.
DiagnosticsLogging? _diagnostics;

ISyncEngine? _engine;
DatabaseConnection? _dbConn;
SyncStatusIndicator? _syncIndicator;
SyncPanel? _syncPanel;

/// User-requested sync pause (toggled from the side panel, persisted in
/// data.json). When true, every incidental start path is skipped — sync stays
/// off until an explicit resume (the "Start Sync" command or the panel's Resume
/// button), which is the only thing that clears it.
bool _syncPaused = false;

/// Starts the engine unless the user paused sync. ALL non-explicit start paths
/// (boot, reconnect, token refresh, config/vault change, subscription) route
/// through this so a persisted pause is honoured everywhere — otherwise the
/// flag desyncs from reality (engine running while "paused"). The pause flag is
/// cleared only by an explicit resume (`setSyncPaused(false)` in boot).
Future<void> _guardedStart(ISyncEngine engine, [TaskCancelToken? token]) async {
  if (_syncPaused) {
    _log.info('Engine start skipped — sync paused by user.');
    return;
  }
  await engine.start(token: token);
}

/// Short, user-facing reason for a [SyncStartBlock] — the middle of the boot
/// notice. The panel spells the same condition out at length; this only has to
/// be enough to tell an outage apart from a plugin waiting on the user.
String _startBlockReason(SyncStartBlock block) => switch (block) {
  SyncStartBlock.signedOut => S.blockedSignedOut,
  SyncStartBlock.noVault => S.blockedNoVault,
  SyncStartBlock.locked => S.blockedLocked,
  SyncStartBlock.noServer => S.blockedNoServer,
};

/// Best-effort OS label for [DeviceInfo] on the log collector: `desktop`, or
/// `iOS`/`Android` sniffed from the user agent on mobile (Obsidian doesn't
/// expose the OS directly). The bug this diagnostics feature exists to debug is
/// iOS-specific, so telling iPhone from Android in the collector matters.
String _diagnosticsOs(bool isMobile) {
  if (!isMobile) return 'desktop';
  try {
    final nav = jsu.getProperty<JSObject?>(jsu.globalThis, 'navigator');
    final ua = nav != null
        ? (jsu.getProperty<String?>(nav, 'userAgent') ?? '')
        : '';
    return ua.contains('Android') ? 'Android' : 'iOS';
  } catch (_) {
    return 'mobile';
  }
}

/// Fetches managed-storage usage over the sync connection. Returns null on
/// self-host / BYO (no managed quota, responder absent) or before connect.
Future<({int usedBytes, int quotaBytes})?> _fetchVaultUsage(
  ISyncEngine engine,
  String vaultId,
) async {
  if (engine is! StateSyncEngine || vaultId.isEmpty) return null;
  final ep = engine.endpoint;
  if (ep == null) return null;
  try {
    final res = await VaultUsageContractCaller(
      ep,
    ).getVaultUsage(GetVaultUsageRequest(vaultId: vaultId));
    return (usedBytes: res.usedBytes, quotaBytes: res.quotaBytes);
  } catch (e) {
    _log.warning('vault usage fetch failed: $e');
    return null;
  }
}

ObsidianConfigSync? _configSync;
StreamSubscription<SyncEngineEvent>? _configReconnectSub;

/// The auth/recovery event listener (session-expiry re-auth, blob-config
/// adopt, token refresh). Held so onUnload can cancel it — without this a
/// soft reload (unload + re-onload) leaks one listener bound to the prior
/// engine's event stream each cycle.
StreamSubscription<SyncEngineEvent>? _engineAuthEventsSub;

/// Watches for the connected vault being permanently deleted on another device
/// (its registry entry comes back tombstoned). Cancelled on unload like the
/// others to avoid leaking a listener across soft reloads.
StreamSubscription<SyncEngineEvent>? _deletedVaultWatchSub;
StreamSubscription<SyncEngineEvent>? _stateLostSub;
StreamSubscription<SyncEngineEvent>? _flushSub;
Timer? _flushDebounce;

/// Drives the offline self-heal: watches connection events to arm/cancel the
/// periodic recovery timer. Held so onUnload can cancel it.
StreamSubscription<SyncEngineEvent>? _selfHealSub;

/// Periodic self-heal timer. Armed when the engine reports it lost the backend
/// (SyncDisconnected) and rpc_dart's own reconnect loop gave up; cancelled on
/// SyncConnected. Drives recovery on a capped backoff so getting back online no
/// longer depends on a DOM online/visibility event firing — those never fire
/// when the OS network stayed up but the server/token dropped.
Timer? _selfHealTimer;
int _selfHealAttempt = 0;

/// Debounce for the auth-rejection -> token-refresh path. A burst of auth.*
/// rejections (every pending RPC failing at once) must not spawn a refresh
/// grind loop — refresh at most once per cooldown, one in flight at a time.
bool _authRefreshInFlight = false;
DateTime? _lastAuthRefreshAt;

/// Consecutive "rebind the live session and restart" recoveries. Bounded so a
/// rebind that does not actually fix the rejection can't restart the engine on
/// every cooldown; past the cap the handler falls through to refresh/prompt.
/// Reset on the next successful connect.
int _authRebindAttempts = 0;
const int _kMaxAuthRebinds = 3;

/// Stops the offline self-heal loop and resets its backoff. Called on connect,
/// on pause and on unload.
void _cancelSelfHeal() {
  _selfHealTimer?.cancel();
  _selfHealTimer = null;
  _selfHealAttempt = 0;
}

/// Latest known plan (managed edition), as the server last described it.
/// Loaded from `data.json` at boot, refreshed by every getSubscription.
PlanSnapshot? _plan;

/// The plan the previous session ended on, kept for the whole session.
///
/// The account service reports a lapsed subscription as `none` with free
/// capabilities — the same answer it gives someone who never paid. Comparing
/// against what we remembered is the only way to tell those apart, so the
/// remembered value must survive being overwritten by the fresh one.
PlanSnapshot? _rememberedPlan;

/// Plan capabilities, or null when no answer has ever been obtained. The engine
/// reads `maxFileSizeBytes` from this for the per-file size gate.
PlanCapabilities? get _capabilities => _plan?.capabilities;

/// Records a fresh plan and remembers it for the next session.
///
/// Every consumer treats null as "no answer", and the only way to get one is a
/// network call made while a sync session starts — so it fails at exactly the
/// times sessions are hardest to start. Persisting the last real answer turns
/// a failed lookup into "what the server said last time", which is right far
/// more often than "nothing is allowed".
Future<void> _rememberPlan(
  SubscriptionDto? dto,
  ObsidianConfigStorage storage,
) async {
  if (dto == null) return;
  final next = resolvePlan(prior: _plan ?? _rememberedPlan, fresh: dto);
  if (_plan == next) return;
  _plan = next;
  try {
    await storage.savePlan(next);
  } catch (e) {
    _log.debug('plan cache write failed: $e');
  }
}

/// What the panel and settings currently say about the plan, if anything.
PlanNotice _planAlert = PlanNotice.quiet;

/// Recomputes the plan alert and pushes it everywhere that shows it.
///
/// Called after every subscription lookup rather than on a timer: the alert
/// only changes when the answer does, or when a date passes — and a date that
/// passes mid-session is caught by the next session's lookup, which is soon
/// enough for something measured in days.
void _refreshPlanNotice() {
  // Self-host has no account, no plan and nothing to renew.
  final next = _selfHostActive
      ? PlanNotice.quiet
      : planNotice(
          remembered: _rememberedPlan,
          current: _plan,
          now: DateTime.now(),
        );
  if (next == _planAlert) return;
  _planAlert = next;
  _syncPanel?.setPlanNotice(next);
  if (!next.isQuiet) _announcePlanOnce(next);
}

/// The period a plan notice has already been announced for, so the one-off
/// notice is one-off. Keyed on the date itself: renewing moves the date, which
/// re-arms the announcement for the new period without any bookkeeping.
String? _announcedPlanPeriod;

/// Shows the plan alert once, as a notice with a way to act on it.
///
/// The panel strip is what persists; this exists because the panel may well be
/// closed, and an alert nobody is looking at explains nothing. One per period,
/// never per start.
void _announcePlanOnce(PlanNotice notice) {
  final key = '${notice.alert.name}:${notice.date?.toIso8601String() ?? "-"}';
  if (_announcedPlanPeriod == key) return;
  _announcedPlanPeriod = key;
  final date = notice.date == null ? null : formatPlanDay(notice.date!);
  final message = switch (notice.alert) {
    PlanAlert.ended =>
      date == null ? S.planEndedNoDate : S.planEndedOn(date),
    PlanAlert.endingSoon => S.planEndingOn(date ?? ''),
    PlanAlert.none => '',
  };
  if (message.isEmpty) return;
  _noticeWithButton(
    message,
    buttonText: S.planRenew,
    onClick: _openSubscriptionPage,
  );
}

void _openSubscriptionPage() {
  if (kEnv.siteUrl.isEmpty) return;
  _openExternalUrl('${kEnv.siteUrl}/account');
}


/// Whether this session talks to a self-hosted server. Held here because the
/// settings-sync launcher runs from several call sites that no longer have the
/// boot block's locals in scope, and the plugin-code storage gate needs it.
bool _selfHostActive = false;

/// Bytes the community plugins installed on THIS device occupy, measured on
/// each settings-sync launch. Shown in the settings row so enabling plugin-code
/// sync is a decision made with the number in hand. Null until first measured.
int? _pluginCodeLocalBytes;

/// The vault's plugin set joined with this device's disk, or empty when
/// plugin-code sync is off / settings sync isn't running.
Future<PluginCodeOverview> _pluginOverview() async {
  try {
    return await _configSync?.pluginOverview() ?? PluginCodeOverview.empty;
  } catch (e) {
    _log.warning('plugin overview failed: $e');
    return PluginCodeOverview.empty;
  }
}

/// Opens the storage overview. Single definition so the sync panel, the
/// command palette and the settings tab all show the same thing.
Future<void> _showStorageOverview(
  PluginHandle plugin,
  ISyncEngine engine, {
  Future<({int usedBytes, int quotaBytes})?> Function()? fetchUsage,
}) async {
  ({int usedBytes, int quotaBytes})? usage;
  try {
    usage = await fetchUsage?.call();
  } catch (_) {
    // No managed quota (self-host / BYO) or the lookup failed: the rest of the
    // overview is still worth showing.
  }
  await showStorageOverviewModal(
    plugin,
    engine,
    plugins: await _pluginOverview(),
    usage: usage,
    onManagePlugins: () => _showPluginManagement(plugin),
  );
}

/// Opens plugin management, where a plugin can be dropped from the vault for
/// every device at once.
Future<void> _showPluginManagement(PluginHandle plugin) => showPluginManagementModal(
      plugin,
      load: _pluginOverview,
      onRemove: (resourceId) async =>
          await _configSync?.removeFromVault(resourceId) ?? false,
    );

/// Obsidian's own mobile flag. Desktop-only plugins are not materialized here.
bool _isMobileApp(PluginHandle plugin) {
  try {
    return jsu.getProperty<bool?>(plugin.app.raw, 'isMobile') ?? false;
  } catch (_) {
    return false;
  }
}

/// Plugin-owned task lane. Created in onLoad, injected into the engine so the
/// engine's steady-state sync work (reconcile/pull/GC/settings) and the
/// plugin's lifecycle work (boot/restart) share one serialized,
/// connection-fair scheduler instead of racing the single WebSocket. Outlives
/// every engine session; disposed on unload. See [[engine_sync_scheduler_plan]].
PriorityTaskScheduler? _scheduler;

/// Priority for lifecycle (boot/restart) tasks. Above the engine's interactive
/// lane (100) so a restart is never blocked by the user-active typing gate.
const int _kBootPriority = 1000;

/// Priority for lifecycle work the plugin decided to do on its own — the
/// health-check restart, the offline self-heal. Below [_kBootPriority] and
/// preemptible, so a start the USER asked for is not queued behind one of
/// these. It used to be: a restart wedged on a dead transport held the single
/// lane until its own 60s RPC timeout, and Resume sat behind it doing nothing
/// visible. Above the engine's interactive lane (100) either way.
const int _kRecoveryPriority = 500;

/// Runs [body] as the single coalesced `engine-lifecycle` task, so the restart
/// triggers (initial start, Start command, resume health-check, blob-config
/// adopt, token refresh) can't overlap or interleave their `engine.start()` —
/// the latest supersedes a still-pending one, and a running one is never
/// re-entered. Settings relaunch is deliberately NOT wrapped: it routes through
/// engine.scheduleBackground (lower priority) and awaiting it from inside this
/// task would deadlock the single slot, so callers relaunch settings AFTER
/// awaiting this. Runs [body] directly if the scheduler is gone (unloaded).
/// [automatic] marks work the plugin started by itself: it runs at
/// [_kRecoveryPriority] and yields its token when a user-initiated boot
/// arrives, so the engine can abandon a start nobody is waiting for any more.
Future<void> _scheduleBoot(
  Future<void> Function(TaskCancelToken token) body, {
  bool automatic = false,
}) {
  final scheduler = _scheduler;
  if (scheduler == null) return body(TaskCancelController().token);
  return scheduler.schedule(
    key: 'engine-lifecycle',
    priority: automatic ? _kRecoveryPriority : _kBootPriority,
    preemptible: automatic,
    run: body,
  );
}

/// Copies the engine's device identity into data.json the first time.
///
/// Only ever writes when nothing is stored yet, and writes what the sync
/// database already carries — so an existing install keeps the head it has
/// been using instead of registering a second one. After this, the id comes
/// from data.json and outlives the database.
Future<void> _adoptDeviceId(
  ISyncEngine engine,
  ObsidianConfigStorage configStorage,
) async {
  try {
    final vaultId = engine.config.vaultId;
    if (vaultId.isEmpty) return;
    if (await configStorage.loadDeviceId(vaultId) != null) return;
    final deviceId = engine is StateSyncEngine ? engine.deviceId : null;
    if (deviceId == null || deviceId.isEmpty) return;
    await configStorage.saveDeviceId(vaultId, deviceId);
    _log.info('Adopted device id for vault $vaultId');
  } catch (e) {
    // Losing this only means the id is re-adopted on the next start.
    _log.warning('Device id adoption failed: $e');
  }
}

/// (Re)starts `.obsidian` settings sync. Idempotent — disposes any running
/// instance first. No-op when disabled, before the engine has an endpoint, or
/// before a vault key is available. The config caller reuses the engine's live
/// connection via a distinct service name.
/// Debounce for the "settings changed — reload" prompt: a burst of synced
/// resources coalesces into a single notice.
Timer? _settingsReloadDebounce;

void _scheduleSettingsReloadNotice(PluginHandle plugin) {
  _settingsReloadDebounce?.cancel();
  _settingsReloadDebounce = Timer(const Duration(seconds: 3), () {
    _showReloadNotice(
      plugin,
      'Settings synced from another device. Reload to apply them.',
    );
  });
}

/// Persistent notice with a clickable "Reload" that runs Obsidian's reload
/// command. Falls back to a plain notice if the DOM/command wiring is
/// unavailable (e.g. mobile has no app:reload).
/// A notice that stays until dismissed and carries one button.
///
/// Obsidian's own Notice has no such affordance, so the button is appended to
/// its element. Any failure in that interop falls back to a plain notice —
/// losing the button is acceptable, losing the message is not.
void _noticeWithButton(
  String message, {
  required String buttonText,
  required void Function() onClick,
}) {
  try {
    final obsidian = jsu.callMethod<Object?>(jsu.globalThis, 'require', [
      'obsidian',
    ]);
    final noticeCtor = jsu.getProperty<Object?>(obsidian!, 'Notice');
    // timeout 0 = stays until dismissed or the app reloads.
    final notice = jsu.callConstructor<Object?>(noticeCtor!, [message, 0])!;
    final el = jsu.getProperty<Object?>(notice, 'noticeEl');
    if (el == null) return;
    final btn = jsu.callMethod<Object?>(el, 'createEl', [
      'button',
      jsu.jsify({'text': ' $buttonText', 'cls': 'mod-cta'}),
    ])!;
    jsu.setProperty(btn, 'style', 'margin-left: 8px;');
    jsu.callMethod<void>(btn, 'addEventListener', [
      'click',
      jsu.allowInterop((_) {
        onClick();
        jsu.callMethod<void>(notice, 'hide', []);
      }),
    ]);
  } catch (_) {
    showNotice(message);
  }
}

void _showReloadNotice(PluginHandle plugin, String message) => _noticeWithButton(
      message,
      buttonText: 'Reload',
      onClick: () {
        final commands = jsu.getProperty<Object?>(plugin.app.raw, 'commands');
        if (commands != null) {
          jsu.callMethod<void>(commands, 'executeCommandById', ['app:reload']);
        }
      },
    );

Future<void> _launchConfigSync({
  required ISyncEngine engine,
  required IDataClient dataClient,
  required IVaultCipher cipher,
  required String vaultId,
  required PluginHandle plugin,
  required SettingsSyncPrefs prefs,
}) async {
  _stopConfigSync();
  if (!prefs.enabled || engine is! StateSyncEngine) return;
  final endpoint = engine.endpoint;
  if (endpoint == null) return;

  final caller = StateSyncContractCaller(
    endpoint,
    serviceNameOverride: StateSyncContractNames.instance('config'),
  );
  // Plugin *code* is the one category whose bytes are measured in hundreds of
  // megabytes, so it is gated on the storage backing this vault as well as on
  // the user's own toggle.
  //
  // The gate suppresses UPLOADS and nothing else. It used to drop the category
  // from the set below, which is also the sync scope — so a `getSubscription`
  // that merely timed out (`unknownQuota`) purged every plugin record from the
  // local store and reset the pull cursor, and the next successful lookup paid
  // for it with a full re-download of the plugin set. Availability is a
  // statement about spending managed storage; it must not be able to rewrite
  // what this device is subscribed to.
  final gate = pluginCodeAvailability(
    selfHost: _selfHostActive,
    externalStorage: engine.config.externalStorageKind != null,
    managedStorageQuotaBytes: _capabilities?.managedStorageQuotaBytes,
  );
  final categories = prefs.categories;
  final pluginCodeWanted = categories.contains(
    SettingsCategory.communityPluginCode,
  );
  final pullOnly = pluginCodePullOnly(
    enabled: categories,
    availability: gate,
  );
  if (pullOnly.isNotEmpty) {
    _log.info('Plugin code upload paused: ${gate.name} '
        '(existing plugin records still sync down)');
  }

  final pluginCode = BlobDirSync(
    adapter: plugin.app.vault.adapter,
    // Rebuilt per call: the engine swaps remote storage on reconnect and on a
    // BYO-credentials change.
    blobIO: () => engine.newSiblingBlobIO(
      maxDownloadBytes: BlobDirSync.maxFileBytes,
    ),
    isMobile: _isMobileApp(plugin),
    deviceLabel: engine.config.clientName,
    pluginsManagerRaw: jsu.getProperty<Object?>(plugin.appRaw, 'plugins'),
    // Surfaces plugin/theme transfers in the panel's active-transfers view,
    // the same place note content appears. A first sync moves tens of
    // megabytes; without this it is minutes of silence.
    onTransfer: ({
      required String path,
      required bool upload,
      required int sentBytes,
      required int totalBytes,
      required bool done,
    }) =>
        engine.reportSiblingTransfer(
      path: path,
      upload: upload,
      sentBytes: sentBytes,
      totalBytes: totalBytes,
      done: done,
    ),
    log: _log.info,
  );
  // Measure what plugins weigh here even when the category is off — that number
  // is exactly what the settings row shows to make the opt-in an informed one.
  // Stat-only, so it costs nothing to keep current.
  unawaited(
    pluginCode.localTotalBytes(SyncedDirKind.plugin).then((bytes) {
      _pluginCodeLocalBytes = bytes;
    }).catchError((Object _) {}),
  );

  final sync = SettingsSync(
    remote: caller,
    store: SettingsStore(client: dataClient, vaultId: vaultId),
    cipher: cipher,
    vaultId: vaultId,
    kindOf: ObsidianSettingsRegistry.kindOf(categories),
    // Which categories are on IS the scope: a pull drops records for a category
    // that is off, so the cursor it leaves behind is only valid while the set
    // stays the same. Sorted so the token depends on membership, not order.
    //
    // `categories` is the user's own toggle set, never the storage gate — see
    // the gate comment above. A token that a failed network call can flip makes
    // the cursor worthless.
    scope: (categories.map((c) => c.name).toList()..sort()).join(','),
    log: _log.info,
  );
  final cs = ObsidianConfigSync(
    adapter: plugin.app.vault.adapter,
    sync: sync,
    enabledCategories: categories,
    // The storage gate, expressed where it belongs: no capture, no removal
    // detection, everything else untouched.
    pullOnlyCategories: pullOnly,
    // Needed by BOTH blob-backed categories. Themes are on by default while
    // plugin code is opt-in, so gating this on plugin code alone would have
    // silently stopped themes from syncing at all. Keyed on what the user
    // enabled, not on the gate: a pull-only category still has to be able to
    // write what it receives to disk.
    pluginCode: (pluginCodeWanted ||
            categories.contains(SettingsCategory.themesSnippets))
        ? pluginCode
        : null,
    // Reclaim the replaced plugin version's storage right after the push,
    // instead of leaving it for whenever the user happens to run a sweep.
    // The server decides what is actually dead; we only nominate.
    releaseBlobs: engine.releaseBlobs,
    // Event-driven remote->local: react to another device's settings push on
    // the config keyspace topic (same vault qualification the server uses).
    notifyEndpoint: endpoint,
    notifyTopic: 'vault:${vaultId}_config',
    onActivity: (active) => _syncIndicator?.setSettingsActivity(active),
    // Obsidian doesn't hot-apply config files from disk, so a settings change
    // synced from another device lands on disk but isn't live until a reload.
    // Prompt one (debounced, one notice per burst).
    onRemoteApplied: () => _scheduleSettingsReloadNotice(plugin),
    log: _log.info,
    // Share the note engine's connection-fair scheduler: settings sync runs
    // as low-priority background work that yields to interactive note sync
    // and pauses while the user is actively editing.
    runBackground: engine.scheduleBackground,
  );
  _configSync = cs;
  try {
    await cs.start();
    _log.info('Settings sync started (${prefs.categories.length} categories)');
    // The blob GC ran (and refused) before this existed — its live set was
    // incomplete without us. Now that we can answer, let it try again.
    engine.rescheduleLocalBlobGc();
  } catch (e, st) {
    _log.error('Settings sync start failed', error: e, stackTrace: st);
  }
}

void _stopConfigSync() {
  _configSync?.dispose();
  _configSync = null;
}

/// Updates the engine's reference to the auth-backed vault meta storage.
///
/// `metaStorage` is set once at engine construction; without this helper a
/// post-construction sign-in (session-expired refresh, manual re-auth,
/// onAuthChanged callback) would leave the engine with a stale null
/// `metaStorage` and `_checkExternalBlobConfig` would silently never
/// load the server-side external blob config.
void _setEngineAuth(ISyncEngine engine, AuthSessionState auth) {
  if (engine is! StateSyncEngine) return;
  engine.metaStorage = auth.metaStorage;
}

/// Opens [url] in the user's real system browser, not Obsidian's in-app Web
/// Viewer. Browser-auth depends on this: the site's `obsidian://rhyolite-auth`
/// callback only reaches the protocol handler when login happens in the
/// external browser — inside the in-app WebView the redirect is swallowed and
/// Electron throws a detached-webview error ("getWebContentsId"). Uses
/// Electron's `shell.openExternal` on desktop, falling back to `window.open`
/// on mobile (no Electron), where that already opens the system browser.
void _openExternalUrl(String url) {
  try {
    final electron = jsu.callMethod<Object?>(jsu.globalThis, 'require', [
      'electron',
    ]);
    if (electron != null) {
      final shell = jsu.getProperty<Object?>(electron, 'shell');
      if (shell != null) {
        jsu.callMethod<void>(shell, 'openExternal', [url]);
        return;
      }
    }
  } catch (_) {
    // No Electron (mobile) or require unavailable — fall through.
  }
  jsu.callMethod<void>(jsu.globalThis, 'open', [url]);
}

/// Returns true if [error] indicates a corrupted or incompatible SQLite database.
bool _isSqliteCorrupt(Object error) {
  final msg = error.toString();
  // SqliteException(11) — SQLITE_CORRUPT
  if (msg.contains('SqliteException(11)') ||
      (msg.contains('SqliteException') && msg.contains('malformed'))) {
    return true;
  }
  // IndexedDB VFS failures — stale or incompatible DB layout:
  // 1. Chunk shorter than expected → negative typed array length.
  if (msg.contains('Invalid typed array length') && msg.contains('-')) {
    return true;
  }
  // 2. IDB cursor key is null when a number is expected (missing chunk).
  if (msg.contains('JSNull') && msg.contains('double')) {
    return true;
  }
  return false;
}

/// Returns a URI for the sqlite3mc wasm module.
/// The wasm is inlined as base64 in main.js by the build script — decoded here
/// and wrapped in a Blob URL so no separate file is needed.
Uri _resolveWasmUri() {
  final b64 =
      jsu.getProperty<String?>(jsu.globalThis, '__rhyoliteWasmB64') ?? '';
  final bytes = base64Decode(b64);
  final jsBytes = jsu.jsify(bytes);
  final blobConstructor = jsu.getProperty<Object>(jsu.globalThis, 'Blob');
  final blob = jsu.callConstructor<Object>(blobConstructor, [
    [jsBytes],
    jsu.jsify({'type': 'application/wasm'}),
  ]);
  final url = jsu.callMethod<String>(
    jsu.getProperty<Object>(jsu.globalThis, 'URL'),
    'createObjectURL',
    [blob],
  );
  return Uri.parse(url);
}

/// Drains the database's pending writes to durable storage.
///
/// The IndexedDB VFS acknowledges a write and performs it afterwards from a
/// queue, so between the two the database has told us "committed" about bytes
/// that exist only in RAM. Android kills backgrounded WebView apps routinely
/// and without a clean unload, which is precisely the window: state rolls back
/// to the last drained write, and sync then re-downloads the vault and undoes
/// deletes whose records never landed.
///
/// [immediate] skips the debounce — used when the host is about to be
/// suspended and there may be no later chance.
Future<void> _flushDb({bool immediate = false}) async {
  final conn = _dbConn;
  if (conn == null) return;
  if (immediate) {
    _flushDebounce?.cancel();
    _flushDebounce = null;
    try {
      await conn.flush();
    } catch (e) {
      _log.warning('db flush failed: $e');
    }
    return;
  }
  // Coalesce: a sync burst emits many convergence points, and each flush only
  // waits for work queued before it — flushing per event would serialise the
  // write queue for no added durability.
  if (_flushDebounce != null) return;
  _flushDebounce = Timer(const Duration(seconds: 3), () {
    _flushDebounce = null;
    unawaited(_flushDb(immediate: true));
  });
}

/// Asks the browser to make this origin's storage persistent.
///
/// The plugin's whole durable state is one SQLite file in OPFS (IndexedDB
/// fallback). A default storage bucket is *best-effort*: the OS may evict it
/// when the app has not been used for a while or when the device is short on
/// space — and the plugin then boots with an empty database, pulls from cursor
/// 0 and re-downloads every blob. A granted bucket is exempt from that.
///
/// Best-effort in every direction. The API is absent on old WebViews, the
/// grant can be refused without explanation, and neither case is worth
/// blocking a boot over — hence the timeout and the swallowed errors. The
/// outcome is logged because it is the first thing to check when a device
/// keeps losing its database.
Future<void> _requestPersistentStorage() async {
  Future<Object?> call(Object storage, String method) => jsu
      .promiseToFuture<Object?>(
        jsu.callMethod<Object>(storage, method, const []),
      )
      .timeout(const Duration(seconds: 3), onTimeout: () => null);

  try {
    final navigator = jsu.getProperty<Object?>(jsu.globalThis, 'navigator');
    if (navigator == null) return;
    final storage = jsu.getProperty<Object?>(navigator, 'storage');
    if (storage == null || !jsu.hasProperty(storage, 'persist')) {
      _log.warning('boot: storage.persist() unavailable — storage is evictable');
      return;
    }
    if (jsu.hasProperty(storage, 'persisted') &&
        await call(storage, 'persisted') == true) {
      _log.info('boot: storage already persistent');
      return;
    }
    final granted = await call(storage, 'persist');
    if (granted == true) {
      _log.info('boot: persistent storage granted');
    } else {
      _log.warning(
        'boot: persistent storage NOT granted ($granted) — the OS may evict '
        'the sync database while Obsidian is unused',
      );
    }
  } catch (e) {
    _log.warning('boot: persistent storage request failed: $e');
  }
}

void main() {
  RpcGzipCodec.register();
  bootstrapPlugin(
    extraCss: '''
      .rhyolite-setting-desc { color: var(--text-muted); font-size: 0.85em; }
      .rhyolite-group-note {
        color: var(--text-muted); font-size: 0.85em;
        margin: -0.5em 0 0.75em 0;
      }
      .rhyolite-vault-label { font-weight: 500; }
$kSyncPanelCss
''',
    onLoad: (plugin) async {
      // Pick UI strings from Obsidian's language before any UI is built.
      initLocale();

      // Before the first await, always. Obsidian restores the workspace layout
      // once the plugin-load phase is done, and a leaf whose view type isn't
      // registered by then is replaced with "this plugin no longer exists" for
      // the rest of the session. Everything the panel actually displays is
      // bound later (see SyncPanel.register); this only claims the type.
      registerSyncPanelView(plugin, logger: _logController.scope('plugin'));

      String dbFileName = '';
      String dbName = '';
      bool handlingCorruption = false;

      void onCorruptDb() {
        if (handlingCorruption) return;
        handlingCorruption = true;
        () async {
          try {
            await _engine?.stop();
            await _dbConn?.close();
            _engine = null;
            _dbConn = null;
          } catch (_) {}
          await showDbCorruptionModal(
            plugin,
            dbFileName: dbFileName,
            dbName: dbName,
          );
          handlingCorruption = false;
        }();
      }

      await runZonedGuarded(
        () async {
          final configStorage = ObsidianConfigStorage(plugin);

          // Before anything that reads the plan. The size gate and the
          // plugin-code storage gate both run during boot, and both would
          // otherwise spend the whole session on "no answer" whenever the
          // subscription lookup below is slow or fails.
          _plan = await configStorage.loadPlan();
          // Held apart from _plan, which the first successful lookup
          // overwrites. A lapse is only visible as the difference between the
          // two, so this side of the comparison has to outlive the refresh.
          _rememberedPlan = _plan;

          // -----------------------------------------------------------------------
          // Self-host mode: point the plugin at a self-hosted sync server with a
          // static bearer token, bypassing the managed account service entirely.
          // -----------------------------------------------------------------------
          final selfHost = await configStorage.loadSelfHost();
          final selfHostToken = selfHost.enabled
              ? (await configStorage.loadSelfHostToken() ?? '')
              : '';
          final selfHostActive =
              selfHost.enabled &&
              selfHost.syncUrl.isNotEmpty &&
              selfHostToken.isNotEmpty;
          _selfHostActive = selfHostActive;

          // From the remembered plan alone, before any lookup. A paused vault
          // never reaches startSyncSession and an offline one gets nothing back
          // from it, and both are cases where a lapse that was already recorded
          // still needs saying — a period ends on its date regardless.
          _refreshPlanNotice();

          // Server URL: self-host overrides the compile-time managed sync URL.
          final syncServerUrl = selfHostActive
              ? selfHost.syncUrl
              : kEnv.syncServiceUrl;

          // Session bindings (token provider, vault directory, meta store) for
          // whichever edition is active. ONE instance, read back through
          // `auth.*` everywhere — never copied into a local, or a later
          // sign-in updates one copy and the rest of the plugin keeps acting
          // signed out. See [AuthSessionState].
          final auth = AuthSessionState(selfHost: selfHostActive);
          WebSocketSyncConnection? registryConn; // self-host: kept alive

          // -----------------------------------------------------------------------
          // Auth — account service URL comes from compile-time dart-define only.
          // -----------------------------------------------------------------------
          final authConfig = AuthConfig(
            accountServiceUrl: kEnv.accountServiceUrl,
          );

          final accountTransport = RpcHttpCallerTransport(
            baseUrl: authConfig.accountServiceUrl,
          );
          final accountEndpoint = RpcCallerEndpoint(
            transport: accountTransport,
          );
          final accountClient = RpcAccountClient(accountEndpoint);
          // Persist every server-issued session (sign-in + every background
          // refresh). The server rotates the refresh token on each refresh, so
          // without this the on-disk token goes stale within ~15 min and the
          // next cold start is forced to re-login with a revoked token.
          accountClient.onSessionPersist = configStorage.saveAuthSession;

          // Boot-time session restore. The result is handed to `auth` below —
          // this local exists only for the length of that restore.
          RpcAccountClient? restoredClient;

          if (!selfHostActive && authConfig.isConfigured) {
            final savedSession = await configStorage.loadAuthSession();
            if (savedSession != null) {
              if (!savedSession.isExpired) {
                accountClient.useSession(savedSession);
                restoredClient = accountClient;
              } else {
                // Access token expired (they live 15 minutes, so this is the
                // normal cold-start path) — refresh it.
                try {
                  accountClient.useSession(savedSession);
                  // Bounded: onLoad must never hang on the network. A timeout
                  // is not a verdict, and the catch below treats every
                  // non-refusal as inconclusive — the session is kept and the
                  // token provider refreshes again on first use. Without this
                  // an unreachable account service held the whole plugin load
                  // open for the HTTP stack's own timeout.
                  await accountClient.refreshSession().timeout(
                    const Duration(seconds: 8),
                  );
                  final newSession = accountClient.session;
                  if (newSession != null) {
                    await configStorage.saveAuthSession(newSession);
                  }
                  restoredClient = accountClient;
                } catch (e) {
                  // Only a refusal the server actually issued discards the
                  // session. Matching on '(401)' used to stand in for that,
                  // and never matched anything: the transport reports
                  // `HTTP 401 from <path>` and an RPC-level refusal arrives
                  // as `unauthenticated: ...`.
                  if (classifyRefreshFailure(e) == RefreshOutcome.refused) {
                    _log.warning('Stored session refused by the server — '
                        'cleared: $e');
                    await configStorage.clearAuthSession();
                  } else {
                    // Offline at boot, or an answer we never got. Keep the
                    // session: the provider refreshes again on first use, and
                    // on a timeout the very same refresh is still in flight —
                    // `ensureValidToken` joins it rather than starting a second
                    // one against a single-use token.
                    //
                    // Deliberately NOT re-applying `savedSession` here. It was
                    // already applied above, before the attempt, so the only
                    // thing a second `useSession` can do is overwrite a NEWER
                    // session that the in-flight refresh has meanwhile stored —
                    // leaving the client holding a refresh token the server has
                    // already revoked, i.e. a forced logout on the next call.
                    _log.warning('Boot refresh inconclusive — keeping the '
                        'stored session: $e');
                    restoredClient = accountClient;
                  }
                }
              }
            }
          }

          // Bind the vault directory + engine auth to the active edition.
          if (selfHostActive) {
            auth.bindSelfHostToken(selfHostToken);
            registryConn = WebSocketSyncConnection(
              serverUrl: syncServerUrl,
              tokenProvider: auth.tokenProvider,
              logger: _logController.scope('registry'),
            );
            try {
              // Bounded: onLoad must never hang on a stalled connect, or the
              // rest of onLoad (settings tab, commands, engine) never runs and
              // the settings page shows up blank.
              await registryConn.connect().timeout(const Duration(seconds: 10));
              final regCaller = VaultRegistryContractCaller(
                registryConn.endpoint,
              );
              auth.bindSelfHostRegistry(
                directory: SelfHostVaultDirectory(regCaller),
                metaStorage: SelfHostVaultMetaStorage(regCaller),
              );
            } catch (e) {
              _log.warning('Self-host registry connect failed: $e');
            }
          } else {
            auth.bindAccount(restoredClient);
          }

          // -----------------------------------------------------------------------
          // Vault
          // -----------------------------------------------------------------------
          var config = await configStorage.tryLoad();
          // One-time migration: older installs stored the BYO storage secret
          // (S3/WebDAV keys) in cleartext in data.json. VaultConfig.toJson no
          // longer serialises it, so re-saving strips the cleartext; the secret
          // is re-fetched from the E2EE server config each session, and only
          // the non-secret kind marker (derived in fromJson) is persisted.
          if (config != null && config.externalBlobConfig != null) {
            await configStorage.save(config);
            _log.info('Migrated external storage credentials out of data.json');
          }
          VaultCipher? cipher;

          // Boot never blocks on the user.
          //
          // The vault picker and the passphrase prompt used to run right here,
          // and Obsidian awaits `onload`: while either modal waited for a click
          // NOTHING else in this plugin got registered — no panel view, no
          // settings tab, no commands. A sidebar leaf restored from the last
          // session then found no such view type and fell back to Obsidian's
          // "plugin no longer active" placeholder, and the settings tab was
          // simply absent.
          //
          // Only the silent path survives: a key the local store already holds.
          // Both interactive paths are now named panel states with a button
          // behind them ([SyncStartBlock.noVault], [SyncStartBlock.locked]),
          // which the user opens when they choose to rather than being
          // ambushed by a modal while Obsidian is still starting.
          final booted = config;
          final bootedToken = booted?.verificationToken;
          if (booted != null && bootedToken != null && bootedToken.isNotEmpty) {
            cipher = await configStorage.tryUnlockFromStorage(
              booted.vaultId,
              bootedToken,
            );
          }

          final cfg = config ?? const VaultConfig(vaultId: '', vaultName: '');

          // Identity for THIS vault, kept in data.json so it survives every
          // event that recreates the sync database. Null on the very first run
          // (or for an install predating this): the engine then keeps whatever
          // the database already holds, and it is adopted right after start —
          // so an existing install keeps its head instead of gaining a second.
          final storedDeviceId = await configStorage.loadDeviceId(cfg.vaultId);

          // Single config builder for every (re)build — initial boot AND the
          // settings callbacks (onVaultChanged/onConfigChanged/onAuthChanged).
          // Always the SAME provider instance, in every edition and whether or
          // not a session exists: sign-in mutates it in place, so no config
          // rebuild can leave the engine without one. Signed out it simply
          // fails calls locally instead of sending them unauthenticated.
          VaultConfig buildConfig(VaultConfig base) => base.copyWith(
            tokenProvider: auth.tokenProvider,
            deviceId: storedDeviceId,
          );

          final activeConfig = buildConfig(cfg);

          final wasmUri = _resolveWasmUri();

          final vaultId = cfg.vaultId;

          final bootSw = Stopwatch()..start();
          final raw = await plugin.loadData();
          _log.info('boot: loadData ${bootSw.elapsedMilliseconds}ms');
          final dbSuffix =
              (raw as Map<Object?, Object?>?)?['dbSuffix'] as String? ?? '';
          final suffix = dbSuffix.isNotEmpty ? '-$dbSuffix' : '';
          dbFileName = '$vaultId$suffix.db';
          dbName = 'rhyolite-$vaultId$suffix';

          // .obsidian settings sync preferences (opt-in; default off).
          var settingsPrefs = SettingsSyncPrefs.fromData(raw);

          // Remote diagnostics logging (opt-in; default off). The sink itself is
          // installed after platform detection below so DeviceInfo can carry the
          // OS — but it's still early enough to capture the whole engine boot.
          var diagnosticsPrefs = DiagnosticsPrefs.fromData(raw);

          // Per-device file-type sync filter (opt-in; default empty = sync all).
          // A denylist of extensions this device skips both uploading and
          // downloading. Device-local (data.json is not synced). Read live by
          // the engine through the callback below so a settings change takes
          // effect on the next reconcile without reconstructing the engine.
          var fileFilterPrefs = FileFilterPrefs.fromData(raw);

          // User-requested sync pause (from the side panel). Gates the boot
          // start below; the panel toggles it live.
          _syncPaused = raw is Map && raw['syncPaused'] == true;

          // Ask for a durable storage bucket BEFORE the database is opened.
          // Everything this plugin persists — FileState registers, the pull
          // cursor, Fugue trees, the local blob cache — lives in one SQLite
          // file on OPFS (IndexedDB fallback), i.e. in WebView origin storage.
          // Without a persistence grant that storage is best-effort and the OS
          // is free to evict it while Obsidian sits unused; the next launch
          // then starts from cursor 0 and re-downloads the whole vault.
          await _requestPersistentStorage();

          // Open the database, refusing the library's silent in-memory
          // fallback. In-memory looks exactly like a working-but-empty
          // database: sync would run, pull the entire vault from cursor 0,
          // write everything into RAM, and do it all again on the next launch
          // — without a single line saying why. Better to know.
          //
          // Not fatal, though: on a device that genuinely has neither OPFS nor
          // IndexedDB, refusing to open at all would just mean no sync. So the
          // second attempt takes the fallback deliberately, with the user
          // warned that nothing will persist past this session.
          DatabaseConnection dbConn;
          try {
            dbConn = await openFileDb(
              options: SqliteConnectionOptions(
                webDatabaseName: dbName,
                webFileName: dbFileName,
                webSqliteWasmUri: wasmUri,
                webRequireDurableStorage: true,
              ),
            );
          } on DurableWebStorageUnavailable catch (e) {
            _log.error('boot: no durable storage for the sync database: $e');
            showNotice(S.noDurableStorageNotice);
            dbConn = await openFileDb(
              options: SqliteConnectionOptions(
                webDatabaseName: dbName,
                webFileName: dbFileName,
                webSqliteWasmUri: wasmUri,
              ),
            );
          }
          _dbConn = dbConn;
          _log.info('boot: openFileDb ${bootSw.elapsedMilliseconds}ms');

          // Set up database logger
          final dataRepository = SqliteDataRepository(
            storage: SqliteDataStorageAdapter.connection(dbConn),
          );
          final dataClient = IDataClient.repository(repository: dataRepository);
          // Database logging removed during logger migration

          final blobRepo = SqliteBlobRepository.db(
            dbConn.database,
            enableWal: false,
          );

          String platformTag;
          bool isMobile = false;
          try {
            isMobile = jsu.getProperty<bool>(plugin.app.raw, 'isMobile');
            platformTag = isMobile ? 'mobile' : 'desktop';
          } catch (_) {
            platformTag = 'unknown';
          }

          // Install the remote diagnostics sink now that DeviceInfo can carry
          // the OS (iOS/Android/desktop) so the collector can tell devices
          // apart — the bug this exists to debug is device-specific. Off unless
          // the user enabled it; re-applied live from the settings tab.
          _diagnostics = DiagnosticsLogging(
            controller: _logController,
            baselineLevel: _baselineLogLevel,
            log: _log,
            device: () => DeviceInfo(
              name: cfg.vaultName.isNotEmpty ? cfg.vaultName : 'Obsidian',
              app: 'rhyolite_sync',
              os: _diagnosticsOs(isMobile),
            ),
          );
          _diagnostics!.apply(diagnosticsPrefs);

          // On mobile (Obsidian iOS/Android) RAM is tight. StartupDiff
          // holds N × file_bytes in memory while uploading; with large
          // attachments (PDFs, attachments in MB range) concurrency=4
          // can OOM the host process. Cap to 2 on mobile.
          final startupUploadConcurrency = isMobile ? 2 : 4;

          // Plugin version (from the Obsidian manifest) + client kind, reported
          // with this device's head so the device-management UI and support can
          // tell devices/versions apart. Best-effort — empty on any failure.
          String pluginVersion = '';
          try {
            final manifest = jsu.getProperty<JSObject?>(plugin.raw, 'manifest');
            if (manifest != null) {
              pluginVersion =
                  jsu.getProperty<String?>(manifest, 'version') ?? '';
            }
          } catch (_) {}
          final clientKind = selfHostActive ? 'obsidian-selfhost' : 'obsidian';

          // One scheduler for the whole plugin: the engine's sync work and the
          // lifecycle boot/restart work below share it (see [_scheduleBoot]).
          final scheduler = PriorityTaskScheduler(
            onError: (e, _) => _log.warning('scheduler task error: $e'),
          );
          _scheduler = scheduler;

          final ISyncEngine engine = StateSyncEngine(
            vaultPath: '',
            serverUrl: syncServerUrl,
            config: activeConfig.copyWith(
              clientName: 'Obsidian/$platformTag',
              clientVersion: pluginVersion,
              clientKind: clientKind,
            ),
            cipher: cipher,
            dataClient: dataClient,
            blobStore: LocalBlobStore(blobRepo),
            io: ObsidianIO(plugin.app.vault),
            changeProvider: ObsidianChangeProvider(
              plugin,
              logger: _logController.scope('engine'),
            ),
            metaStorage: auth.metaStorage,
            httpClient: ObsidianHttpClient(),
            logger: _logController.scope('engine'),
            rejectionFactory: pluginRejectionFactory,
            startupUploadConcurrency: startupUploadConcurrency,
            scheduler: scheduler,
            // The managed per-file size limit only applies to managed storage —
            // not BYO/external, where we never see the bytes. Callback so a
            // tier change is picked up without reconstructing the engine.
            //
            // Keyed on the non-secret marker: the credentials are never
            // persisted, so this snapshot has `externalBlobConfig == null` even
            // on a BYO vault, and asking it applied the managed plan's
            // per-file cap to storage the plan does not govern.
            maxFileSizeBytes: () => activeConfig.externalStorageKind != null
                ? null
                : _capabilities?.maxFileSizeBytes,
            // Per-device denylist, read live so a settings change is picked up
            // on the next reconcile without reconstructing the engine.
            excludedExtensions: () => fileFilterPrefs.excludedExtensions,
            // Per-device folder filter, same live-read contract. Narrowing
            // takes effect on the next reconcile; widening needs the restart
            // the settings callback performs.
            pathScope: () => fileFilterPrefs.pathScope,
          );
          _engine = engine;
          // Settings sync stores plugin-code blobs in the SAME local cache
          // under the same vaultId, but the engine's blob GC builds its live
          // set from notes alone — without this hook it evicts every plugin
          // blob on the next housekeeping pass. Null while settings sync is
          // enabled but not yet loaded: the GC then skips rather than guesses.
          if (engine is StateSyncEngine) {
            engine.siblingLiveBlobIds = () {
              if (!settingsPrefs.enabled) return const <String>{};
              final cs = _configSync;
              return cs == null ? null : cs.liveBlobIds();
            };
          }
          _log.info('boot: engine ctor ${bootSw.elapsedMilliseconds}ms');

          // (Re)binds `.obsidian` settings sync to the engine's CURRENT
          // endpoint. Every engine restart invalidates the old one, so any
          // path that restarts must call this or settings sync silently stops.
          Future<void> relaunchConfigSync() async {
            if (cipher == null) return;
            await _launchConfigSync(
              engine: engine,
              dataClient: dataClient,
              cipher: cipher!,
              vaultId: vaultId,
              plugin: plugin,
              prefs: settingsPrefs,
            );
          }

          // Restarts the engine so a changed session reaches the wire. The
          // bearer interceptor is installed once per connection, so a new
          // token only takes effect on a fresh connect — assigning
          // `engine.config` alone leaves the live socket authenticating as
          // whoever (or whatever) opened it.
          Future<void> restartForAuth() async {
            await _scheduleBoot((token) async {
              await engine.stop();
              await _guardedStart(engine, token);
            });
            await relaunchConfigSync();
            // A sign-in that can't start the engine yet (no vault picked) emits
            // no engine events, so the panel would keep showing "not signed in"
            // until its 30s tick.
            _syncPanel?.refresh();
          }

          // Starts a full sync session: cache plan caps (the size gate needs
          // the tier BEFORE StartupDiff, which runs inside start()), start the
          // engine, then launch settings-sync. Shared by the boot start below
          // and the panel's Resume action so both take the identical path.
          Future<void> startSyncSession() async {
            try {
              final sub = await accountClient.getSubscription().timeout(
                const Duration(seconds: 5),
              );
              await _rememberPlan(sub, configStorage);
            } catch (e) {
              // Keep whatever we already know — the cached answer loaded at
              // boot, or a fresher one from earlier this session. Overwriting
              // it with null is what made a slow network look like a downgrade.
              _log.info('Subscription lookup failed, using last known plan '
                  '(${_capabilities?.toString() ?? "none cached"}): $e');
            }
            _refreshPlanNotice();
            await _scheduleBoot((token) => _guardedStart(engine, token));
            await relaunchConfigSync();
            await _adoptDeviceId(engine, configStorage);
          }

          // Single source of truth for the pause toggle — shared by the panel
          // Pause/Resume button and the "Pause sync"/"Resume sync" commands so
          // the two surfaces are the same action. Pausing persists + stops;
          // resuming persists + runs the full start session.
          Future<void> setSyncPaused(bool paused) async {
            _syncPaused = paused;
            await configStorage.savePaused(paused);
            if (paused) {
              _cancelSelfHeal();
              _stopConfigSync();
              await engine.stop();
            } else {
              await startSyncSession();
            }
          }

          // Assigned in the recovery block below (needs the engine + config-sync
          // deps that exist further down). Held here so the status-indicator tap,
          // the "Reconnect now" command, the panel button and the offline
          // self-heal timer can all force a recovery through the one code path.
          // Nullable + null-guarded: an early return before assignment simply
          // makes those triggers no-ops (the engine isn't up yet anyway).
          Future<void> Function({required bool requireVisible})? recover;

          // Assigned once the settings tab is registered further down — the
          // browser sign-in flow (state nonce + protocol handler) belongs to
          // that registrar, but the panel is built before it and needs the same
          // one action. Null-guarded, so a click before assignment is a no-op.
          void Function()? beginSignIn;

          // Same late-binding as [beginSignIn]: the picker wants the
          // delete-vault callback declared further down, and the panel is
          // built before it.
          Future<void> Function()? connectVault;

          // The server refused a refresh token it had not already rotated —
          // the one verdict that proves this session is dead. Fired from the
          // account client's single refresh funnel, whichever operation
          // happened to need the token.
          //
          // Before this hook every consumer logged its own failure and carried
          // on ("External blob config check failed", "forced-binary policy load
          // failed", an unhandled zone error), so nothing ever concluded the
          // account was signed out: the engine kept restarting against an
          // account it could not authenticate with, and the panel sat on
          // "Connecting…" indefinitely. Fail closed instead, once, and let the
          // panel offer the sign-in it now has.
          accountClient.onSessionRefused = (reason) {
            if (auth.client == null) return; // already handled
            _log.warning('Session refused by the server — signing out: $reason');
            auth.bindAccount(null);
            _setEngineAuth(engine, auth);
            unawaited(
              configStorage.clearAuthSession().catchError(
                (Object e) => _log.warning('Clearing session failed: $e'),
              ),
            );
            // Stop rather than let the reconnect ladder grind: nothing it can
            // do will authenticate, and every retry costs a full refresh
            // round-trip before failing.
            _cancelSelfHeal();
            _stopConfigSync();
            unawaited(_scheduleBoot((_) => engine.stop()));
            // The settings tab rebuilds on every open and reads auth live, so
            // it needs no nudge — the panel is the one holding a stale render.
            _syncPanel?.refresh();
            showNotice(
              S.syncNotStartedNotice(S.blockedSignedOut),
              timeoutMs: 12000,
            );
          };

          // Why the engine cannot start, or null when nothing is missing.
          //
          // Every one of these used to surface as the same grey "sync stopped /
          // not connected": the panel's `stopped` state means only "no
          // SyncStarted event was ever seen", which is equally true of a signed
          // out plugin and of a dead server. Naming the precondition is the
          // difference between a dead end and a button.
          //
          // Read live (engine + auth, not boot-time locals) so signing in or
          // unlocking clears it without a plugin reload.
          SyncStartBlock? currentStartBlock() {
            // No address to sync with, whichever edition this is.
            if (syncServerUrl.isEmpty) return SyncStartBlock.noServer;
            if (selfHostActive) {
              // Self-host has no account: a URL and a token are all it needs.
              if (selfHostToken.isEmpty) return SyncStartBlock.noServer;
            } else if (selfHost.enabled) {
              // Self-host switched on but not usable (missing URL or token) —
              // it never fell back to managed, so say what's actually wrong.
              return SyncStartBlock.noServer;
            } else if (!authConfig.isConfigured) {
              return SyncStartBlock.noServer;
            } else if (auth.client?.session == null) {
              // A session that exists but whose access token expired is NOT
              // signed out — that is the normal cold-start state, and every
              // call refreshes on demand. Only the absence of a session (never
              // signed in, or one the server refused) is the user's problem.
              return SyncStartBlock.signedOut;
            }
            if (engine.config.vaultId.isEmpty) return SyncStartBlock.noVault;
            // A vault id without a verification token is a half-finished
            // registration: there is nothing to check a passphrase against, so
            // Unlock could not work and the fix is to pick the vault again.
            final token = config?.verificationToken;
            if (token == null || token.isEmpty) return SyncStartBlock.noVault;
            if (engine.cipher == null) return SyncStartBlock.locked;
            return null;
          }

          // Obtains the vault key when it's missing: the passphrase prompt, or
          // whatever the OS keychain/local store already holds. Returns whether
          // the engine ended up with a cipher. Shared by the panel's Unlock
          // button and the "Resume sync" command so both take one path.
          Future<bool> ensureVaultKey() async {
            if (engine.cipher != null) return true;
            final verificationToken = config?.verificationToken;
            if (verificationToken == null || verificationToken.isEmpty) {
              return false;
            }
            final unlocked =
                await configStorage.tryUnlockFromStorage(
                  cfg.vaultId,
                  verificationToken,
                ) ??
                await withModalLock(
                  () => showPassphraseModal(
                    plugin,
                    configStorage,
                    vaultId: cfg.vaultId,
                    verificationToken: verificationToken,
                  ),
                );
            if (unlocked == null) return false;
            cipher = unlocked;
            engine.cipher = unlocked;
            return true;
          }

          // Backend/tier labels for the panel — stable at construction, so
          // derived from the connection mode rather than (later-fetched) caps.
          //
          // From the non-secret marker: the credentials are deliberately never
          // persisted, so a boot-time config has `externalBlobConfig == null`
          // on a BYO vault too, and reading it labelled every such vault
          // "Managed" on every launch.
          final byo = activeConfig.externalStorageKind != null;
          final String backendLabel;
          if (selfHostActive) {
            final host = Uri.tryParse(selfHost.syncUrl)?.host;
            backendLabel = (host != null && host.isNotEmpty)
                ? 'Self-host · $host'
                : 'Self-host';
          } else if (byo) {
            backendLabel = 'Bring-your-own storage';
          } else {
            backendLabel = 'Managed';
          }
          final planLabel = selfHostActive
              ? 'Self-host'
              : (byo ? 'BYO' : 'Managed');

          // Docked right-side panel: live status, one-tap sync, and the
          // over-time warnings (size-blocked files, lossy conflicts) that
          // don't fit the status-bar dot. The indicator's tap reveals it.
          // A soft restart re-runs this boot; drop the prior instance's engine
          // subscription first (registerView itself is idempotent, see below).
          _syncPanel?.dispose();
          final syncPanel = SyncPanel(
            plugin: plugin,
            engine: engine,
            vaultName: cfg.vaultName,
            encrypted: cipher != null,
            backendLabel: backendLabel,
            planLabel: planLabel,
            logger: _logController.scope('plugin'),
            // Site FAQ. Most "is this broken?" questions turn out to be
            // questions about what this sync does differently from the plugin
            // the user came from — empty notes, conflict copies, deletions.
            onOpenFaq: kEnv.siteUrl.isEmpty
                ? null
                : () => _openExternalUrl('${kEnv.siteUrl}/faq'),
            onOpenSettings: () {
              final setting = jsu.getProperty<Object?>(
                plugin.app.raw,
                'setting',
              );
              if (setting == null) return;
              jsu.callMethod<void>(setting, 'open', []);
              jsu.callMethod<void>(setting, 'openTabById', ['rhyolite-sync']);
            },
            onBrowseVersions: () => showFileVersionModal(plugin, engine),
            isPaused: () => _syncPaused,
            onSetPaused: setSyncPaused,
            // Turns "sync stopped / not connected" into the actual missing
            // step, with the button that performs it.
            startBlock: currentStartBlock,
            onSignIn: () async => beginSignIn?.call(),
            onConnectVault: () async => connectVault?.call(),
            onUnlock: () async {
              if (await ensureVaultKey()) await startSyncSession();
            },
            // Shown as a button only while sync looks stuck; runs the same
            // recovery path as the indicator tap and the command.
            onReconnect: () =>
                recover?.call(requireVisible: false) ?? Future<void>.value(),
            // Managed-only usage meter; self-host/BYO have no managed quota.
            onFetchUsage: (selfHostActive || byo)
                ? null
                : () => _fetchVaultUsage(engine, vaultId),
            onSettingsSize: () => SettingsStore(
              client: dataClient,
              vaultId: vaultId,
            ).approxTotalBytes(),
            onPluginStats: () async {
              final o = await _configSync?.pluginOverview();
              return o == null || o.isEmpty
                  ? null
                  : (count: o.count, bytes: o.totalBytes);
            },
            // The user answers the vanished-files question; the engine only
            // ever reported it.
            onConfirmVanished: (fileIds) async {
              if (engine is! StateSyncEngine) return;
              try {
                final n = await engine.confirmVanishedDeletes(fileIds);
                if (n > 0) showNotice(S.vanishedDeleted(n));
              } catch (e) {
                showNotice(S.reclaimFailed(e));
              }
            },
            onStorageDetails: () => _showStorageOverview(
              plugin,
              engine,
              fetchUsage: (selfHostActive || byo)
                  ? null
                  : () => _fetchVaultUsage(engine, vaultId),
            ),
            // Self-host has no account to renew, so the strip has no button
            // there — and no plan alert ever reaches it either.
            onPlanAction:
                selfHostActive || kEnv.siteUrl.isEmpty ? null : _openSubscriptionPage,
          )..register();
          _syncPanel = syncPanel;
          // The panel is built after the boot lookup may already have run.
          syncPanel.setPlanNotice(_planAlert);

          // Single indicator, surface picks itself by platform:
          // status bar on desktop, floating pill on mobile. Tap reveals
          // the docked panel.
          _syncIndicator = SyncStatusIndicator(
            plugin: plugin,
            engine: engine,
            logger: _logController.scope('plugin'),
            onTap: () => unawaited(syncPanel.reveal()),
            // In offline/error/auth-expired the tap forces a recovery instead of
            // just opening the panel (see recover assignment below).
            onReconnect: () => unawaited(recover?.call(requireVisible: false)),
          )..init();

          // The settings notify subscription is an in-flight call too, so it
          // dies on a transport reconnect. The engine emits SyncConnected on
          // every (re)connect; reissue the config notify + catch-up pull. The
          // first SyncConnected fires before config sync is launched, so the
          // null-guard makes it a no-op then and a real reissue on reconnects.
          _configReconnectSub = engine.events.listen((e) {
            if (e is SyncConnected) _configSync?.handleReconnect();
          });

          // The sync database was there yesterday and is gone today (evicted
          // WebView storage is the usual reason on mobile). The engine restores
          // itself, but the user sees the whole vault download again and, if a
          // delete made here never reached the server, that file back on disk.
          // Tell them what happened instead of leaving it as a mystery.
          _stateLostSub = engine.events.listen((e) {
            if (e is! SyncLocalStateLost) return;
            _log.warning('Local sync state lost — device ${e.deviceId}');
            showNotice(S.localStateLostNotice);
          });

          // Durability barriers at the engine's convergence points. These are
          // the events emitted right after the store persists (the puller
          // writes meta, then emits SyncCursorAdvanced), so a flush here means
          // an abrupt kill costs at most the last few seconds of sync rather
          // than everything since the last clean unload.
          _flushSub = engine.events.listen((e) {
            if (e is SyncCursorAdvanced ||
                e is SyncFilePushed ||
                e is SyncStartupBlobUploadDone) {
              unawaited(_flushDb());
            }
          });

          // Permanent-delete propagation. When another device permanently
          // deletes the vault this device is connected to, its registry entry
          // comes back tombstoned (deletedAt set). On (re)connect, pull the
          // vault list and, if our vault is tombstoned, drop it locally:
          // disconnect + wipe local sync state. Files on disk are left
          // untouched (matches the initiating device). We act only on an
          // explicit tombstone, never on mere absence (which could be a
          // transient list failure or an access change).
          _deletedVaultWatchSub = engine.events.listen((e) async {
            if (e is! SyncConnected) return;
            final connectedVaultId = engine.config.vaultId;
            final d = auth.directory;
            if (connectedVaultId.isEmpty || d == null) return;
            final List<VaultInfo> vaults;
            try {
              vaults = await d.listVaults();
            } catch (_) {
              return; // transient — don't forget on a failed list
            }
            final matches = vaults.where((v) => v.vaultId == connectedVaultId);
            if (matches.isEmpty || !matches.first.isDeleted) return;
            _log.info(
              'Vault $connectedVaultId permanently deleted on another device '
              '— dropping it locally (files on disk untouched)',
            );
            engine.cipher = null;
            await _scheduleBoot((_) async {
              await engine.stop();
              try {
                await engine.wipeLocalState();
              } catch (_) {}
            });
            await configStorage.disconnectVault();
          });

          // Permanently delete a vault. Order: (1) tombstone the registration
          // so the vault is marked deleted (other devices see it via listVaults
          // and drop it locally); (2) purge sync data for BOTH keyspaces —
          // notes AND settings/config — from the sync server. Tombstone-first
          // means a failed purge only leaks server data (recoverable by retry —
          // both steps are idempotent), while the user-facing outcome (vault
          // gone everywhere) is already correct.
          //
          // The account/self-host token authorizes deleting any of the user's
          // own vaults, so a short-lived connection works from the picker even
          // with no vault connected. Local note files on disk are never touched;
          // external (BYO) blobs stay in the user's own bucket (the confirmation
          // warns to clear it separately).
          Future<void> deleteVaultClosure(VaultInfo vault) async {
            final dir = auth.directory;
            if (dir == null || !auth.hasToken) {
              throw StateError('Not signed in — cannot delete a vault.');
            }
            final tp = auth.tokenProvider;
            final vaultId = vault.vaultId;

            // 1. Tombstone first (intent). Idempotent.
            await dir.deleteVault(vaultId: vaultId);

            // 2. Purge sync data for both keyspaces over one short-lived socket.
            final conn = WebSocketSyncConnection(
              serverUrl: syncServerUrl,
              tokenProvider: tp,
              logger: _logController.scope('delete'),
            );
            try {
              await conn.connect().timeout(const Duration(seconds: 15));
              final purge = StatePurgeRequest(
                vaultId: vaultId,
                sourceClientId: cfg.clientName,
              );
              // Notes keyspace (default) + settings keyspace ('config'), which
              // lives as a sibling StateSync service on the same socket.
              await conn.stateCaller.purgeVault(purge);
              final configCaller = StateSyncContractCaller(
                conn.endpoint,
                serviceNameOverride: StateSyncContractNames.instance('config'),
              );
              await configCaller.purgeVault(purge);
            } finally {
              await conn.dispose();
            }

            // If this device had that vault connected, clear its local state.
            if (engine.config.vaultId == vaultId) {
              engine.cipher = null;
              await _scheduleBoot((_) async {
                await engine.stop();
                try {
                  await engine.wipeLocalState();
                } catch (_) {}
              });
              await configStorage.disconnectVault();
            }
            _log.info('Vault deleted: $vaultId');
          }

          // The panel's "no vault connected" button. The picker persists the
          // config itself, so all that is left is to get the session rebuilt
          // around it.
          //
          // Reload rather than restart in place: the SQLite file is named after
          // the vault this session booted with (`rhyolite-<vaultId>`), and it
          // was opened long before this click. Restarting the engine would sync
          // the newly-picked vault into the previous session's file and find it
          // empty on the next launch — a full re-download of the whole vault.
          connectVault = () async {
            final dir = auth.directory;
            if (dir == null) return;
            final picked = await withModalLock(
              () => showVaultPickerModal(
                plugin,
                dir,
                configStorage,
                onDeleteVault: deleteVaultClosure,
                maxVaultCount: selfHostActive
                    ? null
                    : _capabilities?.maxVaultCount,
              ),
            );
            if (picked == null) return;
            _log.info('Vault connected: ${picked.$1.vaultId} — reloading');
            reloadPlugin(plugin);
          };

          late final ({void Function() refresh, void Function() beginSignIn})
          settingsHandle;
          void refreshSettings() => settingsHandle.refresh();
          settingsHandle = _registerSettings(
            plugin: plugin,
            configStorage: configStorage,
            config: cfg,
            authConfig: authConfig,
            auth: auth,
            accountClient: accountClient,
            engine: engine,
            buildConfig: buildConfig,
            restartForAuth: restartForAuth,
            settingsSyncPrefs: () => settingsPrefs,
            onDeleteVault: deleteVaultClosure,
            selfHostEnabled: selfHostActive,
            selfHostUrl: selfHost.syncUrl,
            onSettingsSyncChanged: (next) async {
              settingsPrefs = next;
              await configStorage.saveSettingsSync(next.toJson());
              if (cipher != null) {
                await _launchConfigSync(
                  engine: engine,
                  dataClient: dataClient,
                  cipher: cipher!,
                  vaultId: vaultId,
                  plugin: plugin,
                  prefs: settingsPrefs,
                );
              }
              refreshSettings();
            },
            diagnosticsPrefs: () => diagnosticsPrefs,
            onDiagnosticsChanged: (next) async {
              // Persist + apply live; deliberately NO refreshSettings() — the
              // URL text field's onChange fires per keystroke and a tab rebuild
              // would drop the caret. Obsidian's own widgets hold their state.
              diagnosticsPrefs = next;
              await configStorage.saveDiagnostics(next.toJson());
              _diagnostics?.apply(next);
            },
            fileFilterPrefs: () => fileFilterPrefs,
            onFileFilterChanged: (next) async {
              // Persist + swap the live var, then restart. A pull would be
              // enough for NARROWING (the next reconcile turns the file away),
              // but widening either filter has to re-scan disk for files that
              // were never uploaded and backfill states the applier skipped —
              // both of which only happen inside StartupDiff. The settings tab
              // commits on an explicit Save precisely so this restart is a
              // deliberate act and not a consequence of typing a character.
              fileFilterPrefs = next;
              await configStorage.saveFileFilter(next.toJson());
              await restartForAuth();
            },
            // Vault-global force-binary list — read from / written to the
            // engine's encrypted vault-meta so it is the same on every device.
            // Only available while the real engine is running.
            forcedBinaryExtensions: () => engine is StateSyncEngine
                ? engine.forcedBinaryExtensions
                : <String>{},
            onForcedBinaryChanged: (next) async {
              if (engine is! StateSyncEngine) {
                throw StateError('sync engine is not running');
              }
              // Persists to the server (vault-meta) and updates the live set;
              // the engine's classification callback picks it up immediately,
              // so the next edit to an affected file uses the binary path.
              // Existing files convert lazily (no re-scan forced).
              await engine.setForcedBinaryExtensions(next);
            },
          );

          // The panel's sign-in button routes here: the browser-auth nonce and
          // the protocol handler that redeems it live in the settings
          // registrar, and there must be exactly one of each.
          beginSignIn = settingsHandle.beginSignIn;

          // Resume/Pause commands mirror the panel buttons — same persisted
          // pause flag, same code path (setSyncPaused). "Resume" first ensures
          // a vault key, then clears the pause and starts the session.
          plugin.addCommand(
            id: 'rhyolite-sync-start',
            name: S.resumeSync,
            callback: () async {
              if (!await ensureVaultKey()) return;
              await setSyncPaused(false);
            },
          );
          plugin.addCommand(
            id: 'rhyolite-sync-stop',
            name: S.pauseSync,
            callback: () => setSyncPaused(true),
          );
          plugin.addCommand(
            id: 'rhyolite-sync-now',
            name: S.cmdSyncNow,
            callback: () async {
              await engine.triggerPull();
              _log.info('Manual sync triggered');
            },
          );
          // Force a recovery: health-check, and if the transport is stale
          // restart the engine (which re-connects and, on a stale token, chains
          // into token refresh). Distinct from "Sync now" — a pull over a dead
          // socket just hangs; this rebuilds the connection.
          plugin.addCommand(
            id: 'rhyolite-sync-reconnect',
            name: S.cmdReconnect,
            callback: () async {
              _log.info('Manual reconnect triggered');
              await recover?.call(requireVisible: false);
            },
          );
          plugin.addCommand(
            id: 'rhyolite-sync-config-now',
            name: S.cmdSyncSettingsNow,
            callback: () async {
              final cs = _configSync;
              if (cs == null) {
                _log.info('Settings sync is off');
                return;
              }
              await cs.sync();
              _log.info('Manual settings sync triggered');
            },
          );
          plugin.addCommand(
            id: 'rhyolite-cleanup-storage',
            name: S.cmdCleanupStorage,
            callback: () {
              showStorageCleanupModal(plugin, engine);
            },
          );
          plugin.addCommand(
            id: 'rhyolite-manage-devices',
            name: S.cmdManageDevices,
            callback: () {
              showDeviceManagementModal(plugin, engine);
            },
          );
          // Dev builds only: it walks every note in the vault and exists to
          // measure the frontmatter recogniser against Obsidian's own parser,
          // which is useless to anyone not working on that recogniser.
          if (kDebug) {
            plugin.addCommand(
              id: 'rhyolite-audit-frontmatter',
              name: 'Rhyolite (dev): audit frontmatter parsing',
              callback: () => unawaited(() async {
                showNotice('Auditing frontmatter…');
                final result = await auditVault(plugin.app);
                _log.info('frontmatter audit\n${result.summary()}');
                showNotice(
                  result.clean
                      ? 'Frontmatter audit: no disagreements '
                          '(${result.withFrontmatter} notes). See logs.'
                      : 'Frontmatter audit: '
                          '${result.regionDisagreements.length} region, '
                          '${result.keyDisagreements.length} key '
                          'disagreement(s). See logs.',
                );
              }()),
            );
          }
          plugin.addCommand(
            id: 'rhyolite-storage-overview',
            name: S.storageOverviewTitle,
            callback: () => unawaited(_showStorageOverview(plugin, engine)),
          );
          plugin.addCommand(
            id: 'rhyolite-reclaim-orphans',
            name: S.cmdReclaimOrphans,
            callback: () {
              showOrphanSweepModal(plugin, engine);
            },
          );
          plugin.addCommand(
            id: 'rhyolite-configure-selfhost',
            name: S.cmdConfigureSelfHost,
            callback: () async {
              final changed = await withModalLock(
                () => showSelfHostModal(plugin, configStorage),
              );
              if (changed) {
                // Re-run onLoad so the new mode takes effect immediately.
                reloadPlugin(plugin);
              }
            },
          );
          plugin.addCommand(
            id: 'rhyolite-show-file-history',
            name: S.cmdShowHistory,
            callback: () {
              showFileVersionModal(plugin, engine);
            },
          );
          plugin.addCommand(
            id: 'rhyolite-restore-backup',
            name: S.cmdRestoreBackup,
            callback: () {
              showBackupModal(plugin, engine);
            },
          );

          if (_syncPaused) {
            _log.info(
              'Sync paused by user — skipping start. Resume from the '
              'sync panel.',
            );
          } else {
            // Everything from here on may prompt or touch the network, and
            // Obsidian awaits onLoad — so it runs AFTER onLoad returns, with
            // the view type, settings tab and commands already registered.
            //
            // Deferring also keeps the UI responsive while sync warms up: if
            // start later blocks the event loop, Pause / Disable are reachable.
            // Caps are cached BEFORE start() inside startSyncSession — the
            // startup size gate needs the tier before StartupDiff runs.
            Future<void>.delayed(Duration.zero, () async {
              try {
                // The two prompts that used to run inside onLoad: the vault
                // picker on a fresh install, the passphrase on a locked vault.
                // Same moment from the user's point of view, but nothing is
                // waiting on them any more — and dismissing one now leaves a
                // panel that explains itself instead of a dead sidebar.
                var block = currentStartBlock();
                if (block == SyncStartBlock.noVault && auth.directory != null) {
                  // Reloads the plugin on success, so a return here means the
                  // user cancelled.
                  await connectVault?.call();
                } else if (block == SyncStartBlock.locked) {
                  await ensureVaultKey();
                }

                block = currentStartBlock();
                if (block != null) {
                  // Sync cannot run and only the user can change that. Logging
                  // it was never enough: nothing on screen distinguished this
                  // from a server that happens to be down, so a signed-out
                  // plugin looked exactly like an outage.
                  _log.warning('Sync cannot start: ${block.name}');
                  showNotice(
                    S.syncNotStartedNotice(_startBlockReason(block)),
                    timeoutMs: 12000,
                  );
                  _syncPanel?.refresh();
                  return;
                }
                await startSyncSession();
              } catch (e, st) {
                _log.error('Engine start failed', error: e, stackTrace: st);
              }
            });
          }

          // Resume-from-background recovery. When Obsidian is backgrounded
          // — mobile multitasking, desktop sleep, OS suspending the
          // WebView — the WebSocket can die silently: client-side state
          // says "Online" but every send hangs. The user returns, edits,
          // nothing syncs, until they manually run Start Sync (which
          // tears down and rebuilds the engine).
          //
          // Hook visibilitychange: when the tab becomes visible, run a
          // cheap healthCheck. If it fails, the transport is stale —
          // restart the engine. `registerDomEvent` ensures the listener
          // is removed on plugin unload (community-plugin requirement).
          {
            var recoverInFlight = false;
            final documentJs = jsu.getProperty<JSObject?>(
              jsu.globalThis,
              'document',
            );

            // Shared recovery: cheap healthCheck; if the transport is stale
            // restart the engine, otherwise re-arm notify + opportunistically
            // pull so anything missed while offline/backgrounded lands.
            // [requireVisible] gates the resume path (visibilitychange) on the
            // tab actually being visible; the network path (online) fires
            // regardless.
            Future<void> recoverConnection({
              required bool requireVisible,
            }) async {
              if (recoverInFlight || _syncPaused) return;
              // Nothing to recover TO. Restarting the engine against a missing
              // session or a locked vault cannot succeed, and each attempt
              // costs a full refresh round-trip (~15s with the retry ladder)
              // before failing — which is what turned a dead session into an
              // endless "Connecting…" and a plugin that felt slow to start.
              // The panel names the missing piece instead.
              if (currentStartBlock() != null) return;
              if (requireVisible && documentJs != null) {
                final visible =
                    jsu.getProperty<String?>(documentJs, 'visibilityState') ==
                    'visible';
                if (!visible) return;
              }
              if (_engine == null) return;
              recoverInFlight = true;
              try {
                final ok = await _engine!.healthCheck(
                  timeout: const Duration(seconds: 5),
                );
                if (!ok) {
                  _log.warning('Health check failed — restarting engine');
                  try {
                    await _scheduleBoot(
                      (token) async {
                        await _engine!.stop();
                        await _guardedStart(_engine!, token);
                      },
                      automatic: true,
                    );
                    if (cipher != null) {
                      await _launchConfigSync(
                        engine: _engine!,
                        dataClient: dataClient,
                        cipher: cipher!,
                        vaultId: vaultId,
                        plugin: plugin,
                        prefs: settingsPrefs,
                      );
                    }
                  } catch (e) {
                    _log.error('Engine restart on recover failed: $e');
                  }
                } else {
                  await _engine!.reissueNotify();
                  await _engine!.triggerPull();
                  _configSync?.handleReconnect();
                  await _configSync?.sync();
                }
              } finally {
                recoverInFlight = false;
              }
            }

            // Publish the recovery closure so the indicator tap, the "Reconnect
            // now" command and the panel button can all drive it.
            recover = recoverConnection;

            // Offline self-heal. rpc_dart's reconnect loop eventually gives up
            // and the engine emits SyncDisconnected, then does nothing — leaving
            // recovery to the DOM online/visibility hooks, which never fire when
            // the OS network stayed up but the server/token dropped. Arm a capped
            // backoff timer on disconnect so the engine climbs back on its own;
            // cancel it the moment we reconnect.
            // A failed start() emits SyncError, NOT SyncDisconnected, and never
            // wires the connection watcher — so the event stream alone can't keep
            // the ladder going across failed reconnects. The timer re-arms itself
            // instead, capped so a persistently-down server (or the rare
            // healthCheck-passes-without-a-connect-event case) can't spin forever;
            // past the cap the indicator/command/panel button remain.
            const maxSelfHeal = 10;
            var selfHealOnline = false;
            void scheduleHeal() {
              if (_syncPaused || selfHealOnline || _selfHealTimer != null)
                return;
              if (_selfHealAttempt >= maxSelfHeal) {
                _log.warning(
                  'Self-heal gave up after $maxSelfHeal attempts — '
                  'tap the status dot or run "Reconnect now"',
                );
                return;
              }
              // Backoff 5s,10s,20s,40s,60s(cap). Reset to 5s on any reconnect.
              final delaySec = [
                5,
                10,
                20,
                40,
                60,
              ][_selfHealAttempt.clamp(0, 4)];
              _selfHealTimer = Timer(Duration(seconds: delaySec), () async {
                _selfHealTimer = null;
                if (_syncPaused || selfHealOnline || _engine == null) return;
                _selfHealAttempt++;
                _log.info('Self-heal attempt $_selfHealAttempt — recovering');
                // requireVisible:false — the point is to recover with no user
                // action. recoverConnection restarts the engine on failure; on
                // success the connection watcher emits SyncConnected which cancels
                // + resets the ladder. Re-arm here to cover the failed-start case.
                await recoverConnection(requireVisible: false);
                if (!selfHealOnline && _selfHealTimer == null) scheduleHeal();
              });
            }

            _selfHealSub?.cancel();
            _selfHealSub = engine.events.listen((e) {
              if (e is SyncConnected) {
                selfHealOnline = true;
                _cancelSelfHeal();
              } else if (e is SyncDisconnected) {
                selfHealOnline = false;
                scheduleHeal();
              }
            });

            // Resume-from-background: WebSocket can die silently while the WebView
            // is suspended; check on return to visibility. Leaving (hidden) is
            // also a settings sync point: `.obsidian` has no vault events, so
            // push any pending local settings the moment the user switches away
            // — other devices then get them via notify before the user arrives,
            // instead of only on the next return-to-visible.
            if (documentJs != null) {
              jsu.callMethod<void>(plugin.raw, 'registerDomEvent', [
                documentJs,
                'visibilitychange',
                jsu.allowInterop((JSAny? _) {
                  final visible =
                      jsu.getProperty<String?>(documentJs, 'visibilityState') ==
                      'visible';
                  if (visible) {
                    recoverConnection(requireVisible: true);
                  } else {
                    // Leaving is the last reliable moment before Android may
                    // kill the process: drain the write queue now, whether or
                    // not sync is paused.
                    unawaited(_flushDb(immediate: true));
                  }
                  if (!visible && !_syncPaused) {
                    // Best-effort, no delay: the WebView can suspend right after
                    // 'hidden' (mobile), so fire immediately. sync() is _busy-safe
                    // and a no-op when nothing changed (signature guard).
                    final cs = _configSync;
                    if (cs != null) unawaited(cs.sync());
                  }
                }),
              ]);
            }
            // Second durability barrier. 'hidden' is the one that reliably
            // fires on Obsidian mobile, but it is not guaranteed to be last —
            // 'pagehide' catches a teardown that skipped it. Both are
            // idempotent: a flush with an empty queue completes at once.
            jsu.callMethod<void>(plugin.raw, 'registerDomEvent', [
              jsu.globalThis,
              'pagehide',
              jsu.allowInterop(
                (JSAny? _) => unawaited(_flushDb(immediate: true)),
              ),
            ]);
            // Network restored: reconnect immediately instead of waiting out the
            // transport's reconnect backoff.
            jsu.callMethod<void>(plugin.raw, 'registerDomEvent', [
              jsu.globalThis,
              'online',
              jsu.allowInterop(
                (JSAny? _) => recoverConnection(requireVisible: false),
              ),
            ]);
          }

          // Settings-dialog close is a cross-platform "settings changed" signal.
          // Obsidian emits no vault event for `.obsidian`, but nearly every
          // settings edit happens inside this dialog, so pushing on its close
          // propagates changes immediately (still on this device) instead of
          // only on the next resume. We wrap `app.setting.close`; a short settle
          // delay lets settings that flush their file write on close land before
          // the scan. Restored on unload via plugin.register so a reloaded plugin
          // neither stacks wrappers nor pins a disposed engine.
          {
            final setting = jsu.getProperty<Object?>(plugin.app.raw, 'setting');
            final originalClose = setting == null
                ? null
                : jsu.getProperty<Object?>(setting, 'close');
            if (setting != null && originalClose != null) {
              jsu.setProperty(
                setting,
                'close',
                jsu.allowInterop(() {
                  jsu.callMethod<void>(originalClose, 'call', [setting]);
                  if (_syncPaused) return;
                  Timer(const Duration(milliseconds: 400), () {
                    final cs = _configSync;
                    if (cs != null) unawaited(cs.sync());
                  });
                }),
              );
              jsu.callMethod<void>(plugin.raw, 'register', [
                jsu.allowInterop(
                  () => jsu.setProperty(setting, 'close', originalClose),
                ),
              ]);
            }
          }

          // Listen for session expiry and prompt re-authentication.
          // `_autoSignInInFlight` dedupes overlapping SessionExpired
          // events while the auto sign-in flow is mid-wait or mid-modal.
          var _autoSignInInFlight = false;
          _engineAuthEventsSub = engine.events.listen((event) async {
            switch (event) {
              case ExternalBlobConfigDiscovered(:final kind):
                _log.info(
                  'External blob config ($kind) discovered from server',
                );
                // The engine already fetched, decrypted and applied the config
                // synchronously (_checkExternalBlobConfig) BEFORE emitting this
                // event, so read the applied config from the engine — the secret
                // must never travel on the broadcast events stream. copyWith
                // treats null as "no change", so a missing config is a no-op.
                final extConfig = engine.config.externalBlobConfig;
                // Build on top of the *current* config, not the initial
                // load-time snapshot — `cfg` is `final` and misses any
                // post-load edits (verification token rotation, vault
                // rename, etc.). Persist only the non-secret kind marker
                // (VaultConfig.toJson drops the secret); the secret stays in
                // memory + on the E2EE server.
                final base = config ?? cfg;
                final updated = base.copyWith(
                  externalBlobConfig: extConfig,
                  externalStorageKind: extConfig?.kind ?? kind,
                );
                config = updated;
                await configStorage.save(updated);
                if (engine.config.externalBlobConfig == null) {
                  // Runtime discovery — the engine wasn't started with the
                  // secret, so adopt it and restart to pick up the backend.
                  // (Unreachable at start-time now that the engine self-applies;
                  // kept for the historical runtime-discovery path.)
                  engine.config = buildConfig(
                    engine.config.copyWith(
                      externalBlobConfig: extConfig,
                      externalStorageKind: extConfig?.kind ?? kind,
                    ),
                  );
                  await _scheduleBoot((_) async {
                    await engine.stop();
                    await _guardedStart(engine);
                  });
                  await relaunchConfigSync();
                  _log.info('Restarted with external blob storage');
                }
                // Otherwise the engine already self-applied the secret in
                // _checkExternalBlobConfig during this start() — no restart.
                // Re-render the settings tab so it shows "Connected: ..."
                // instead of the snapshot's "Configure" buttons.
                refreshSettings();
                return;
              case SyncConnected():
                // Authenticated traffic is flowing again — arm the bounded
                // rebind budget for the next auth incident.
                _authRebindAttempts = 0;
                return;
              case SubscriptionRequired():
                return;
              case SessionExpired():
                // Self-host has no account session — never prompt for sign-in.
                if (selfHostActive) return;
                break; // fall through to refresh handler below
              // A stale token surfaces as auth.* on an active RPC (not only as
              // SessionExpired). Funnel it into the same debounced refresh path
              // so an expired session heals without an Obsidian restart. Self-
              // host has no account session, so never refresh/prompt there.
              case SyncServerRejected(:final code)
                  when code.startsWith('auth.'):
                if (selfHostActive) return;
                break; // fall through to refresh handler below
              // Every other policy rejection (managed storage unavailable, quota
              // exceeded, permission denied, unrecognised app_policy code). A
              // real policy state, not a token problem: log and let the sync
              // indicator surface it. Crucially no auto-restart — that's what
              // created the per-record grind loop that froze Obsidian.
              case SyncServerRejected(:final code, :final message)
                  when code.startsWith('app_policy.'):
                _log.warning('Sync paused — server refused ($code): $message');
                return;
              default:
                return;
            }
            // Debounce: a burst of rejections (every pending RPC failing at
            // once, or repeated auth.* from a stale token) must not each spawn a
            // refresh+restart. At most one refresh in flight, and no more than
            // once per cooldown.
            final nowAuth = DateTime.now();
            if (_authRefreshInFlight ||
                (_lastAuthRefreshAt != null &&
                    nowAuth.difference(_lastAuthRefreshAt!) <
                        const Duration(seconds: 8))) {
              return;
            }
            _lastAuthRefreshAt = nowAuth;

            final live = accountClient.session;
            final client = auth.client ?? accountClient;
            final tokenMissing = event is AuthTokenMissing;
            final plan = planAuthRecovery(
              tokenMissing: tokenMissing,
              sessionLive: live != null && !live.isExpired,
              sessionPresent: client.session != null,
              providerBound: auth.hasToken && auth.client != null,
              rebindBudgetLeft: _authRebindAttempts < _kMaxAuthRebinds,
            );

            // A live session with nothing attached to the wire is OUR failure,
            // not an expired token: the provider was unbound, or the socket
            // was opened before the sign-in and still authenticates as nobody.
            if (plan == AuthRecovery.rebind) {
              _authRebindAttempts++;
              _log.warning('Auth rejected but session is live — rebinding');
              auth.bindAccount(accountClient);
              _setEngineAuth(engine, auth);
              engine.config = buildConfig(engine.config);
              await restartForAuth();
              _log.info('Auth rebound from live session — restarted');
              return;
            }

            _log.warning('Auth rejected — attempting token refresh');

            var refreshOutcome = RefreshOutcome.notAttempted;
            if (plan == AuthRecovery.refresh) {
              _authRefreshInFlight = true;
              try {
                final session = await client.refreshSession();
                await configStorage.saveAuthSession(session);
                auth.bindAccount(client);
                _setEngineAuth(engine, auth);
                engine.config = buildConfig(engine.config);
                await restartForAuth();
                _log.info('Token refreshed — restarted');
                return;
              } catch (e) {
                // Log the reason. Swallowing it made "was my session really
                // expired?" unanswerable from the logs, which is exactly the
                // question a surprise logout raises.
                refreshOutcome = classifyRefreshFailure(e);
                _log.warning('Refresh failed (${refreshOutcome.name}): $e');
              } finally {
                _authRefreshInFlight = false;
              }
            }

            if (shouldClearStoredSession(
              tokenMissing: tokenMissing,
              refresh: refreshOutcome,
            )) {
              await configStorage.clearAuthSession();
              auth.bindAccount(null);
              _setEngineAuth(engine, auth);
            }
            engine.config = buildConfig(engine.config);

            // No verdict: the session we hold may well be fine. Never prompt
            // on this — prompting is what taught the user to re-login for a
            // dropped connection. Rebind (an unbound provider is our own bug,
            // and it is the only thing a restart here can fix) and let the
            // next incident, or the self-heal timer, retry.
            if (refreshOutcome == RefreshOutcome.inconclusive) {
              final stillHaveSession = client.session != null;
              final unbound = !(auth.hasToken && auth.client != null);
              if (stillHaveSession &&
                  unbound &&
                  _authRebindAttempts < _kMaxAuthRebinds) {
                _authRebindAttempts++;
                auth.bindAccount(client);
                _setEngineAuth(engine, auth);
                engine.config = buildConfig(engine.config);
                await restartForAuth();
                _log.info('Refresh inconclusive — session kept, provider '
                    'rebound');
              } else {
                _log.warning(
                  'Refresh inconclusive — keeping the stored session, '
                  'will retry',
                );
              }
              return;
            }

            if (!authConfig.isConfigured) return;

            // Dedupe: multiple SessionExpired events can fire in
            // quick succession (notify reconnect, pending RPCs all
            // failing). Without this flag every one of them would
            // queue its own awaitModalClose + showSignInModal.
            if (_autoSignInInFlight) return;
            _autoSignInInFlight = true;
            try {
              if (isModalOpen) {
                _log.info(
                  'Session expired — waiting for current modal '
                  'to close before prompting re-auth',
                );
                await awaitModalClose();
                // World may have moved on while we waited (user might
                // have signed in via Settings, or refreshed the token
                // through another flow). Try refresh once more; if it
                // succeeds no prompt is needed.
                try {
                  final session = await accountClient.refreshSession();
                  await configStorage.saveAuthSession(session);
                  auth.bindAccount(accountClient);
                  _setEngineAuth(engine, auth);
                  engine.config = buildConfig(engine.config);
                  await restartForAuth();
                  _log.info(
                    'Token refreshed after modal closed — no prompt needed',
                  );
                  return;
                } catch (e) {
                  // Still bad — fall through and prompt.
                  _log.warning('Refresh after modal close failed: $e');
                }
              }
              // Browser-auth is the only sign-in method, so there is no
              // credential modal to pop here. Point the user at Settings,
              // where the "Sign in" button starts the browser handoff; its
              // protocol handler re-auths the engine on return.
              showNotice(
                'Rhyolite: session expired. Open Settings → Rhyolite Sync '
                'and press Sign In.',
              );
              final setting = jsu.getProperty<Object?>(
                plugin.app.raw,
                'setting',
              );
              if (setting != null) {
                jsu.callMethod<void>(setting, 'open', []);
                jsu.callMethod<void>(setting, 'openTabById', ['rhyolite-sync']);
              }
            } finally {
              _autoSignInInFlight = false;
            }
          });
        },
        (error, stack) {
          if (_isSqliteCorrupt(error)) {
            onCorruptDb();
          } else {
            _log.error('Unhandled error', error: error, stackTrace: stack);
          }
        },
      );
    },
    onUnload: (_) async {
      _stopConfigSync();
      await _configReconnectSub?.cancel();
      _configReconnectSub = null;
      await _engineAuthEventsSub?.cancel();
      _engineAuthEventsSub = null;
      await _deletedVaultWatchSub?.cancel();
      _deletedVaultWatchSub = null;
      await _stateLostSub?.cancel();
      _stateLostSub = null;
      await _flushSub?.cancel();
      _flushSub = null;
      _flushDebounce?.cancel();
      _flushDebounce = null;
      await _selfHealSub?.cancel();
      _selfHealSub = null;
      _cancelSelfHeal();
      _syncIndicator?.dispose();
      _syncIndicator = null;
      _syncPanel?.closeLeaves();
      _syncPanel?.dispose();
      _syncPanel = null;
      // Close the remote log sink's WebSocket, if the user had it on.
      _diagnostics?.dispose();
      _diagnostics = null;
      await _engine?.stop();
      _engine = null;
      await _scheduler?.dispose();
      _scheduler = null;
      await _dbConn?.close();
      _dbConn = null;
    },
  );
}

// Returns the `refresh` callback so the caller can re-render the settings tab
// in response to events that update vault config from outside the tab itself
// (notably ExternalBlobConfigDiscovered), plus `beginSignIn` so the sync panel
// can offer the same browser sign-in the tab does.
({void Function() refresh, void Function() beginSignIn}) _registerSettings({
  required PluginHandle plugin,
  required ObsidianConfigStorage configStorage,
  required VaultConfig config,
  required AuthConfig authConfig,
  // Shared, by reference: sign-in here must be visible to every other
  // consumer (above all the auth-recovery listener in onLoad), which is
  // exactly what a by-value `RpcAccountClient?` parameter got wrong.
  required AuthSessionState auth,
  required RpcAccountClient accountClient,
  required ISyncEngine engine,
  required VaultConfig Function(VaultConfig) buildConfig,
  required Future<void> Function() restartForAuth,
  required SettingsSyncPrefs Function() settingsSyncPrefs,
  required Future<void> Function(SettingsSyncPrefs next) onSettingsSyncChanged,
  required DiagnosticsPrefs Function() diagnosticsPrefs,
  required Future<void> Function(DiagnosticsPrefs next) onDiagnosticsChanged,
  required FileFilterPrefs Function() fileFilterPrefs,
  required Future<void> Function(FileFilterPrefs next) onFileFilterChanged,
  required Set<String> Function() forcedBinaryExtensions,
  required Future<void> Function(Set<String> next) onForcedBinaryChanged,
  required Future<void> Function(VaultInfo vault) onDeleteVault,
  required bool selfHostEnabled,
  required String selfHostUrl,
}) {
  late final ({void Function() refresh, void Function() beginSignIn}) settings;
  void refreshSettings() => settings.refresh();
  settings = registerSettingsTab(
    plugin: plugin,
    configStorage: configStorage,
    config: config,
    authConfig: authConfig,
    authClient: () => auth.client,
    accountClient: accountClient,
    // Evaluated per call, not once at wiring: a vault can be marked BYO after
    // this closure is built (the credentials arrive from the server during
    // start()), and a ternary resolved here would keep fetching a managed
    // quota that does not apply.
    onFetchUsage: () async =>
        (selfHostEnabled || engine.config.externalStorageKind != null)
            ? null // no managed quota on self-host / BYO
            : _fetchVaultUsage(engine, config.vaultId),
    openUrl: _openExternalUrl,
    authWebUrl: kEnv.siteUrl,
    onConfigChanged: (updated) async {
      engine.config = buildConfig(updated);
      // Route the restart through the lifecycle lane so it can't overlap a
      // queued reconnect / token-refresh boot on the single WebSocket.
      await _scheduleBoot((_) async {
        await engine.stop();
        await _guardedStart(engine);
      });
    },
    onAuthChanged: (newAuthConfig, client) async {
      auth.bindAccount(client);
      _setEngineAuth(engine, auth);
      // Build on the engine's LIVE config, not the registration-time
      // snapshot — that one predates the client name/version/kind the
      // constructor added and any vault edits made since.
      engine.config = buildConfig(engine.config);
      // A sign-in that only updates config leaves the running connection
      // authenticating as nobody: the bearer interceptor is bound once per
      // connect. Reconnect, or the user stays "signed in" and unsynced.
      await restartForAuth();
      _log.info('Signed in — engine restarted');
    },
    onSignOut: () async {
      auth.bindAccount(null);
      _setEngineAuth(engine, auth);
      await _scheduleBoot((_) => engine.stop());
      _log.info('Signed out');
    },
    onDisconnectVault: () async {
      // Order matters: stop the engine BEFORE wiping the local stores
      // so no in-flight reconcile/push can resurrect rows mid-wipe.
      // wipeLocalState reads config.vaultId, which stays in memory on
      // the engine even after configStorage.disconnectVault() has
      // cleared the on-disk vault config. Runs on the lifecycle lane so a
      // queued boot can't start the engine mid-wipe.
      engine.cipher = null;
      await _scheduleBoot((_) async {
        await engine.stop();
        try {
          await engine.wipeLocalState();
        } catch (e) {
          _log.error('Vault disconnect: local wipe failed', error: e);
        }
      });
      _log.info('Vault disconnected (local state wiped)');
    },
    onVaultChanged: (newConfig, newCipher) async {
      // Reload rather than restart in place — same reason the panel's
      // connect-vault button does.
      //
      // The SQLite file is named after the vault this session booted with
      // (`rhyolite-<vaultId>`, empty id when none was connected) and was
      // opened long before this call. The stores key their rows by vaultId,
      // so a restart in place syncs the newly-connected vault into the
      // PREVIOUS session's file: it works, right up until the next launch
      // opens `rhyolite-<newVaultId>` and finds it empty. Since a deviceId
      // was adopted for the new vault in the meantime, the engine then reads
      // that emptiness as a LOST database — the user gets the "your local
      // sync state is gone" notice and a full re-download of the vault.
      //
      // The picker has already persisted the config, so a clean boot picks
      // everything up.
      _log.info('Vault connected: ${newConfig.vaultId} — reloading');
      reloadPlugin(plugin);
    },
    onDeleteVault: onDeleteVault,
    onSubscribed: () => _waitForSubscriptionAndStart(
      plugin: plugin,
      engine: engine,
      accountClient: accountClient,
      configStorage: configStorage,
      onDone: refreshSettings,
    ),
    onResetVault: () async {
      await engine.triggerReset();
      _log.info('Vault re-upload initiated');
    },
    onRestoreFromServer: () async {
      await engine.triggerRestoreFromServer();
      _log.info('Vault restore from server initiated');
    },
    onRepairVault: () async {
      await engine.triggerRepair();
      _log.info('Vault repair initiated');
    },
    onSaveExternalBlobConfig: (extConfig) async {
      // Fail loudly. Silent skips here mean the user ticked Configure,
      // saw the modal close, but the encrypted config never reached the
      // server — so other devices never adopt it, and a local-DB wipe
      // on this device loses it forever. The settings tab catches these
      // throws and surfaces them as a Notice.
      final store = auth.metaStorage;
      if (store == null) {
        throw StateError(
          'Connect a vault before configuring external storage.',
        );
      }
      // Read the LIVE cipher/vaultId off the engine, not the values captured
      // when the settings tab was registered — after a vault switch those
      // are stale, and the config would be encrypted with the old vault's
      // key and stored under its id.
      final c = engine.cipher;
      if (c == null) {
        throw StateError('Vault is locked — enter your passphrase first.');
      }
      final metaService = VaultMetaService(
        storage: store,
        vaultId: engine.config.vaultId,
        cipher: c,
      );
      await metaService.saveExternalBlobConfig(extConfig);
      _log.info('External blob config saved');
    },
    onClearExternalBlobConfig: () async {
      final store = auth.metaStorage;
      if (store == null) {
        throw StateError('Connect a vault before clearing external storage.');
      }
      // Live engine values, not the registration-time snapshot (see save).
      final c = engine.cipher;
      if (c == null) {
        throw StateError('Vault is locked — enter your passphrase first.');
      }
      final metaService = VaultMetaService(
        storage: store,
        vaultId: engine.config.vaultId,
        cipher: c,
      );
      await metaService.clearExternalBlobConfig();
      _log.info('External blob config cleared');
    },
    settingsSyncPrefs: settingsSyncPrefs,
    onSettingsSyncChanged: onSettingsSyncChanged,
    // Read live: the plan (and so the answer) can change under a running
    // session, and the measurement lands asynchronously after boot.
    pluginCodeAvailability: () => pluginCodeAvailability(
      selfHost: selfHostEnabled,
      externalStorage: engine.config.externalStorageKind != null,
      managedStorageQuotaBytes: _capabilities?.managedStorageQuotaBytes,
    ),
    pluginCodeSize: () {
      final bytes = _pluginCodeLocalBytes;
      return bytes == null || bytes == 0 ? null : formatBytes(bytes);
    },
    planNotice: () => _planAlert,
    // This tab fetches its own subscription; route it through the host so the
    // lapse comparison, the persisted snapshot and the panel strip all move
    // together instead of the tab holding a private, fresher opinion.
    onSubscriptionFetched: (sub) async {
      await _rememberPlan(sub, configStorage);
      _refreshPlanNotice();
    },
    onShowStorageOverview: () => _showStorageOverview(
      plugin,
      engine,
      fetchUsage: (selfHostEnabled || engine.config.externalStorageKind != null)
          ? null
          : () => _fetchVaultUsage(engine, config.vaultId),
    ),
    diagnosticsPrefs: diagnosticsPrefs,
    onDiagnosticsChanged: onDiagnosticsChanged,
    fileFilterPrefs: fileFilterPrefs,
    onFileFilterChanged: onFileFilterChanged,
    forcedBinaryExtensions: forcedBinaryExtensions,
    onForcedBinaryChanged: onForcedBinaryChanged,
    onResetSettings: () async {
      final cs = _configSync;
      if (cs == null) {
        throw StateError('Settings sync is off.');
      }
      await cs.resetFromThisDevice();
      _log.info('Settings re-upload finished');
    },
    onRestoreSettings: () async {
      final cs = _configSync;
      if (cs == null) {
        throw StateError('Settings sync is off.');
      }
      await cs.restoreFromServer();
      _log.info('Settings download finished');
    },
    selfHostEnabled: selfHostEnabled,
    selfHostUrl: selfHostUrl,
    selfHostDirectory: selfHostEnabled ? auth.directory : null,
  );
  return settings;
}

/// Polls the account service's getSubscription endpoint every 10 seconds for up to 5 minutes.
/// Shows a modal with a spinner while waiting. Starts the engine on success.
Future<void> _waitForSubscriptionAndStart({
  required PluginHandle plugin,
  required ISyncEngine engine,
  required RpcAccountClient accountClient,
  required ObsidianConfigStorage configStorage,
  void Function()? onDone,
}) async {
  const interval = Duration(seconds: 10);
  const timeout = Duration(minutes: 5);
  final deadline = DateTime.now().add(timeout);

  _log.info('Waiting for subscription activation...');

  ModalContext<void>? modalCtx;
  SpinnerRef? spinnerRef;

  // Open a modal with a spinner — the polling runs in the background.
  // We capture ctx/spinner via the build closure and close/update from below.
  unawaited(
    showModalWith<void>(
      plugin,
      build: (ctx) {
        modalCtx = ctx;
        ctx.h3(S.activatingSubscription);
        ctx.spaceVertical(px: 12);
        ctx.createEl('p', text: S.confirmingPayment);
        ctx.spaceVertical(px: 12);
        spinnerRef = ctx.spinner(label: S.checking);
        spinnerRef!.show();
        ctx.spaceVertical(px: 4);
        ctx.onEscape(() {}); // disable accidental close
      },
    ),
  );

  // Give the modal a moment to render before polling starts.
  await Future<void>.delayed(const Duration(milliseconds: 300));

  bool confirmed = false;

  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(interval);

    try {
      final subscription = await accountClient.getSubscription();
      await _rememberPlan(subscription, configStorage);
      if (subscription.isActive) {
        confirmed = true;
        break;
      }
      _log.debug('Subscription not yet active, retrying...');
    } catch (e) {
      _log.error('checkAccess error', error: e);
    }
  }

  final ctx = modalCtx;
  if (ctx == null) return;

  if (confirmed) {
    _log.info('Subscription confirmed — starting engine');
    spinnerRef?.hide();
    // Replace modal content with success message.
    ctx.close(null);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await showModalWith<void>(
      plugin,
      build: (ctx2) {
        ctx2.h3('🎉 ${S.subscriptionActivated}');
        ctx2.spaceVertical(px: 12);
        ctx2.createEl('p', text: S.subscriptionNowActive);
        ctx2.spaceVertical(px: 16);
        ctx2.buttonRow([
          ButtonSpec(
            S.gotIt,
            () => ctx2.close(null),
            variant: ButtonVariant.primary,
          ),
        ]);
        ctx2.onEscape(() => ctx2.close(null));
      },
    );
    onDone?.call();
    await _guardedStart(engine);
  } else {
    _log.warning('Subscription not activated within 5 minutes');
    spinnerRef?.hide();
    ctx.close(null);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await showModalWith<void>(
      plugin,
      build: (ctx2) {
        ctx2.h3(S.paymentNotConfirmed);
        ctx2.spaceVertical(px: 12);
        ctx2.createEl('p', text: S.paymentNotConfirmedBody);
        ctx2.spaceVertical(px: 16);
        ctx2.buttonRow([ButtonSpec(S.close, () => ctx2.close(null))]);
        ctx2.onEscape(() => ctx2.close(null));
      },
    );
    onDone?.call();
  }
}
