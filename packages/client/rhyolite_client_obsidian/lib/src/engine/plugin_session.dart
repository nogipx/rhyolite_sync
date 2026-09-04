import 'dart:async';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../diagnostics/bug_report.dart';
import '../diagnostics/persistent_log_sink.dart';
import 'diagnostics_logging.dart';
import 'gated_database.dart';
import 'plan_tracker.dart';
import 'recovery_state.dart';
import 'session_contracts.dart';

/// Everything one plugin load owns, and the single act of giving it back.
///
/// This exists because of how it is torn down, not how it is built. Obsidian
/// does not await `onunload`, so a reload can start the next load while the
/// previous one is still suspended at an await — and top-level variables in
/// dart2js are one set of slots that both loads read. Teardown then disposes
/// the live objects and abandons the dead ones: a settings tab and a status-bar
/// circle with no owner, per reload, until the user has seven of each.
///
/// The fix is not care. It is arity. Twenty slots need a twenty-line prologue
/// that takes ownership and clears them before the first await, and that
/// prologue has to be extended by hand every time anything is added — the kind
/// of rule that is followed until it isn't. One slot holding one object needs
/// three lines that cannot go out of date, and [dispose] is where the order is
/// stated once.
///
/// The synchronous half of [dispose] runs before the first await, deliberately.
/// That is what stops a racing reload from stacking UI on the user; everything
/// after the first await is only resources.
class PluginSession {
  PluginSession({required this.logs});

  /// The plugin's log controller. Held because the session installs and removes
  /// log outputs, which is a property of the controller, not of a sink.
  final LogController logs;

  /// What this load knows about the user's plan.
  ///
  /// A sub-object rather than four more fields: these have rules between them
  /// (see [PlanTracker]) and a session that spread them out flat would be the
  /// same bag of globals with a dot in front of it.
  final PlanTracker plans = PlanTracker();

  /// What the recovery ladder has seen and spent this load.
  ///
  /// Also a sub-object, for the same reason: these fields are a fold over the
  /// engine's event sequence, not eight independent switches.
  final RecoveryState recovery = RecoveryState();

  // --- Mode ------------------------------------------------------------------

  /// Whether this load talks to a self-hosted server. Decided during boot from
  /// the stored config, and read from several call sites that no longer have
  /// the boot block's locals in scope.
  bool selfHost = false;

  /// User-requested sync pause, persisted in `data.json`.
  ///
  /// When true, every incidental start path is skipped — sync stays off until
  /// an explicit resume (the "Start Sync" command or the panel's Resume
  /// button), which is the only thing that clears it. Every non-explicit start
  /// consults it, or the flag desyncs from reality and the engine runs while
  /// the UI says paused.
  bool syncPaused = false;

  /// How many engine-lifecycle boots are in flight (scheduled or running).
  ///
  /// A restart is a stop followed by a start, and BETWEEN them the engine
  /// answers a probe with `stopped` — which the recovery planner treats as
  /// unconditional grounds for a restart, ahead of every liveness test. So a
  /// slow restart asks for another one, and the second lands on the first.
  /// That is what a user saw as sync starting over each time she came back to
  /// the window: a restart was still finishing, the probe returned `stopped`
  /// in 0 ms, and the pull it had going was torn down again.
  ///
  /// A counter rather than a flag because restarts nest — an explicit one may
  /// be scheduled while an automatic one runs, and a flag would be cleared by
  /// whichever finished first.
  int engineBootsInFlight = 0;

  /// When the OLDEST of them was decided on, so the guard can be bounded —
  /// see [shouldAttemptRecovery]. Set as the count leaves zero and cleared as
  /// it returns, so it measures the whole run of nested boots rather than the
  /// last one: a restart that keeps scheduling restarts is exactly the state
  /// the bound is there to escape.
  DateTime? engineBootStartedAt;

  bool get engineBootInFlight => engineBootsInFlight > 0;

  /// How long a boot has been in flight, or null if none is.
  Duration? engineBootRunningFor(DateTime now) {
    final since = engineBootStartedAt;
    if (since == null || engineBootsInFlight <= 0) return null;
    return now.difference(since);
  }

  /// True while a settings-sync launch is between its stop and its start.
  ///
  /// Only the AUTOMATIC re-arm consults it. An explicit relaunch — a restart, a
  /// storage change, a settings edit — must always win, because it is rebinding
  /// to something that changed; the re-arm only exists to revive a sync that
  /// nothing else will.
  bool configSyncLaunching = false;

