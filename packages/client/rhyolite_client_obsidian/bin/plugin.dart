// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_client_account/rhyolite_client_account.dart'
    hide VaultInfo;
import 'package:rhyolite_client_obsidian/rhyolite_client_obsidian.dart';
import 'package:rhyolite_client_obsidian/src/diagnostics/bug_report.dart';
import 'package:rhyolite_client_obsidian/src/diagnostics/bug_report_modal.dart';
import 'package:rhyolite_client_obsidian/src/diagnostics/diagnostic_redactor.dart';
import 'package:rhyolite_client_obsidian/src/diagnostics/persistent_log_sink.dart';
import 'package:rhyolite_client_obsidian/src/engine/auth_recovery.dart';
import 'package:rhyolite_client_obsidian/src/engine/auth_session_state.dart';
import 'package:rhyolite_client_obsidian/src/engine/boot/auth_boot.dart';
import 'package:rhyolite_client_obsidian/src/engine/boot/database_boot.dart';
import 'package:rhyolite_client_obsidian/src/engine/boot/engine_boot.dart';
import 'package:rhyolite_client_obsidian/src/engine/host_info.dart';
import 'package:rhyolite_client_obsidian/src/engine/build_env.dart';
import 'package:rhyolite_client_obsidian/src/engine/connection_recovery.dart';
import 'package:rhyolite_client_obsidian/src/engine/durability_barrier.dart';
import 'package:rhyolite_client_obsidian/src/engine/db_recovery.dart';
import 'package:rhyolite_client_obsidian/src/engine/diagnostics_logging.dart';
import 'package:rhyolite_client_obsidian/src/engine/file_version_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/frontmatter_audit_binding.dart';
import 'package:rhyolite_client_obsidian/src/engine/modal_lock.dart';
import 'package:rhyolite_client_obsidian/src/engine/plan_status.dart';
import 'package:rhyolite_client_obsidian/src/engine/plugin_management_modal.dart';
import 'package:rhyolite_client_obsidian/src/diagnostics/log_file_store.dart';
import 'package:rhyolite_client_obsidian/src/diagnostics/obsidian_log_file_store.dart';
import 'package:rhyolite_client_obsidian/src/engine/plugin_session.dart';
import 'package:rhyolite_client_obsidian/src/engine/recovery_state.dart';
import 'package:rhyolite_client_obsidian/src/engine/self_host_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/server_rejections.dart';
import 'package:rhyolite_client_obsidian/src/engine/storage_overview_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/sync_panel.dart';
import 'package:rhyolite_client_obsidian/src/engine/sync_status_indicator.dart';
import 'package:rhyolite_client_obsidian/src/engine/vault_picker_modal.dart';
import 'package:rhyolite_client_obsidian/src/i18n/i18n.dart';
import 'package:rhyolite_client_obsidian/src/platform/obsidian_http_client.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_compression/rpc_dart_compression.dart';
import 'package:rpc_dart_log/rpc_dart_log.dart';
import 'package:rpc_data/rpc_data.dart';

// Baseline level. This codebase logs at info/warning/error and almost nothing
// below, so `info` captures everything the plugin and the engine actually say
// while leaving out rpc_dart's debug/trace internals — which are voluminous,
// and describe the transport rather than the sync. Dev builds take everything.
//
// Release used to sit at `warning` with no outputs at all, which meant a user
// reporting a bug had nothing to report with. When the user enables remote
// diagnostics, [DiagnosticsLogging] drops this to debug and restores it after.
const _baselineLogLevel = kDebug ? RpcLogLevel.debug : RpcLogLevel.info;

// Release builds log to this device and nowhere else. The session's log sink
// keeps a memory ring plus a two-generation file under the plugin folder; that
// file is what a bug report ships. Nothing is transmitted anywhere unless the
// user turns on remote diagnostics, which is still off by default.
final _logController = LogController(
  outputs: kDebug ? [ConsoleOutput()] : [],
  minLevel: _baselineLogLevel,
);
final _log = _logController.scope('plugin');

/// Everything the current load owns. The ONE top-level slot holding
/// per-load state — see [PluginSession] for why the count is the point.
///
/// Read from `onUnload` and nowhere else. Everything built during `onLoad`
/// captures the object, so a closure made by one load acts on that load's
/// resources even while the next load has already replaced this slot.
PluginSession? _session;