  /// Tail of the settings-sync launch queue.
  ///
  /// Launches are serialised on it. They used to run side by side: two
  /// overlapping calls both passed [stopConfigSync] and both built an
  /// `ObsidianConfigSync`, the later one took this session's slot, and the
  /// earlier kept running unreferenced — subscribed to the same notify topic,
  /// scanning the same `.obsidian`. The logs showed it plainly: "Settings sync
  /// started" and the config subscription, twice, one second apart.
  ///
  /// [configSyncLaunching] was meant to prevent that and does, for exactly one
  /// caller — the automatic re-arm consults it. There are five callers.
  Future<void>? configSyncLaunch;

  /// Bytes the community plugins installed on THIS device occupy, measured on
  /// each settings-sync launch. Shown in the settings row so enabling
  /// plugin-code sync is a decision made with the number in hand. Null until
  /// first measured.
  int? pluginCodeLocalBytes;

  // --- Resources, in the order boot fills them ------------------------------

  /// The local log. Installed at the very top of `onLoad`, before anything that
  /// can fail, so a boot that dies still leaves something to read.
  PersistentLogSink? logSink;

  /// The sync database, as capabilities. The raw connection is deliberately
  /// unreachable from here — see [GatedDatabase].
  GatedDatabase? db;

  /// Manages the optional remote log sink. Off until the user opts in;
  /// installed during boot from the persisted `DiagnosticsPrefs` and re-applied
  /// live from the settings tab.
  DiagnosticsLogging? diagnostics;

  /// Plugin-owned task lane, injected into the engine so the engine's
  /// steady-state sync work (reconcile/pull/GC/settings) and the plugin's
  /// lifecycle work (boot/restart) share one serialized, connection-fair
  /// scheduler instead of racing the single WebSocket. Outlives every engine
  /// session within a load. See `[[engine_sync_scheduler_plan]]`.
  ///
  /// Typed by its contract rather than by [PriorityTaskScheduler]: nothing here
  /// depends on which implementation the boot chose.
  ITaskScheduler? scheduler;

  ISyncEngine? engine;
  SessionIndicator? indicator;
  SessionPanel? panel;

  /// `.obsidian` settings sync. Replaced wholesale on every relaunch, so it is
  /// held rather than owned once — see [stopConfigSync].
  SessionConfigSync? configSync;

  /// Self-host only: the socket the vault registry is reached over.
  ///
  /// Separate from the engine's own connection and outliving every engine
  /// session, because the directory and the meta store are bound to it once, at
  /// boot, and handed to the auth state. It was a boot-block local with the
  /// comment "kept alive" and nothing that ever closed it — kept alive past the
  /// load that opened it, which is the shape this object exists to remove.
  SyncConnection? registryConnection;

  // --- Subscriptions --------------------------------------------------------
  //
  // Each is held for exactly one reason: to be cancelled here. Without that a
  // soft reload leaks one listener per cycle, bound to an engine that is gone.

  /// Re-arms settings sync when the engine's connection comes back.
  StreamSubscription<SyncEngineEvent>? configReconnectSub;

  /// Auth and recovery: session-expiry re-auth, blob-config adopt, token
  /// refresh.
  StreamSubscription<SyncEngineEvent>? authEventsSub;

  /// Watches for the connected vault being permanently deleted on another
  /// device — its registry entry comes back tombstoned.
  StreamSubscription<SyncEngineEvent>? deletedVaultWatchSub;

  /// Watches for the local state having been lost under the engine.
  StreamSubscription<SyncEngineEvent>? stateLostSub;

  /// Drains pending writes to durable storage at convergence points.
  StreamSubscription<SyncEngineEvent>? flushSub;

  /// Drives the offline self-heal ladder: arms and cancels [selfHealTimer].
  StreamSubscription<SyncEngineEvent>? selfHealSub;

  // --- Timers ---------------------------------------------------------------
  //
  // Named rather than collected because each is replaced repeatedly during a
  // session; a list would only record the dead ones.

  /// Coalesces database flushes across a burst of convergence points.
  Timer? flushDebounce;

  /// Numbers the flushes in the log so a start can be paired with its finish.
  ///
  /// Per session rather than global, like everything else here: the numbers of
  /// a load that has ended mean nothing to the one that replaced it, and a
  /// counter that carried over would make two loads look like one.
  int flushSeq = 0;

  /// Coalesces the "settings changed — reload" prompt across a burst.
  Timer? settingsReloadDebounce;