/// Starts the engine unless the user paused sync. ALL non-explicit start paths
/// (boot, reconnect, token refresh, config/vault change, subscription) route
/// through this so a persisted pause is honoured everywhere — otherwise the
/// flag desyncs from reality (engine running while "paused"). The pause flag is
/// cleared only by an explicit resume (`setSyncPaused(false)` in boot).
Future<void> _guardedStart(
  PluginSession session,
  ISyncEngine engine, [
  TaskCancelToken? token,
]) async {
  if (session.syncPaused) {
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
  SyncStartBlock.storageRefused => S.blockedStorageRefused,
};

/// Builds the local log and hands it to [session], which owns it from then on.
///
/// The build lives here because it needs the Obsidian handle: the vault adapter
/// to write through, and the version/OS probes for the banner. Everything after
/// that — install, remove, close — belongs to the session, which is what makes
/// the teardown order testable.
void _installPersistentLog(PluginSession session, PluginHandle plugin) {
  LogFileStore store;
  try {
    store = ObsidianLogFileStore(plugin.app.vault);
  } catch (_) {
    // No vault adapter is not a reason to lose the session's logs — the ring
    // still holds them, and the report falls back to it.
    store = const NoopLogFileStore();
  }
  // Sized for a startup scan, which is the loudest thing this plugin does:
  // DiskReconciler logs several info lines per text file, so a large vault's
  // first pass runs to megabytes. Those lines are worth keeping at info —
  // "sync never finished starting" is a common report, and they are what
  // diagnoses it — so the buffers are sized to hold a boot rather than the
  // levels lowered to hide one.
  final sink = PersistentLogSink(
    store: store,
    segmentId: PersistentLogSink.segmentIdFor(DateTime.now()),
    memoryCapacity: 4000,
  );
  if (!session.attachLog(sink)) return;
  final os = isMobileHost(plugin) ? diagnosticsOs(true) : 'desktop';
  unawaited(
    sink.start(
      banner:
          'rhyolite ${pluginVersion(plugin)} on $os, '
          'Obsidian ${obsidianVersion()}'
          '${kDebug ? ', debug build' : ''}',
    ),
  );
}

/// Problems reach back across sessions and are rare, so this can be generous.
const _kReportProblemLines = 600;

/// States what the log is missing, in English alongside the rest of the report
/// body. Silence here would be the worst outcome: a truncated log that looks
/// complete is read as "nothing else happened", which is a wrong answer rather
/// than a missing one.
String? _logCompletenessNotice(LogStats stats, {required int fileCount}) {
  final notes = <String>[];
  if (fileCount == 0) {
    notes.add('No log files could be read from disk.');
  }
  if (!stats.fileHealthy) {
    notes.add(
      'The log file could not be written, so this is only what was still in '
      'memory from the current session.',
    );
  }
  if (stats.tailSlotsDiscarded > 0) {
    notes.add(
      'This session outgrew its log ${stats.tailSlotsDiscarded} time(s), so '
      'its middle was dropped. Nothing was summarised — every line here is '
      'verbatim, and the gaps in the #n sequence say exactly how many records '
      'are missing and where. ${stats.recordsSeen} records in total.',
    );
  }
  if (notes.isEmpty) return null;
  notes.add(
    'Log segments kept on this device: ${stats.retainedSegments} '
    '(a segment is a session or a day, whichever ends first).',
  );
  return notes.join(' ');
}

/// Report section titles are English in every locale, deliberately: the file is
/// read by whoever is debugging it, not by the user who produced it. What the
/// user reads — the modal, the preview, every button — is localised.
Future<(BugReport, List<(String, String)>)> _buildBugReport(
  PluginSession session,
  PluginHandle plugin,
  String description,
) async {
  final sink = session.logSink;
  var problems = '';
  var logFiles = <(String, String)>[];
  String? logNotice;
  if (sink == null) {
    logNotice = S.bugReportLogUnavailable;
  } else {
    // Files verbatim, not a rendered tail. There is no cap: entries are
    // compressed one at a time, so the whole retained log costs one file of
    // memory at a time rather than all of it at once.
    logFiles = await sink.readAllLogFiles();
    problems = await sink.readProblems(maxLines: _kReportProblemLines);
    logNotice = _logCompletenessNotice(sink.stats, fileCount: logFiles.length);
  }

  return (
    BugReport(
      generatedAt: DateTime.now(),
      userDescription: description,
      problems: problems,
      logNotice: logNotice,
      pathsRedacted: session.reportPathSalt.isNotEmpty,
      sections: [
        _environmentSection(session, plugin),
        ...?session.reportFacts?.call(),
      ],
    ),
    logFiles,
  );
}

BugReportSection _environmentSection(
  PluginSession session,
  PluginHandle plugin,
) {
  final mobile = isMobileHost(plugin);
  return BugReportSection.compact('Environment', [
    ('Plugin', pluginVersion(plugin)),
    ('Obsidian', obsidianVersion()),
    ('Platform', mobile ? diagnosticsOs(true) : 'desktop'),
    ('Build', kDebug ? 'debug' : 'release'),
    ('Edition', session.selfHost ? 'self-host' : 'managed'),
    ('Language', obsidianLanguage()),
    ('Account server', kEnv.accountServiceUrl),
    ('Site', kEnv.siteUrl),
    // Stated rather than assumed: an unwritable log is the difference between
    // "the session was quiet" and "the session was never recorded".
    ('Log file', session.logSink?.lastStoreError == null ? 'ok' : 'unwritable'),
  ]);
}

/// Erases the on-device diagnostic logs, reporting what it freed.
///
/// Logging continues afterwards — this clears history, it does not turn
/// anything off. The size is read before the delete because afterwards there
/// is nothing left to measure.
Future<void> _clearDiagnosticLogs(PluginSession session) async {
  final sink = session.logSink;
  if (sink == null) return;
  try {
    final freed = await sink.diskBytes();
    await sink.clear();
    showNotice(S.clearLogsDone(formatBytes(freed)));
  } catch (e) {
    showNotice(S.clearLogsFailed(e));
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

/// Stops the offline self-heal loop and resets its backoff. Called on connect
/// and on pause; unload goes through [PluginSession.dispose].
void _cancelSelfHeal(PluginSession session) {
  session.cancelSelfHealTimer();
  session.recovery.resetSelfHeal();
}

/// Persists a fresh plan answer, if it said anything new.
///
/// The decision of what to keep is [PlanTracker.absorb]; this only writes what
/// it hands back. A failed write costs the next cold start its cached plan and
/// nothing else, so it is logged and swallowed.
Future<void> _rememberPlan(
  PluginSession session,
  SubscriptionDto? dto,
  ObsidianConfigStorage storage,
) async {
  final next = session.plans.absorb(dto);
  if (next == null) return;
  try {
    await storage.savePlan(next);
  } catch (e) {
    _log.debug('plan cache write failed: $e');
  }
}

/// Recomputes the plan alert and pushes it everywhere that shows it.
void _refreshPlanNotice(PluginSession session) {
  final next = session.plans.refresh(DateTime.now());
  if (next == null) return;
  session.panel?.setPlanNotice(next);
  if (!next.isQuiet) _announcePlanOnce(session, next);
}

/// Shows the plan alert once, as a notice with a way to act on it.
void _announcePlanOnce(PluginSession session, PlanNotice notice) {
  if (!session.plans.claimAnnouncement(notice)) return;
  final date = notice.date == null ? null : formatPlanDay(notice.date!);
  final message = switch (notice.alert) {
    PlanAlert.ended => date == null ? S.planEndedNoDate : S.planEndedOn(date),
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

/// The vault's plugin set joined with this device's disk, or empty when
/// plugin-code sync is off / settings sync isn't running.
Future<PluginCodeOverview> _pluginOverview(PluginSession session) async {
  try {
    return await session.configSync?.pluginOverview() ??
        PluginCodeOverview.empty;
  } catch (e) {
    _log.warning('plugin overview failed: $e');
    return PluginCodeOverview.empty;
  }
}

/// Opens the storage overview. Single definition so the sync panel, the
/// command palette and the settings tab all show the same thing.
Future<void> _showStorageOverview(
  PluginSession session,
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
    plugins: await _pluginOverview(session),
    usage: usage,
    onManagePlugins: () => _showPluginManagement(session, plugin),
    // The modal cannot reach the database — the handle does not leave
    // GatedDatabase — so its numbers and its two actions are handed in.
    onDatabaseStats: () async => session.db?.stats(),
    onDatabaseReport: () => _writeDatabaseReport(session, plugin),
    onCompactDatabase: () => _compactDatabase(session),
  );
}

/// Writes the database report into the vault and names where it went.
Future<void> _writeDatabaseReport(
  PluginSession session,
  PluginHandle plugin,
) async {
  final db = session.db;
  if (db == null) return;
  try {
    const path = 'rhyolite-database-report.md';
    await ObsidianIO(
      plugin.app.vault,
    ).writeFile(path, Uint8List.fromList(utf8.encode(await db.report())));
    showNotice(path);
    _log.info('Database report written');
  } catch (e) {
    _log.warning('Database report failed: $e');
    showNotice('$e');
  }
}

/// Compacts the database and reports what it gave back.
Future<void> _compactDatabase(PluginSession session) async {
  final db = session.db;
  if (db == null) return;
  showNotice(S.compactRunning);
  try {
    final r = await db.compact();
    String mb(int? b) =>
        b == null ? '?' : '${(b / (1024 * 1024)).toStringAsFixed(0)} MB';
    final done = S.compactDone(mb(r.beforeBytes), mb(r.afterBytes));
    _log.warning(done);
    showNotice(done);
  } catch (e) {
    _log.warning('Database compaction failed: $e');
    showNotice('$e');
  }
}

/// Opens plugin management, where a plugin can be dropped from the vault for
/// every device at once.
Future<void> _showPluginManagement(
  PluginSession session,
  PluginHandle plugin,
) => showPluginManagementModal(
  plugin,
  load: () => _pluginOverview(session),
  onRemove: (resourceId) async =>
      await session.configSync?.removeFromVault(resourceId) ?? false,
);

/// Obsidian's own mobile flag. Desktop-only plugins are not materialized here.
bool _isMobileApp(PluginHandle plugin) {
  try {
    return jsu.getProperty<bool?>(plugin.app.raw, 'isMobile') ?? false;
  } catch (_) {
    return false;
  }
}

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
  PluginSession session,
  Future<void> Function(TaskCancelToken token) body, {
  bool automatic = false,
}) async {
  // Raised on the way IN — before the scheduler is even consulted — because
  // the window this guards opens the moment a restart is decided on, not the
  // moment it starts running. A boot that is still queued behind another has
  // already stopped nothing and started nothing, and the engine it will
  // replace may already be down.
  if (session.engineBootsInFlight == 0) {
    session.engineBootStartedAt = DateTime.now();
  }
  session.engineBootsInFlight += 1;
  try {
    final scheduler = session.scheduler;
    if (scheduler == null) return await body(TaskCancelController().token);
    return await scheduler.schedule(
      key: 'engine-lifecycle',
      priority: automatic ? _kRecoveryPriority : _kBootPriority,
      preemptible: automatic,
      run: body,
    );
  } finally {
    session.engineBootsInFlight -= 1;
    if (session.engineBootsInFlight <= 0) session.engineBootStartedAt = null;
  }
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

/// Prompts a reload once per burst of settings arriving from another device.
/// Debounced because a sync lands many resources at once and one prompt is the
/// whole point.
void _scheduleSettingsReloadNotice(PluginSession session, PluginHandle plugin) {
  session.settingsReloadDebounce?.cancel();
  session.settingsReloadDebounce = Timer(const Duration(seconds: 3), () {
    _showReloadNotice(
      plugin,
      'Settings synced from another device. Reload to apply them.',
    );
  });
}

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

void _showReloadNotice(PluginHandle plugin, String message) =>
    _noticeWithButton(
      message,
      buttonText: 'Reload',
      onClick: () {
        final commands = jsu.getProperty<Object?>(plugin.app.raw, 'commands');
        if (commands != null) {
          jsu.callMethod<void>(commands, 'executeCommandById', ['app:reload']);
        }
      },
    );

/// (Re)starts `.obsidian` settings sync. Idempotent — disposes any running
/// instance first. No-op when disabled, before the engine has an endpoint, or
/// before a vault key is available. The config caller reuses the engine's live
/// connection via a distinct service name.
Future<void> _launchConfigSync({
  required PluginSession session,
  required ISyncEngine engine,
  required IDataClient dataClient,
  required IVaultCipher cipher,
  required String vaultId,
  required PluginHandle plugin,
  required SettingsSyncPrefs prefs,
}) async {
  // Serialised against every other launch — see [PluginSession.configSyncLaunch].
  // The guard cannot live with the callers: there are five of them, and only
  // the automatic re-arm ever checked.
  final previous = session.configSyncLaunch;
  final mine = Completer<void>();
  session.configSyncLaunch = mine.future;
  session.configSyncLaunching = true;
  // A failed predecessor must not cancel this launch; it had its own caller to
  // report to.
  if (previous != null) await previous.catchError((_) {});

  session.stopConfigSync();
  if (!prefs.enabled || engine is! StateSyncEngine) {
    _finishConfigSyncLaunch(session, mine);
    return;
  }
  if (engine.endpoint == null) {
    _finishConfigSyncLaunch(session, mine);
    return;
  }
  try {
    await _launchConfigSyncInner(
      session: session,
      engine: engine,
      dataClient: dataClient,
      cipher: cipher,
      vaultId: vaultId,
      plugin: plugin,
      prefs: prefs,
    );
  } finally {
    _finishConfigSyncLaunch(session, mine);
  }
}

/// Releases this launch's place in the queue, and the flag with it when no
/// later launch has queued behind us.
void _finishConfigSyncLaunch(PluginSession session, Completer<void> mine) {
  mine.complete();
  if (identical(session.configSyncLaunch, mine.future)) {
    session.configSyncLaunch = null;
    session.configSyncLaunching = false;
  }
}

Future<void> _launchConfigSyncInner({
  required PluginSession session,
  required StateSyncEngine engine,
  required IDataClient dataClient,
  required IVaultCipher cipher,
  required String vaultId,
  required PluginHandle plugin,
  required SettingsSyncPrefs prefs,
}) async {
  // Resolved per call, like [BlobDirSync.blobIO] just below and for the same
  // reason: the engine rebuilds its connection on reconnect, and on the
  // re-upload and restore buttons, which stop and start it from inside
  // without the plugin ever hearing about it.
  RpcCallerEndpoint? currentEndpoint() => engine.endpoint;
  StateSyncContractCaller caller() {
    final endpoint = currentEndpoint();
    // The `!` that used to be here asserted exactly what the comment above
    // says can stop being true. A restore restarts the engine from inside a
    // pull — "server epoch ahead, forcing restore" — and settings sync, which
    // starts alongside it, reached for the endpoint a beat after it was torn
    // down. That surfaced as `Null check operator used on a null value`, which
    // says nothing about what happened or what to do.
    //
    // Not having a connection is not a fault, it is a moment. Naming it lets
    // the start below defer instead of reporting a failure, and the
    // SyncConnected handler re-arms when the engine comes back.
    if (endpoint == null) throw const _EngineOffline();
    return StateSyncContractCaller(
      endpoint,
      serviceNameOverride: StateSyncContractNames.instance('config'),
    );
  }

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
    selfHost: session.selfHost,
    externalStorage: engine.config.externalStorageKind != null,
    managedStorageQuotaBytes:
        session.plans.capabilities?.managedStorageQuotaBytes,
  );
  final categories = prefs.categories;
  final pluginCodeWanted = categories.contains(
    SettingsCategory.communityPluginCode,
  );
  final pullOnly = pluginCodePullOnly(enabled: categories, availability: gate);
  if (pullOnly.isNotEmpty) {
    _log.info(
      'Plugin code upload paused: ${gate.name} '
      '(existing plugin records still sync down)',
    );
  }

  final pluginCode = BlobDirSync(
    adapter: plugin.app.vault.adapter,
    // Rebuilt per call: the engine swaps remote storage on reconnect and on a
    // BYO-credentials change.
    blobIO: () =>
        engine.newSiblingBlobIO(maxDownloadBytes: BlobDirSync.maxFileBytes),
    isMobile: _isMobileApp(plugin),
    deviceLabel: engine.config.clientName,
    pluginsManagerRaw: jsu.getProperty<Object?>(plugin.appRaw, 'plugins'),
    // Surfaces plugin/theme transfers in the panel's active-transfers view,
    // the same place note content appears. A first sync moves tens of
    // megabytes; without this it is minutes of silence.
    onTransfer:
        ({
          required String path,
          required bool upload,
          required int sentBytes,
          required int totalBytes,
          required bool done,
        }) => engine.reportSiblingTransfer(
          path: path,
          upload: upload,
          sentBytes: sentBytes,
          totalBytes: totalBytes,
          done: done,
        ),
    log: _logController.scope('settings'),
  );
  // Measure what plugins weigh here even when the category is off — that number
  // is exactly what the settings row shows to make the opt-in an informed one.
  // Stat-only, so it costs nothing to keep current.
  unawaited(
    pluginCode
        .localTotalBytes(SyncedDirKind.plugin)
        .then((bytes) {
          session.pluginCodeLocalBytes = bytes;
        })
        .catchError((Object _) {}),
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
    pluginCode:
        (pluginCodeWanted ||
            categories.contains(SettingsCategory.themesSnippets))
        ? pluginCode
        : null,
    // Reclaim the replaced plugin version's storage right after the push,
    // instead of leaving it for whenever the user happens to run a sweep.
    // The server decides what is actually dead; we only nominate.
    releaseBlobs: engine.releaseBlobs,
    // Event-driven remote->local: react to another device's settings push on
    notifyEndpoint: currentEndpoint,
    notifyTopic: 'vault:${vaultId}_config',
    onActivity: (active) {
      // Both surfaces, from one report: the dot says whether anything is
      // working, the panel says what. Feeding only the dot is how the panel
      // came to say "up to date" while settings files were still moving.
      session.indicator?.setSettingsActivity(active);
      session.panel?.setSettingsActivity(active);
    },
    // Obsidian doesn't hot-apply config files from disk, so a settings change
    // synced from another device lands on disk but isn't live until a reload.
    // Prompt one (debounced, one notice per burst).
    onRemoteApplied: () => _scheduleSettingsReloadNotice(session, plugin),
    log: _logController.scope('settings'),
    // Share the note engine's connection-fair scheduler: settings sync runs
    // as low-priority background work that yields to interactive note sync
    // and pauses while the user is actively editing.
    runBackground: engine.scheduleBackground,
  );
  session.configSync = cs;
  try {
    await cs.start();
    _log.info('Settings sync started (${prefs.categories.length} categories)');
    // The blob GC ran (and refused) before this existed — its live set was
    // incomplete without us. Now that we can answer, let it try again.
    engine.rescheduleLocalBlobGc();
  } on _EngineOffline {
    // The engine went down between the check at the top of this function and
    // the first call needing its connection — a restore is the usual reason.
    // Left stopped on purpose: SyncConnected re-arms it, and reporting this as
    // a failure would put an error in front of the user for a state that
    // resolves itself in seconds.
    _log.info('Settings sync deferred: the engine is between connections');
    session.stopConfigSync();
  } catch (e, st) {
    _log.error('Settings sync start failed', error: e, stackTrace: st);
  }
}

/// The engine has no connection right now. Distinct from a failure because
/// nothing is wrong: something restarted it, and it is coming back.
class _EngineOffline implements Exception {
  const _EngineOffline();

  @override
  String toString() => 'the engine is between connections';
}

/// Points the engine at whatever [auth] now holds, after any rebind.
///
/// One call instead of the two lines that used to follow every
/// `auth.bindAccount(...)` at eight sites, in two of which only the first line
/// was there. Nothing was broken by that — see below — but a rule kept by hand
/// at eight sites is not a rule.
///
/// The meta storage is the load-bearing half. It is set once at construction,
/// so without this a post-construction sign-in (session-expired refresh, manual
/// re-auth, the settings callback) leaves the engine holding a stale null and
/// `_checkExternalBlobConfig` silently never loads the server-side blob config.
///
/// The config rebuild is the other half, and it is currently a no-op: the two
/// fields `buildConfig` sets are a `MutableTokenProvider` that is one instance
/// for the life of [AuthSessionState] (rebinding mutates it in place — that is
/// what it is for) and a device id read once at boot. It stays because the
/// invariant is "the engine's config is rebuilt whenever auth changes", and
/// keeping it in one place is what makes that survive `buildConfig` ever
/// gaining a term that does depend on auth.
void _applyAuth(
  ISyncEngine engine,
  AuthSessionState auth,
  VaultConfig Function(VaultConfig) buildConfig,
) {
  if (engine is StateSyncEngine) engine.metaStorage = auth.metaStorage;
  engine.config = buildConfig(engine.config);
}

/// Opens [url] in the user's real system browser, not Obsidian's in-app Web
/// Viewer. Browser-auth depends on this: the site's `obsidian://rhyolite-auth`
/// callback only reaches the protocol handler when login happens in the
/// external browser — inside the in-app WebView the redirect is swallowed and
/// Electron throws a detached-webview error ("getWebContentsId"). Uses
/// Electron's `shell.openExternal` on desktop, falling back to `window.open`
/// on mobile (no Electron), where that already opens the system browser.
/// Writes a tiny object to [extConfig]'s backend, reads it back and removes it.
///
/// Throws with a message a user can act on when the backend refuses. This is
/// the only moment the credentials are checked at all: after this they are
/// encrypted onto the server and adopted by every device the vault has, so a
/// mistake here is not one device's problem.
Future<void> _probeExternalStorage(
  ExternalBlobConfig extConfig, {
  required IVaultCipher cipher,
  required String vaultId,
}) async {
  final storage = defaultRemoteBlobStorageBuilder(
    config: VaultConfig(
      vaultId: vaultId,
      vaultName: 'probe',
      externalBlobConfig: extConfig,
    ),
    cipher: cipher,
    httpClient: ObsidianHttpClient(),
    endpoint: null,
  );
  if (storage == null) {
    throw StateError('could not build a client for this storage');
  }
  final bytes = Uint8List.fromList(utf8.encode('rhyolite connection probe'));
  final id = ChunkedBlobIO.hasherFor(null)(bytes);
  try {
    await storage.upload([(bytes, id)]);
    bool readBack;
    try {
      readBack = (await storage.exists([id])).contains(id);
    } on BlobProbeIncomplete {
      // The upload just proved the network is up, so this is a backend that
      // stores objects but will not answer HEAD for them. That costs it the
      // background integrity pass, not the ability to hold a vault — so ask
      // for the object instead of turning it away at setup.
      readBack = (await storage.download([id])).containsKey(id);
    }
    if (!readBack) {
      throw StateError(
        'the storage accepted a test object but did not return it — check the '
        'bucket or path',
      );
    }
  } finally {
    // Best effort: a probe left behind is untidy, not broken, and reporting a
    // cleanup failure over the real one would bury it.
    try {
      await storage.deleteMany([id]);
    } catch (_) {}
  }
}

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
Future<void> _flushDb(PluginSession session, {bool immediate = false}) async {
  final db = session.db;
  if (db == null) return;
  if (immediate) {
    session.flushDebounce?.cancel();
    session.flushDebounce = null;
    final sw = Stopwatch()..start();
    // Logged BEFORE the await as well as after, because the interesting
    // outcome is a flush that starts and never finishes. With only the
    // completion line, "the barrier never fired" and "the barrier is still
    // waiting" are the same silence — and they need opposite fixes.
    final seq = ++session.flushSeq;
    _log.info('db flush #$seq: draining');
    try {
      await db.flush();
      sw.stop();
      // Logged on SUCCESS, not only on failure. The failure line existed and
      // the success line did not, so a run in which no flush ever happened and
      // a run in which every flush succeeded produced identical silence —
      // which is exactly the pair that had to be told apart when an
      // interrupted sync kept starting over. Once per barrier at most, and the
      // barriers are debounced.
      _log.info('db flush #$seq done in ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      sw.stop();
      _log.warning('db flush #$seq failed after ${sw.elapsedMilliseconds}ms: $e');
    }
    return;
  }
  // Coalesce: a sync burst emits many convergence points, and each flush only
  // waits for work queued before it — flushing per event would serialise the
  // write queue for no added durability.
  if (session.flushDebounce != null) return;
  session.flushDebounce = Timer(const Duration(seconds: 3), () {
    session.flushDebounce = null;
    unawaited(_flushDb(session, immediate: true));
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
/// Logs `navigator.storage.estimate()` — bytes used and the origin's quota.
///
/// A grant of persistence says the storage will not be evicted. It says
/// nothing about how much of it is left, and those are the two different
/// failures a full database can have. Best-effort in every direction, like
/// the grant above: absent on old WebViews, and never worth blocking a boot.
Future<void> _logStorageEstimate() async {
  try {
    final navigator = jsu.getProperty<Object?>(jsu.globalThis, 'navigator');
    if (navigator == null) return;
    final storage = jsu.getProperty<Object?>(navigator, 'storage');
    if (storage == null || !jsu.hasProperty(storage, 'estimate')) {
      _log.warning('boot: storage.estimate() unavailable');
      return;
    }
    final estimate = await jsu
        .promiseToFuture<Object?>(
          jsu.callMethod<Object>(storage, 'estimate', const []),
        )
        .timeout(const Duration(seconds: 3), onTimeout: () => null);
    if (estimate == null) {
      _log.warning('boot: storage.estimate() timed out');
      return;
    }
    final usage = jsu.getProperty<Object?>(estimate, 'usage');
    final quota = jsu.getProperty<Object?>(estimate, 'quota');
    final used = usage is num ? usage.toDouble() : null;
    final cap = quota is num ? quota.toDouble() : null;
    final pct = (used != null && cap != null && cap > 0)
        ? (used / cap * 100).toStringAsFixed(1)
        : '?';
    _log.warning(
      'boot: storage usage=$usage quota=$quota ($pct% used, '
      'free=${cap != null && used != null ? (cap - used).round() : '?'} bytes)',
    );
  } catch (e) {
    _log.warning('boot: storage.estimate() failed: $e');
  }
}

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
      _log.warning(
        'boot: storage.persist() unavailable — storage is evictable',
      );
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
    extraCss:
        '''
      .rhyolite-setting-desc { color: var(--text-muted); font-size: 0.85em; }
      .rhyolite-group-note {
        color: var(--text-muted); font-size: 0.85em;
        margin: -0.5em 0 0.75em 0;
      }
      .rhyolite-vault-label { font-weight: 500; }
      .rhyolite-bug-report-input {
        width: 100%; resize: vertical; font-family: inherit;
      }
      /* Bounded and scrollable: the preview exists so the report can be read
         before it is sent, and an unbounded pre would push the buttons that
         send it off the bottom of the modal. */
      .rhyolite-bug-report-preview {
        max-height: 40vh; overflow: auto; white-space: pre-wrap;
        word-break: break-word; font-size: 0.8em;
        background: var(--background-secondary); padding: 0.5em;
        border-radius: 4px;
      }
$kSyncPanelCss
''',
    onLoad: (plugin) async {
      // Pick UI strings from Obsidian's language before any UI is built.
      initLocale();

      // First statement with any state in it, deliberately: everything built
      // below is registered ON this object, so a teardown that arrives at any
      // point finds a complete picture of what this load owns. `session` is a
      // local, captured by every closure made here — the global slot exists
      // only so onUnload can find it.
      final session = PluginSession(logs: _logController);
      _session = session;

      // Before the first await too, and before anything that can throw: from
      // here on the session is recorded, so a boot failure below leaves a bug
      // report that can explain itself.
      _installPersistentLog(session, plugin);

      // Registered here rather than with the other commands, which live inside
      // the boot block: the reports worth the most are the ones from a boot
      // that never finished, and a command registered down there would not
      // exist in exactly that case. It degrades instead of failing — without
      // [PluginSession.reportFacts] the report carries the environment and the
      // log, which is what such a report is for.
      plugin.addCommand(
        id: 'rhyolite-sync-bug-report',
        name: S.bugReportCommand,
        callback: () => showBugReportModal(
          plugin,
          buildReport: (description) =>
              _buildBugReport(session, plugin, description),
          openUrl: _openExternalUrl,
          supportUrl: kSupportUrl,
          submit: session.reportSubmitter,
          log: _logController.scope('report'),
        ),
      );

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
            final engine = session.engine;
            session.engine = null;
            await engine?.stop();
            final db = session.db;
            session.db = null;
            await db?.close();
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

          // Auth, edition and the stored session, in one phase that knows
          // nothing about Obsidian — see [bootstrapAuth]. Everything it needs
          // from `data.json` is named by [AuthBootStorage], which
          // ObsidianConfigStorage satisfies.
          final booted = await bootstrapAuth(
            storage: configStorage,
            accountServiceUrl: kEnv.accountServiceUrl,
            managedSyncUrl: kEnv.syncServiceUrl,
            log: _log,
            registryLog: _logController.scope('registry'),
          );
          final auth = booted.auth;
          final accountClient = booted.accountClient;
          final authConfig = booted.authConfig;
          final syncServerUrl = booted.syncServerUrl;
          final selfHostActive = booted.selfHostActive;

          session.selfHost = selfHostActive;
          session.plans.selfHost = selfHostActive;
          // Seeds both sides of the tracker before anything reads a plan: the
          // first successful lookup overwrites one of them, and a lapse is
          // only visible as the difference between the two.
          session.plans.seed(booted.cachedPlan);
          // Self-host only, and null otherwise. Owned for the load and given
          // back with it; before the session existed this was a local nothing
          // closed.
          session.registryConnection = booted.registryConnection;

          // From the remembered plan alone, before any lookup. A paused vault
          // never reaches startSyncSession and an offline one gets nothing back
          // from it, and both are cases where a lapse that was already recorded
          // still needs saying — a period ends on its date regardless. Left
          // here rather than inside the phase: announcing is UI.
          _refreshPlanNotice(session);

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
          final bootedConfig = config;
          final bootedToken = bootedConfig?.verificationToken;
          if (bootedConfig != null &&
              bootedToken != null &&
              bootedToken.isNotEmpty) {
            cipher = await configStorage.tryUnlockFromStorage(
              bootedConfig.vaultId,
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
          final names = DatabaseNames.forVault(vaultId, suffix: dbSuffix);
          // The corruption modal tells the user which file to remove, and it
          // is registered outside this block, so the names have to reach it.
          dbFileName = names.fileName;
          dbName = names.databaseName;

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
          session.syncPaused = raw is Map && raw['syncPaused'] == true;

          final opened = await openVaultDatabase(
            names: names,
            wasmUri: wasmUri,
            requestPersistence: _requestPersistentStorage,
            onFallback: (_) => showNotice(S.noDurableStorageNotice),
            log: _log,
          );
          session.db = opened.db;
          final dataClient = opened.db.dataClient;
          final blobRepo = opened.db.blobRepository;

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
          session.diagnostics = DiagnosticsLogging(
            controller: _logController,
            baselineLevel: _baselineLogLevel,
            log: _log,
            device: () => DeviceInfo(
              name: cfg.vaultName.isNotEmpty ? cfg.vaultName : 'Obsidian',
              app: 'rhyolite_sync',
              os: diagnosticsOs(isMobile),
            ),
          );
          session.diagnostics!.apply(diagnosticsPrefs);

          // How long the open took, restated where it can be heard.
          //
          // `openVaultDatabase` logs this itself, and that line has never once
          // reached a collector: it is written before the sink above exists,
          // and the controller has no replay. The plan item asking how 44
          // seconds divides between the persistence grant and the open itself
          // was not missing instrumentation — it was reading a line that never
          // left the device. (First answer once it did: all of it is the open.
          // The grant costs nothing.)
          _log.info(
            'boot: openFileDb ${opened.totalMs}ms '
            '(persist ${opened.persistMs}ms, open ${opened.openMs}ms, '
            'durable ${opened.durable})',
          );

          // WHICH BUILD IS THIS. Nothing in the log said, and answering it
          // once took reconstructing a timeline from commit timestamps against
          // session start times to find out whether a fix under test was even
          // present. Every "did that land?" question starts here, so it is the
          // first thing said after the sink exists.
          _log.info(
            'boot: plugin ${pluginVersion(plugin)} '
            '${selfHostActive ? 'selfhost' : 'managed'} '
            '${isMobile ? 'mobile' : 'desktop'}',
          );

          // Which VFS, because it decides whether flush() does anything —
          // see [GatedDatabase.storageKind].
          try {
            _log.info('boot: storage ${await session.db?.storageKind()}');
          } catch (e) {
            _log.warning('boot: storage kind unavailable: $e');
          }

          // Can this database be flushed AT ALL?
          //
          // Twenty-three flushes across two sessions started and not one
          // finished, which is not what a queue that is merely behind looks
          // like. The VFS runs its work items strictly one at a time and
          // re-arms itself on completion, so a single item that never
          // completes stalls the chain permanently and every later flush waits
          // forever behind it.
          //
          // Asked here because here is the only moment nothing else is
          // running: no pull, no settings sync, one statement's worth of
          // writes. A flush that cannot complete HERE is broken outright, and
          // no amount of scheduling barriers elsewhere can matter.
          unawaited(() async {
            final sw = Stopwatch()..start();
            try {
              await session.db?.flush().timeout(const Duration(seconds: 10));
              _log.info('boot: flush probe ok in ${sw.elapsedMilliseconds}ms');
            } catch (e) {
              _log.error(
                'boot: flush probe DID NOT COMPLETE in '
                '${sw.elapsedMilliseconds}ms — durability barriers cannot '
                'work on this database: $e',
              );
            }
          }());

          // Clear out the change feed earlier builds wrote.
          //
          // Nothing writes it any more, but nothing deleted what was already
          // there either, and on one vault that was 106.5 MB — most of the
          // live database. Compacting alone would have kept every row of it:
          // VACUUM packs a database, it does not prune one.
          //
          // Before the size is reported below, so the number the user is shown
          // is the one they can act on.
          try {
            final freed = await session.db!.dropLegacyChangeJournal();
            if (freed != null && freed > 0) {
              _log.warning(
                'Dropped the local change journal — $freed pages freed. '
                'Nothing read it; compacting now returns them to the disk.',
              );
            }
          } catch (e) {
            _log.warning('boot: could not drop the change journal: $e');
          }

          // What this vault's database looks like, every boot — and the same
          // reason for being here rather than at the open.
          try {
            _log.info(await session.db!.describe());
          } catch (e) {
            _log.warning('boot: could not describe the database: $e');
          }

          // And how much room the origin has left, which the database's own
          // size cannot tell you. Two different ways to run out.
          await _logStorageEstimate();

          // One scheduler for the whole plugin: the engine's sync work and the
          // lifecycle boot/restart work below share it (see [_scheduleBoot]).
          final scheduler = PriorityTaskScheduler(
            onError: (e, _) => _log.warning('scheduler task error: $e'),
          );
          session.scheduler = scheduler;

          // The graph itself — see [buildSyncEngine]. Every Obsidian-facing
          // part is passed in from here, which is what lets a test assemble the
          // same engine.
          final built = buildSyncEngine(
            serverUrl: syncServerUrl,
            config: activeConfig,
            cipher: cipher,
            dataClient: dataClient,
            blobRepository: blobRepo,
            io: ObsidianIO(plugin.app.vault),
            changeProvider: ObsidianChangeProvider(
              plugin,
              logger: _logController.scope('engine'),
            ),
            metaStorage: auth.metaStorage,
            httpClient: ObsidianHttpClient(),
            scheduler: scheduler,
            logger: _logController.scope('engine'),
            isMobile: isMobile,
            platformTag: platformTag,
            clientVersion: pluginVersion(plugin),
            selfHost: selfHostActive,
            plans: session.plans,
            configSync: () => session.configSync,
            settingsSyncEnabled: () => settingsPrefs.enabled,
            excludedExtensions: () => fileFilterPrefs.excludedExtensions,
            pathScope: () => fileFilterPrefs.pathScope,
            // Resolved per call rather than captured: `session.db` is replaced
            // on a recovery reopen, and a captured handle would go on measuring
            // and flushing a database nobody is writing to any more.
            databaseBytes: () async => (await session.db?.stats())?.fileBytes,
            flushDatabase: () => _flushDb(session, immediate: true),
          );
          final ISyncEngine engine = built.engine;
          session.engine = engine;
          _log.info('boot: engine ctor ${bootSw.elapsedMilliseconds}ms');

          session.reportPathSalt = cfg.vaultId;

          // Uploading needs an account service and a session; self-host has
          // neither. Read live through `auth`, so signing in later enables it
          // without rebuilding anything.
          session.reportSubmitter = selfHostActive
              ? null
              : (archive, description) async {
                  final client = auth.client;
                  if (client == null || client.session == null) {
                    throw StateError('signed out');
                  }
                  return client.submitReport(
                    archiveBase64: base64Encode(archive),
                    description: description,
                    pluginVersion: pluginVersion(plugin),
                    platform: platformTag,
                  );
                };
          // Hand the sink the salt now that a vault is known. Records buffered
          // during boot have not been formatted yet, so they get pseudonymised
          // too — that is the whole reason the sink holds records rather than
          // lines.
          session.logSink?.redactor = DiagnosticRedactor(salt: cfg.vaultId);

          // Everything a report needs that only this block knows. A closure
          // over the boot locals rather than a snapshot: the prefs below are
          // reassigned live from the settings tab, and a report is worth
          // having only if it describes the state the user is actually in.
          session.reportFacts = () {
            final stats = session.engine?.statsSnapshot();
            final scope = fileFilterPrefs.pathScope;
            // Folder filters are known to be paths, so they go through
            // redactPath directly. The text scanner would miss a top-level
            // folder like `Work` — it has neither a slash nor an extension to
            // recognise, and in free text that is indistinguishable from an
            // ordinary word.
            final paths = DiagnosticRedactor(salt: cfg.vaultId);
            String folders(Iterable<String> entries) =>
                entries.map(paths.redactPath).join(', ');
            return [
              if (!selfHostActive)
                BugReportSection.compact('Account', [
                  ('Signed in', auth.client?.email != null ? 'yes' : 'no'),
                  ('Email', auth.client?.email),
                  ('Plan', session.plans.current?.status.name),
                  (
                    'Plan ends',
                    session.plans.current?.periodEnd?.toUtc().toIso8601String(),
                  ),
                ]),
              BugReportSection.compact('Vault', [
                ('Name', cfg.vaultName),
                ('Vault id', cfg.vaultId),
                ('Device id', storedDeviceId),
                ('Encrypted', cipher != null ? 'yes' : 'no'),
                // User-supplied on self-host — their own machine, possibly
                // with a token in it. Only the shape is reported.
                ('Sync server', paths.redactUrl(syncServerUrl)),
                ('Database', dbName),
              ]),
              BugReportSection.compact('Sync state', [
                ('Engine', session.engine != null ? 'built' : 'absent'),
                ('Paused by user', session.syncPaused ? 'yes' : 'no'),
                // A stopped engine has no store to read, and a report is
                // written about a stopped engine almost by definition — one
                // arrived with this whole section blank. It now carries the
                // last numbers it had, and says when they were true rather
                // than passing them off as current.
                ('Numbers as of', stats?.capturedAt?.toUtc().toIso8601String()),
                ('Files', stats?.totalFiles.toString()),
                ('Tombstones', stats?.tombstones.toString()),
                ('Conflicting', stats?.conflicting.toString()),
                ('Unique blobs', stats?.uniqueBlobs.toString()),
                (
                  'Total size',
                  stats == null ? null : formatBytes(stats.totalSizeBytes),
                ),
                ('Server cursor', stats?.serverCursor.toString()),
                ('Server epoch', stats?.serverEpoch?.toString()),
              ]),
              BugReportSection.compact('Settings', [
                ('Settings sync', settingsPrefs.enabled ? 'on' : 'off'),
                (
                  'Synced categories',
                  settingsPrefs.enabled
                      ? settingsPrefs.categories.map((c) => c.name).join(', ')
                      : null,
                ),
                (
                  'Excluded extensions',
                  fileFilterPrefs.excludedExtensions.join(', '),
                ),
                ('Sync only paths', folders(scope.include)),
                ('Excluded paths', folders(scope.exclude)),
                ('Remote diagnostics', diagnosticsPrefs.enabled ? 'on' : 'off'),
              ]),
            ];
          };

          // (Re)binds `.obsidian` settings sync to the engine's CURRENT
          // endpoint. Every engine restart invalidates the old one, so any
          // path that restarts must call this or settings sync silently stops.
          Future<void> relaunchConfigSync() async {
            if (cipher == null) return;
            await _launchConfigSync(
              session: session,
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
            await _scheduleBoot(session, (token) async {
              await engine.stop();
              await _guardedStart(session, engine, token);
            });
            await relaunchConfigSync();
            // A sign-in that can't start the engine yet (no vault picked) emits
            // no engine events, so the panel would keep showing "not signed in"
            // until its 30s tick.
            session.panel?.refresh();
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
              await _rememberPlan(session, sub, configStorage);
            } catch (e) {
              // Keep whatever we already know — the cached answer loaded at
              // boot, or a fresher one from earlier this session. Overwriting
              // it with null is what made a slow network look like a downgrade.
              _log.info(
                'Subscription lookup failed, using last known plan '
                '(${session.plans.capabilities?.toString() ?? "none cached"}): $e',
              );
            }
            _refreshPlanNotice(session);
            await _scheduleBoot(
              session,
              (token) => _guardedStart(session, engine, token),
            );
            await relaunchConfigSync();
            await _adoptDeviceId(engine, configStorage);
          }

          // Single source of truth for the pause toggle — shared by the panel
          // Pause/Resume button and the "Pause sync"/"Resume sync" commands so
          // the two surfaces are the same action. Pausing persists + stops;
          // resuming persists + runs the full start session.
          Future<void> setSyncPaused(bool paused) async {
            session.syncPaused = paused;
            await configStorage.savePaused(paused);
            if (paused) {
              _cancelSelfHeal(session);
              session.stopConfigSync();
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
            _log.warning(
              'Session refused by the server — signing out: $reason',
            );
            auth.bindAccount(null);
            _applyAuth(engine, auth, buildConfig);
            unawaited(
              configStorage.clearAuthSession().catchError(
                (Object e) => _log.warning('Clearing session failed: $e'),
              ),
            );
            // Stop rather than let the reconnect ladder grind: nothing it can
            // do will authenticate, and every retry costs a full refresh
            // round-trip before failing.
            _cancelSelfHeal(session);
            session.stopConfigSync();
            unawaited(_scheduleBoot(session, (_) => engine.stop()));
            // The settings tab rebuilds on every open and reads auth live, so
            // it needs no nudge — the panel is the one holding a stale render.
            session.panel?.refresh();
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
              // Self-host has no account: a URL and a token are all it needs,
              // and `selfHostActive` already means it has both.
            } else if (booted.selfHostEnabled) {
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
            // Last, because everything above is a reason we could not even try.
            // This one means we tried and the storage said no.
            if (session.recovery.storageRefused)
              return SyncStartBlock.storageRefused;
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
            final host = Uri.tryParse(booted.selfHostUrl)?.host;
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
          //
          // Belt and braces. This block runs once per session object, so there
          // is nothing here to drop — it used to read the global slot, where a
          // reload really could leave the previous load's panel. Kept because
          // a null check costs nothing and a second panel costs the user a
          // duplicate sidebar entry. (registerView itself is idempotent.)
          session.panel?.dispose();
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
            isPaused: () => session.syncPaused,
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
            // Null while settings sync is still coming up, so the tile can
            // say "still asking" rather than "switched off" — they look the
            // same and only one of them is worth acting on.
            onSettingsCategories: () => session.configSync?.enabledCategoryCount,
            onPluginSyncEnabled: () => session.configSync?.pluginCodeEnabled,
            // Read live rather than remembered from a push, so a panel opened
            // mid-sync starts with the truth instead of with false.
            onSettingsBusy: () =>
                session.configSync?.hasOutstandingWork ?? false,
            onPluginStats: () async {
              // Null means "cannot answer yet", and ONLY that. An empty
              // overview is an answer — no plugins are synced — and folding
              // the two together is what made the tile show a dash for the
              // first seconds and the real figure eight seconds later: the
              // panel took "not ready" for "nothing here" and stopped
              // treating itself as loading.
              final o = await session.configSync?.pluginOverview();
              return o == null ? null : (count: o.count, bytes: o.totalBytes);
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
            // The panel cannot reach the database — the handle does not leave
            // GatedDatabase — so the numbers and the action are handed in.
            onDatabaseStats: () async => session.db?.stats(),
            onCompactDatabase: () => _compactDatabase(session),
            onStorageDetails: () => _showStorageOverview(
              session,
              plugin,
              engine,
              fetchUsage: (selfHostActive || byo)
                  ? null
                  : () => _fetchVaultUsage(engine, vaultId),
            ),
            // Self-host has no account to renew, so the strip has no button
            // there — and no plan alert ever reaches it either.
            onPlanAction: selfHostActive || kEnv.siteUrl.isEmpty
                ? null
                : _openSubscriptionPage,
          )..register();
          session.panel = syncPanel;
          // The panel is built after the boot lookup may already have run.
          syncPanel.setPlanNotice(session.plans.notice);

          // Single indicator, surface picks itself by platform:
          // status bar on desktop, floating pill on mobile. Tap reveals
          // the docked panel.
          session.indicator = SyncStatusIndicator(
            plugin: plugin,
            // No engine: this surface does not listen to it. The model folds
            // the stream once and this repaints when told. A constructor that
            // still took the engine would invite a second subscription, which
            // is exactly how the dot came to sit stale.
            logger: _logController.scope('plugin'),
            onTap: () => unawaited(syncPanel.reveal()),
            // In offline/error/auth-expired the tap forces a recovery instead of
            // just opening the panel (see recover assignment below).
            onReconnect: () => unawaited(recover?.call(requireVisible: false)),
            // Not "the same source as the panel" any more — the same OBJECT.
            // They used to fold the same events into two states and combine
            // them differently, so with no network the panel said "not
            // connected" while the dot beside it was green.
            status: syncPanel.status,
          )..init();

          // The settings notify subscription is an in-flight call too, so it
          // dies on a transport reconnect. The engine emits SyncConnected on
          // every (re)connect; reissue the config notify + catch-up pull. The
          // first SyncConnected fires before config sync is launched, so the
          // null-guard makes it a no-op then and a real reissue on reconnects.
          session.configReconnectSub = engine.events.listen((e) {
            if (e is SyncConnected) session.configSync?.handleReconnect();
          });

          // The sync database was there yesterday and is gone today (evicted
          // WebView storage is the usual reason on mobile). The engine restores
          // itself, but the user sees the whole vault download again and, if a
          // delete made here never reached the server, that file back on disk.
          // Tell them what happened instead of leaving it as a mystery.
          session.stateLostSub = engine.events.listen((e) {
            if (e is! SyncLocalStateLost) return;
            _log.warning('Local sync state lost — device ${e.deviceId}');
            showNotice(S.localStateLostNotice);
          });

          // Durability barriers at the engine's convergence points, so an
          // abrupt kill costs at most the last few seconds of sync rather than
          // everything since the last clean unload. Which events qualify is a
          // rule that has been wrong twice — see [isDurabilityBarrier], where
          // it is written down and tested.
          //
          // The barriers on `pagehide`/`visibilitychange` do not make these
          // optional. They are `unawaited` and cannot hold the WebView open, so
          // a queue holding a whole pull has no chance of draining there. A
          // barrier is only as good as how little it has left to do.
          session.flushSub = engine.events.listen((e) {
            if (isDurabilityBarrier(e)) unawaited(_flushDb(session));
          });

          // Permanent-delete propagation. When another device permanently
          // deletes the vault this device is connected to, its registry entry
          // comes back tombstoned (deletedAt set). On (re)connect, pull the
          // vault list and, if our vault is tombstoned, drop it locally:
          // disconnect + wipe local sync state. Files on disk are left
          // untouched (matches the initiating device). We act only on an
          // explicit tombstone, never on mere absence (which could be a
          // transient list failure or an access change).
          session.deletedVaultWatchSub = engine.events.listen((e) async {
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
            await _scheduleBoot(session, (_) async {
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
              await _scheduleBoot(session, (_) async {
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
                    : session.plans.capabilities?.maxVaultCount,
              ),
            );
            if (picked == null) return;
            _log.info('Vault connected: ${picked.$1.vaultId} — reloading');
            unawaited(reloadPlugin(plugin));
          };

          late final ({void Function() refresh, void Function() beginSignIn})
          settingsHandle;
          void refreshSettings() => settingsHandle.refresh();
          settingsHandle = _registerSettings(
            session: session,
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
            selfHostUrl: booted.selfHostUrl,
            onSettingsSyncChanged: (next) async {
              settingsPrefs = next;
              await configStorage.saveSettingsSync(next.toJson());
              if (cipher != null) {
                await _launchConfigSync(
                  session: session,
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
              session.diagnostics?.apply(next);
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
          // What is in the local database, written where it can be read.
          //
          // The file itself cannot be handed over: it lives in the WebView's
          // origin storage behind the IndexedDB VFS, cut into blocks no SQLite
          // tool will open, and it is measured in gigabytes. The question
          // people actually arrive with is not "give me the file" but "what is
          // taking up the space", and that is a report, not a copy.
          // Compaction, as a decision rather than a chore.
          //
          // Reclaiming the blob cache returns its pages to a freelist INSIDE
          // the file; the file itself keeps its size, and the IndexedDB VFS
          // charges the open for that size. One vault sat at 1462 MB with
          // 1349 MB of it empty and paid twenty-two seconds on every launch.
          // Only VACUUM gives those megabytes back, and it rewrites the whole
          // database to do it — too long, and too greedy with space, to be
          // anything but asked for.
          plugin.addCommand(
            id: 'rhyolite-sync-db-compact',
            name: S.cmdCompactDatabase,
            callback: () => _compactDatabase(session),
          );
          plugin.addCommand(
            id: 'rhyolite-sync-db-report',
            name: S.cmdDatabaseReport,
            callback: () => _writeDatabaseReport(session, plugin),
          );
          plugin.addCommand(
            id: 'rhyolite-sync-config-now',
            name: S.cmdSyncSettingsNow,
            callback: () async {
              final cs = session.configSync;
              if (cs == null) {
                _log.info('Settings sync is off');
                return;
              }
              await cs.sync();
              _log.info('Manual settings sync triggered');
            },
          );
          // Dev builds only: it walks every note in the vault and exists to
          // measure the frontmatter recogniser against Obsidian's own parser,
          // which is useless to anyone not working on that recogniser.
          if (kDebug) {
            plugin.addCommand(
              id: 'rhyolite-audit-frontmatter',
              // Obsidian prefixes every entry with the plugin's name, so one
              // here reads as "Rhyolite Sync: Rhyolite (dev): …".
              name: '(dev) audit frontmatter parsing',
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
          // Storage overview is a HUB: the orphan sweep, device management,
          // restore points, the cleanup and both database actions are each one
          // click inside it. They used to be palette entries as well, which is
          // how sixteen of them accumulated — the hub and its contents listed
          // side by side, six of the sixteen reachable two ways.
          //
          // The palette keeps verbs you would want without opening anything.
          // What it costs: someone who does not know device management lives
          // in the overview will not find it by typing. What it buys back is a
          // list short enough to read, and the overview names them next to the
          // numbers that explain why you would go there.
          plugin.addCommand(
            id: 'rhyolite-storage-overview',
            name: S.storageOverviewTitle,
            callback: () =>
                unawaited(_showStorageOverview(session, plugin, engine)),
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
                unawaited(reloadPlugin(plugin));
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

          if (session.syncPaused) {
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
                  session.panel?.refresh();
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
              // Every "don't even probe" refusal, in one testable place — see
              // [shouldAttemptRecovery] for what each one is defending. The
              // reasons live there rather than here because this closure
              // cannot be reached from a test and the rule needed to be.
              final visible =
                  documentJs == null ||
                  jsu.getProperty<String?>(documentJs, 'visibilityState') ==
                      'visible';
              if (!shouldAttemptRecovery(
                paused: session.syncPaused,
                blocked: currentStartBlock() != null,
                engineMissing: session.engine == null,
                bootRunningFor: session.engineBootRunningFor(DateTime.now()),
                alreadyRecovering: recoverInFlight,
                requireVisible: requireVisible,
                visible: visible,
              )) {
                return;
              }
              recoverInFlight = true;
              try {
                // A busy engine gets a longer deadline. Five seconds is
                // arbitrary, and on dart2js the probe queues behind the very
                // work it is probing — a startup pass chunking and encrypting
                // will spend that budget on its own backlog. The probe asks
                // whether the socket is alive, not whether it is quick, so
                // waiting longer costs nothing and removes most of the false
                // negatives that were tearing live engines down.
                final probeSw = Stopwatch()..start();
                final found = await session.engine!.probe(
                  timeout: probeTimeout(busy: session.recovery.engineBusy),
                );
                final ok = found == EngineProbe.alive;
                probeSw.stop();
                final quietFor = session.recovery.quietFor(DateTime.now());
                if (!ok) {
                  // Every input to the decision, because the old line said
                  // only that the probe failed — which is the one thing that
                  // does not distinguish a dead socket from a busy one.
                  _log.warning(
                    'Health check failed after ${probeSw.elapsedMilliseconds}ms '
                    '(trigger=${requireVisible ? 'visibility' : 'network/heal'}, '
                    'busy=${session.recovery.engineBusy}, '
                    'quiet for ${quietFor.inSeconds}s)',
                  );
                  var nudged = false;
                  var plan = planConnectionRecovery(
                    sinceLastEvent: quietFor,
                    busy: session.recovery.engineBusy,
                    engineStopped: found == EngineProbe.stopped,
                  );
                  if (plan == ConnectionRecovery.waitItIsAlive) {
                    // Restarting here would dispose the blob hub and abandon
                    // whatever the startup pass had uploaded. It is alive, so
                    // the probe lost to load, not to a dead socket.
                    _log.info(
                      'Engine is alive — not restarting it; the probe lost to '
                      'its own workload',
                    );
                    return;
                  }
                  if (plan == ConnectionRecovery.nudge) {
                    // The cheap repair first. A swapped socket leaves notify
                    // permanently silent while everything else works, and that
                    // is fixed by re-arming — at no cost to the pass.
                    _log.info(
                      'Engine is silent — re-arming before any restart',
                    );
                    nudged = true;
                    try {
                      await session.engine!.reissueNotify();
                      await session.engine!.triggerPull();
                      session.configSync?.handleReconnect();
                    } catch (e) {
                      _log.warning('Re-arm failed: $e');
                    }
                    final again = await session.engine!.probe(
                      timeout: probeTimeout(busy: session.recovery.engineBusy),
                    );
                    if (again == EngineProbe.alive) {
                      _log.info('Re-arm worked — no restart needed');
                      return;
                    }
                    plan = planConnectionRecovery(
                      sinceLastEvent: quietFor,
                      busy: session.recovery.engineBusy,
                      engineStopped: again == EngineProbe.stopped,
                      alreadyNudged: true,
                    );
                    if (plan != ConnectionRecovery.restart) return;
                  }
                  // Says which of the two ways we got here, because they are
                  // different faults and the line used to claim the second
                  // whatever happened. A `stopped` probe skips the nudge
                  // entirely, so "still unreachable after re-arming" was
                  // printed for an engine nothing had tried to re-arm — and
                  // that reading is what hid a restart loop in plain sight.
                  _log.warning(
                    nudged
                        ? 'Still unreachable after re-arming — restarting'
                        : 'Engine reports stopped — restarting',
                  );
                  try {
                    await _scheduleBoot(session, (token) async {
                      await session.engine!.stop();
                      await _guardedStart(session, session.engine!, token);
                    }, automatic: true);
                    if (cipher != null) {
                      await _launchConfigSync(
                        session: session,
                        engine: session.engine!,
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
                  await session.engine!.reissueNotify();
                  await session.engine!.triggerPull();
                  session.configSync?.handleReconnect();
                  await session.configSync?.sync();
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
            void scheduleHeal() {
              if (session.syncPaused ||
                  session.recovery.online ||
                  session.selfHealTimer != null) {
                return;
              }
              if (session.recovery.selfHealExhausted) {
                _log.warning(
                  'Self-heal gave up after '
                  '${RecoveryState.maxSelfHealAttempts} attempts — '
                  'tap the status dot or run "Reconnect now"',
                );
                return;
              }
              session.selfHealTimer = Timer(
                session.recovery.selfHealDelay,
                () async {
                  session.selfHealTimer = null;
                  if (session.syncPaused ||
                      session.recovery.online ||
                      session.engine == null) {
                    return;
                  }
                  final attempt = session.recovery.beginSelfHealAttempt();
                  _log.info('Self-heal attempt $attempt — recovering');
                  // requireVisible:false — the point is to recover with no user
                  // action. recoverConnection restarts the engine on failure;
                  // on success the connection watcher emits SyncConnected,
                  // which cancels and resets the ladder. Re-arm here to cover
                  // the failed-start case.
                  await recoverConnection(requireVisible: false);
                  if (!session.recovery.online &&
                      session.selfHealTimer == null) {
                    scheduleHeal();
                  }
                },
              );
            }

            session.selfHealSub?.cancel();
            session.selfHealSub = engine.events.listen((e) {
              // Every update the ladder makes to its own memory happens in
              // one fold — see [RecoveryState.observe]. What is left here is
              // the timer, which needs this closure's recoverConnection.
              switch (session.recovery.observe(e, DateTime.now())) {
                case RecoveryStep.connected:
                  _cancelSelfHeal(session);
                case RecoveryStep.disconnected:
                  scheduleHeal();
                case RecoveryStep.none:
                  break;
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
                    unawaited(_flushDb(session, immediate: true));
                  }
                  if (!visible && !session.syncPaused) {
                    // Best-effort, no delay: the WebView can suspend right after
                    // 'hidden' (mobile), so fire immediately. sync() is _busy-safe
                    // and a no-op when nothing changed (signature guard).
                    final cs = session.configSync;
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
                (JSAny? _) => unawaited(_flushDb(session, immediate: true)),
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
                  if (session.syncPaused) return;
                  Timer(const Duration(milliseconds: 400), () {
                    final cs = session.configSync;
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
          var autoSignInInFlight = false;
          session.authEventsSub = engine.events.listen((event) async {
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
                  await _scheduleBoot(session, (_) async {
                    await engine.stop();
                    await _guardedStart(session, engine);
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
                // The rebind budget is re-armed by RecoveryState.observe on
                // this same event; nothing to do here for it.
                // And bring settings sync back if it is not running. Every
                // path that restarts the engine is supposed to relaunch it,
                // but a restore restarts from INSIDE a pull, which no such
                // path covers — so settings sync stayed dead until the next
                // manual restart. Only when it is actually down: a live one
                // resolves the endpoint per call and needs nothing.
                // Not while a launch is already under way: SyncConnected
                // arrives DURING the ordinary startup, before that path has
                // reached its own relaunch, so an unguarded re-arm started
                // settings sync twice in the same second — two store loads and
                // two pulls for one session.
                if (session.configSync == null &&
                    !session.configSyncLaunching) {
                  unawaited(relaunchConfigSync());
                }
                return;
              case SubscriptionRequired():
                return;
              case SessionExpired():
                // Self-host has no account session — never prompt for sign-in.
                if (selfHostActive) return;
                break; // fall through to refresh handler below
              // Ownership, not authentication — and the prefix is the only
              // thing they share. A fresh token carries exactly the same
              // permissions, so refreshing cannot change this answer: it
              // restarts the engine, fails identically, and restarts again.
              //
              // A user's first sync spent minutes in that loop, alternating
              // "Auth rejected — attempting token refresh" with the identical
              // refusal, several restarts deep. Must be matched BEFORE the
              // `auth.` prefix below, which is what was swallowing it.
              case SyncServerRejected(:final code, :final message)
                  when code.startsWith('auth.') &&
                      !rejectionWarrantsRefresh(code):
                _log.warning(
                  'Sync paused — server refused and a refresh cannot help '
                  '($code): $message',
                );
                return;
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
            if (!session.recovery.claimAuthRefresh(DateTime.now())) return;

            final live = accountClient.session;
            final client = auth.client ?? accountClient;
            final tokenMissing = event is AuthTokenMissing;
            final plan = planAuthRecovery(
              tokenMissing: tokenMissing,
              sessionLive: live != null && !live.isExpired,
              sessionPresent: client.session != null,
              providerBound: auth.hasToken && auth.client != null,
              rebindBudgetLeft: session.recovery.rebindBudgetLeft,
            );

            // A live session with nothing attached to the wire is OUR failure,
            // not an expired token: the provider was unbound, or the socket
            // was opened before the sign-in and still authenticates as nobody.
            if (plan == AuthRecovery.rebind) {
              session.recovery.claimRebind();
              _log.warning('Auth rejected but session is live — rebinding');
              auth.bindAccount(accountClient);
              _applyAuth(engine, auth, buildConfig);
              await restartForAuth();
              _log.info('Auth rebound from live session — restarted');
              return;
            }

            _log.warning('Auth rejected — attempting token refresh');

            var refreshOutcome = RefreshOutcome.notAttempted;
            if (plan == AuthRecovery.refresh) {
              session.recovery.authRefreshInFlight = true;
              try {
                final session = await client.refreshSession();
                await configStorage.saveAuthSession(session);
                auth.bindAccount(client);
                _applyAuth(engine, auth, buildConfig);
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
                session.recovery.authRefreshInFlight = false;
              }
            }

            if (shouldClearStoredSession(
              tokenMissing: tokenMissing,
              refresh: refreshOutcome,
            )) {
              await configStorage.clearAuthSession();
              auth.bindAccount(null);
            }
            // Outside the branch: the config is rebuilt whether or not the
            // session was cleared, which is how it was before and is what the
            // recovery paths below expect to find.
            _applyAuth(engine, auth, buildConfig);

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
                  session.recovery.claimRebind()) {
                auth.bindAccount(client);
                _applyAuth(engine, auth, buildConfig);
                await restartForAuth();
                _log.info(
                  'Refresh inconclusive — session kept, provider '
                  'rebound',
                );
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
            if (autoSignInInFlight) return;
            autoSignInInFlight = true;
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
                  _applyAuth(engine, auth, buildConfig);
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
              autoSignInInFlight = false;
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
      // Take the load's session and clear the slot in one synchronous block,
      // before the first await. Obsidian does not await `onunload`, so a reload
      // can start the next load while this function is suspended — and after
      // resuming, the slot belongs to that one. Teardown would then dispose the
      // live objects and abandon this load's settings tab and status-bar item.
      //
      // One slot is the whole reason this is three lines instead of thirty, and
      // the reason it cannot fall out of date as things are added.
      final session = _session;
      _session = null;

      // The synchronous half of dispose() — UI detach, timers, the local log —
      // runs before its first await, which is what stops a racing reload from
      // stacking a second tab and a second sync circle on the user.
      await session?.dispose();
    },
  );
}

// Returns the `refresh` callback so the caller can re-render the settings tab
// in response to events that update vault config from outside the tab itself
// (notably ExternalBlobConfigDiscovered), plus `beginSignIn` so the sync panel
// can offer the same browser sign-in the tab does.
({void Function() refresh, void Function() beginSignIn}) _registerSettings({
  required PluginSession session,
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
      await _scheduleBoot(session, (_) async {
        await engine.stop();
        await _guardedStart(session, engine);
      });
    },
    onAuthChanged: (newAuthConfig, client) async {
      auth.bindAccount(client);
      // On the engine's LIVE config, not the registration-time snapshot —
      // that one predates the client name/version/kind the constructor added
      // and any vault edits made since.
      _applyAuth(engine, auth, buildConfig);
      // A sign-in that only updates config leaves the running connection
      // authenticating as nobody: the bearer interceptor is bound once per
      // connect. Reconnect, or the user stays "signed in" and unsynced.
      await restartForAuth();
      _log.info('Signed in — engine restarted');
    },
    onSignOut: () async {
      auth.bindAccount(null);
      _applyAuth(engine, auth, buildConfig);
      await _scheduleBoot(session, (_) => engine.stop());
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
      await _scheduleBoot(session, (_) async {
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
      unawaited(reloadPlugin(plugin));
    },
    onDeleteVault: onDeleteVault,
    onSubscribed: () => _waitForSubscriptionAndStart(
      session: session,
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
      // PROVE THE CREDENTIALS BEFORE SAVING THEM.
      //
      // Nothing exercised them here. A wrong password was accepted, written to
      // the E2EE server config — which every other device then adopts — and the
      // UI said "connected". The failure surfaced much later and somewhere
      // else: a background verify reporting `HTTP blob upload failed: 401`,
      // long after the settings screen had been closed.
      //
      // A round trip, not a reachability check: read-only credentials would
      // pass a probe that only lists, and then fail on the first real upload —
      // which is the same fault one step further away.
      await _probeExternalStorage(
        extConfig,
        cipher: c,
        vaultId: engine.config.vaultId,
      );

      final metaService = VaultMetaService(
        storage: store,
        vaultId: engine.config.vaultId,
        cipher: c,
      );
      await metaService.saveExternalBlobConfig(extConfig);
      // The probe above just proved these work, so whatever refused us before
      // is no longer the state of the world. Without clearing it the panel
      // would keep naming a precondition the user had already met.
      session.recovery.storageRefused = false;
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
      managedStorageQuotaBytes:
          session.plans.capabilities?.managedStorageQuotaBytes,
    ),
    pluginCodeSize: () {
      final bytes = session.pluginCodeLocalBytes;
      return bytes == null || bytes == 0 ? null : formatBytes(bytes);
    },
    planNotice: () => session.plans.notice,
    // This tab fetches its own subscription; route it through the host so the
    // lapse comparison, the persisted snapshot and the panel strip all move
    // together instead of the tab holding a private, fresher opinion.
    onSubscriptionFetched: (sub) async {
      await _rememberPlan(session, sub, configStorage);
      _refreshPlanNotice(session);
    },
    onShowStorageOverview: () => _showStorageOverview(
      session,
      plugin,
      engine,
      fetchUsage: (selfHostEnabled || engine.config.externalStorageKind != null)
          ? null
          : () => _fetchVaultUsage(engine, config.vaultId),
    ),
    diagnosticsPrefs: diagnosticsPrefs,
    onDiagnosticsChanged: onDiagnosticsChanged,
    // Same flow as the command palette entry, which stays the path that works
    // when boot never got far enough to build this tab.
    onCreateBugReport: () => showBugReportModal(
      plugin,
      buildReport: (description) =>
          _buildBugReport(session, plugin, description),
      openUrl: _openExternalUrl,
      supportUrl: kSupportUrl,
      submit: session.reportSubmitter,
      log: _logController.scope('report'),
    ),
    onClearLogs: () => _clearDiagnosticLogs(session),
    fileFilterPrefs: fileFilterPrefs,
    onFileFilterChanged: onFileFilterChanged,
    forcedBinaryExtensions: forcedBinaryExtensions,
    onForcedBinaryChanged: onForcedBinaryChanged,
    onResetSettings: () async {
      final cs = session.configSync;
      if (cs == null) {
        throw StateError('Settings sync is off.');
      }
      await cs.resetFromThisDevice();
      _log.info('Settings re-upload finished');
    },
    onRestoreSettings: () async {
      final cs = session.configSync;
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
  required PluginSession session,
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
      await _rememberPlan(session, subscription, configStorage);
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
    await _guardedStart(session, engine);
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