  /// Periodic offline recovery. Armed when the engine reports it lost the
  /// backend (`SyncDisconnected`) and rpc_dart's own reconnect loop gave up;
  /// cancelled on `SyncConnected`. Recovery runs on a capped backoff so getting
  /// back online no longer depends on a DOM online/visibility event firing —
  /// those never fire when the OS network stayed up but the server or the token
  /// dropped.
  Timer? selfHealTimer;

  // --- Bug report ------------------------------------------------------------

  /// The parts of a report only the boot block knows: vault, account, filters.
  /// Absent before boot reaches the engine, and a report taken in that window
  /// is still worth having — a boot that never finished is exactly the sort of
  /// thing being reported.
  List<BugReportSection> Function()? reportFacts;

  /// Uploads a report archive, or null when there is nobody to upload to
  /// (self-host, or signed out). Then the archive stays a file to attach by
  /// hand, which is the path that worked before this existed.
  Future<String> Function(Uint8List archive, String description)?
  reportSubmitter;

  /// Salt for the report's path pseudonyms — the vaultId, so a name maps to the
  /// same pseudonym in every report from this vault and to nothing in any
  /// other. Empty before a vault is connected, when there are no paths to hide.
  String reportPathSalt = '';

  // --- Log --------------------------------------------------------------------

  /// Takes over [sink] and starts recording into it.
  ///
  /// Idempotent: a second call while a sink is live is a no-op rather than two
  /// outputs appending to one file. The caller builds the sink because doing so
  /// needs the Obsidian handle; what happens to it afterwards is this object's
  /// business — which is what keeps this file free of JS and therefore
  /// runnable in a test.
  bool attachLog(PersistentLogSink sink) {
    if (logSink != null) return false;
    logSink = sink;
    logs.addOutput(sink);
    return true;
  }

  // --- Teardown ---------------------------------------------------------------

  /// Stops the offline self-heal timer. The attempt counter lives with the
  /// recovery state that reads it, not here.
  void cancelSelfHealTimer() {
    selfHealTimer?.cancel();
    selfHealTimer = null;
  }

  /// Ends settings sync. Idempotent, and called before every relaunch — a
  /// launch that left the previous instance running would give two config syncs
  /// one keyspace.
  void stopConfigSync() {
    configSync?.dispose();
    configSync = null;
  }

  /// Gives everything back, in the one order that is safe.
  ///
  /// The synchronous half runs before the first await: UI is detached, timers
  /// are cancelled, the log is closed. Only then does the slow half start, and
  /// by then nothing this load owns is still attached to Obsidian.
  ///
  /// Idempotent — every field is cleared as it is taken, so a second call finds
  /// nothing to do.
  Future<void> dispose() async {
    // Detach the UI first and without yielding. This is what actually stops a
    // racing reload from stacking a second settings tab and a second sync
    // circle on the user.
    indicator?.dispose();
    indicator = null;
    panel?.closeLeaves();
    panel?.dispose();
    panel = null;

    // Close the remote log sink's WebSocket, if the user had it on.
    diagnostics?.dispose();
    diagnostics = null;

    // The local log goes with the load. Closing it here costs this teardown's
    // own log lines and buys never having two sinks appending to one file. The
    // report facts go with it — they close over this load's boot state.
    final sink = logSink;
    if (sink != null) {
      logs.removeOutput(sink);
      sink.dispose();
      logSink = null;
    }
    reportFacts = null;
    reportSubmitter = null;
    reportPathSalt = '';

    stopConfigSync();
    flushDebounce?.cancel();
    flushDebounce = null;
    settingsReloadDebounce?.cancel();
    settingsReloadDebounce = null;
    cancelSelfHealTimer();

    // Now the slow half. Subscriptions before the engine: a listener that
    // outlives its stream by even one event is a callback into a torn-down
    // graph.
    final subs = [
      configReconnectSub,
      authEventsSub,
      deletedVaultWatchSub,
      stateLostSub,
      flushSub,
      selfHealSub,
    ];
    configReconnectSub = null;
    authEventsSub = null;
    deletedVaultWatchSub = null;
    stateLostSub = null;
    flushSub = null;
    selfHealSub = null;
    for (final sub in subs) {
      await sub?.cancel();
    }

    final engineToStop = engine;
    engine = null;
    await engineToStop?.stop();

    final schedulerToStop = scheduler;
    scheduler = null;
    await schedulerToStop?.dispose();

    final registry = registryConnection;
    registryConnection = null;
    await registry?.dispose();

    final dbToClose = db;
    db = null;
    await dbToClose?.close();
  }
}
