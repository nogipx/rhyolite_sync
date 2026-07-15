import 'dart:async';

import 'package:convergent/convergent.dart';
import 'package:http/http.dart' as http;
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:uuid/uuid.dart';

import 'causal_stability_gc.dart';
import 'disk_reconciler.dart';
import 'remote_applier.dart';
import 'state_puller.dart';
import 'state_pusher.dart';
import 'path_normalize.dart';
import 'state_record_codec.dart';
import 'text_debounce_coordinator.dart';

/// Bundle passed to a custom resolver factory. Lets embedders construct
/// alternative [IStateConflictResolver] implementations without needing
/// to thread state through the constructor on each sync engine.
class ResolverContext {
  ResolverContext({
    required this.store,
    required this.blobStore,
    required this.vaultId,
    required this.nodeId,
    this.remoteBlobStorage,
    this.chunkedBlobIO,
    this.findHistoryBaseRef,
  });

  final FileStateStore store;
  final LocalBlobStore blobStore;
  final IBlobStorage? remoteBlobStorage;
  final ChunkedBlobIO? chunkedBlobIO;
  final String vaultId;
  final String nodeId;
  final Future<String?> Function(String fileId, Hlc beforeHlc)?
  findHistoryBaseRef;
}

/// State-based sync engine. Each file is one server record; no op log.
class StateSyncEngine implements ISyncEngine {
  StateSyncEngine({
    required this.vaultPath,
    required this.serverUrl,
    required this.config,
    this.cipher,
    required this.dataClient,
    required this.blobStore,
    required this.io,
    required this.changeProvider,
    this.metaStorage,
    this.httpClient,
    LogScope? logger,
    IStateConflictResolver Function(ResolverContext ctx)? resolverFactory,
    ServerRejectionFactory? rejectionFactory,
    SyncConnectionFactory? connectionFactory,
    RemoteBlobStorageBuilder? blobStorageBuilder,
    required ITaskScheduler scheduler,
    this.startupUploadConcurrency = 4,
    int? Function()? maxFileSizeBytes,
  }) : _scheduler = scheduler,
       _maxFileSizeBytes = maxFileSizeBytes ?? (() => null),
       _log = logger ?? LogScope.noop,
       _resolverFactory = resolverFactory,
       _rejections = ServerRejectionMapper(factory: rejectionFactory),
       _connectionFactory =
           connectionFactory ?? WebSocketSyncConnection.factory,
       _blobStorageBuilder =
           blobStorageBuilder ?? defaultRemoteBlobStorageBuilder;

  final String vaultPath;
  final String serverUrl;
  VaultConfig config;
  IVaultCipher? cipher;

  /// Number of files uploaded in parallel during `StartupDiff`. Lower
  /// values bound peak RAM (~`N × largest_file_bytes`) on memory-tight
  /// hosts like Obsidian on iOS/Android. Default tuned for desktop.
  final int startupUploadConcurrency;

  final IDataClient dataClient;
  final LocalBlobStore blobStore;
  final IPlatformIO io;
  final IChangeProvider changeProvider;

  /// Optional storage for the encrypted external blob config (see
  /// [VaultMetaService]). When null, the engine skips the
  /// fetch-from-server step on startup.
  IVaultMetaStorage? metaStorage;
  final http.Client? httpClient;
  final LogScope _log;
  final IStateConflictResolver Function(ResolverContext ctx)? _resolverFactory;
  final ServerRejectionMapper _rejections;
  final SyncConnectionFactory _connectionFactory;
  final RemoteBlobStorageBuilder _blobStorageBuilder;

  /// Current per-file upload size limit in bytes (null = unlimited). Threaded
  /// into the reconciler + startup diff so an over-limit file is never
  /// read/chunked/uploaded. The host provides it from the subscription's
  /// PlanCapabilities (managed) or leaves it null (self-host / BYO storage).
  final int? Function() _maxFileSizeBytes;

  /// Paths currently skipped for exceeding the size limit. Shared between the
  /// startup diff (seeds it) and the reconciler (clears it + emits
  /// [SyncFileSizeUnblocked] when a blocked path is deleted or shrinks). Lives
  /// for the engine's lifetime so the "too large" list stays consistent.
  final Set<String> _sizeBlockedPaths = {};

  FileStateStore? _store;
  FugueStore? _fugueStore;
  StatSigStore? _sigStore;
  DiskReconciler? _reconciler;
  StateRecordCodec? _recordCodec;
  StatePuller? _puller;
  StatePusher? _pusher;

  /// The session's RPC connection (transport + state/history callers).
  /// Built in [start], disposed in [stop]. Null before connect / after
  /// dispose; every method that talks to the server reads its callers
  /// through this and bails when it is null.
  SyncConnection? _conn;

  /// The live RPC endpoint, available after [start] has connected. Exposed so
  /// a sibling sync (e.g. settings on the `RhyoliteStateSync_config` service)
  /// can reuse the same authenticated WebSocket connection instead of opening
  /// a second one. Null before connect / after dispose.
  RpcCallerEndpoint? get endpoint => _conn?.endpoint;
  BlobTransferHub? _blobHub;
  NotifyCoordinator? _notifyCoordinator;

  /// Watches the reconnecting connection's state. The notify subscription is an
  /// in-flight server-stream; rpc_dart explicitly does NOT carry in-flight
  /// calls across a reconnect (its stream id belongs to the dropped transport),
  /// so it must be reissued once the state returns to online.
  StreamSubscription? _connSub;

  /// True once the connection has reached online at least once, so the first
  /// online (initial connect) is distinguished from a genuine reconnect.
  bool _wasOnline = false;
  StreamSubscription? _fileEventsSub;
  StreamSubscription? _typingSub;

  /// Serializes + prioritizes the engine's steady-state sync work onto one
  /// lane (single connection / single thread): file reconcile+push runs at
  /// [_pInteractive], pulls at [_pForeground]; housekeeping/settings can run
  /// at [_pBackground]. The [TextDebounceCoordinator] stays IN FRONT as the
  /// keystroke coalescer — it hands the scheduler an already-settled edit.
  ///
  /// The instance is OWNED BY THE HOST (constructor [scheduler]) so it outlives
  /// engine sessions: the host uses the same lane to sequence its own lifecycle
  /// work (boot/restart) above this engine's. The engine never creates or
  /// disposes it — [stop] cancels only this engine's [_schedulerGroup], leaving
  /// the shared instance and other owners' tasks untouched.
  final ITaskScheduler _scheduler;

  /// Tags every task this engine schedules, so [stop] can cancel exactly this
  /// engine's work on the shared scheduler without disturbing the host's
  /// lifecycle tasks or any sibling. Unique per engine instance.
  final Object _schedulerGroup = Object();

  /// While the user is actively typing, background work is gated out (see
  /// [_onTypingEvent]); this timer reopens the gate once typing stops.
  Timer? _userActiveTimer;

  /// Priority lanes for [_scheduler]. Higher runs first.
  static const int _pInteractive = 100; // user edits → reconcile + push
  static const int _pForeground = 50; //  pulls
  static const int _pBackground = 10; //  GC / verify / settings

  late final TextDebounceCoordinator _textDebounce = TextDebounceCoordinator(
    debounce: _textReconcileDebounce,
    onReconcile: _runDebouncedTextReconcile,
  );
  late final CausalStabilityGc _causalGc = CausalStabilityGc(
    vaultId: config.vaultId,
    getFugueStore: () => _fugueStore,
    getHistoryCaller: () => _conn?.historyCaller,
    onInfo: _log.info,
    onWarning: _log.warning,
  );
  bool _running = false;
  bool _epochRestoreInFlight = false;
  bool _repairInFlight = false;

  /// True while [start]'s pull / StartupDiff / verify pipeline runs. File
  /// change events that arrive during this window are queued in
  /// [_startupEventQueue] rather than processed, so they neither race with
  /// the startup mutations nor get lost. Drained by [_drainStartupQueue].
  bool _startupInProgress = false;
  final List<FileChangeEvent> _startupEventQueue = [];

  /// Deadline for top-level sync RPCs (push/pull). Sized for slow
  /// mobile networks while still being short enough that a silently-
  /// dead WebSocket surfaces as an error rather than hanging forever.
  /// On timeout the engine emits SyncError; the host plugin's
  /// resume-aware health check then drives an engine restart to
  /// rebuild the transport.
  static const Duration _rpcTimeout = Duration(seconds: 30);

  final _eventsController = StreamController<SyncEngineEvent>.broadcast();
  @override
  Stream<SyncEngineEvent> get events => _eventsController.stream;

  @override
  VaultStats? statsSnapshot() {
    final store = _store;
    if (store == null) return null;
    return VaultStatsUseCase(store).call();
  }

  @override
  List<ConflictedFile> conflictSnapshot() {
    final store = _store;
    if (store == null) return const [];
    return ConflictListUseCase(store).call();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  Future<void> start() async {
    if (config.vaultId.isEmpty || cipher == null) {
      _log.info('StateSyncEngine: not configured, skipping start');
      return;
    }
    await stop();
    _running = true;
    _emit(SyncStarted());

    try {
      _store = FileStateStore(client: dataClient, vaultId: config.vaultId);
      await _store!.load();
      // deviceId doubles as the HLC nodeId — every TaggedValue this device
      // emits is unambiguously attributable.
      final nodeId = _store!.deviceId;

      // Per-file Fugue sequences (text path). Binary files keep using the
      // state-based blob path; the store stays small in vaults without
      // any text edits.
      _fugueStore = FugueStore(client: dataClient, vaultId: config.vaultId);
      // Persistent per-file disk signatures — lets startup skip unchanged text
      // files and the reconciler short-circuit across plugin restarts.
      _sigStore = StatSigStore(client: dataClient, vaultId: config.vaultId);
      await _sigStore!.load();
      final swFugueLoad = Stopwatch()..start();
      await _fugueStore!.load();
      swFugueLoad.stop();
      final fugueStats = _fugueStore!.stats;
      _log.info(
        'FugueStore load: files=${fugueStats.files} '
        'cached=${fugueStats.cached} '
        'took=${swFugueLoad.elapsedMilliseconds}ms',
      );

      final conn = _connectionFactory(
        serverUrl: serverUrl,
        tokenProvider: config.tokenProvider,
        logger: _log,
      );
      _conn = conn;
      await conn.connect();

      _reconciler = DiskReconciler(
        vaultPath: vaultPath,
        vaultId: config.vaultId,
        io: io,
        blobStore: blobStore,
        changeProvider: changeProvider,
        store: _store!,
        fugueStore: _fugueStore!,
        chunkedIOBuilder: _newChunkedIO,
        knownChunks: _collectKnownChunks,
        fileIdFor: _deterministicFileId,
        emit: _emit,
        maxFileSizeBytes: _maxFileSizeBytes,
        sizeBlocked: _sizeBlockedPaths,
        sigStore: _sigStore,
        logger: _log,
      );

      _recordCodec = StateRecordCodec(cipher: cipher!);
      final applier = RemoteApplier(
        store: _store!,
        fugueStore: _fugueStore!,
        reconciler: _reconciler!,
        codec: _recordCodec!,
        blobStore: blobStore,
        io: io,
        changeProvider: changeProvider,
        vaultId: config.vaultId,
        vaultPath: vaultPath,
        newChunkedIO: _newChunkedIO,
        collectKnownChunks: _collectKnownChunks,
        emit: _emit,
        isFatalRejection: _rejections.isFatal,
        log: _log,
      );
      _puller = StatePuller(
        stateCaller: conn.stateCaller,
        historyCaller: conn.historyCaller,
        store: _store!,
        blobStore: blobStore,
        vaultId: config.vaultId,
        rpcTimeout: _rpcTimeout,
        getRemoteBlobStorage: _getRemoteBlobStorage,
        newResolver: _newResolver,
        applyFile: applier.apply,
        handleEpochMismatch: _handleEpochMismatch,
        emit: _emit,
        isFatalRejection: _rejections.isFatal,
        log: _log,
        clientName: () => config.clientName ?? '',
      );
      _pusher = StatePusher(
        stateCaller: conn.stateCaller,
        historyCaller: conn.historyCaller,
        store: _store!,
        codec: _recordCodec!,
        vaultId: config.vaultId,
        clientName: config.clientName,
        rpcTimeout: _rpcTimeout,
        emit: _emit,
        handleEpochMismatch: _handleEpochMismatch,
        clearPending: _clearPending,
        log: _log,
      );
      // Attach the file-change listener BEFORE the (potentially slow)
      // pull / StartupDiff / verify pipeline below, so a note edited DURING
      // startup isn't lost. The host change provider attaches its vault
      // listeners lazily on this first subscription (e.g.
      // ObsidianChangeProvider.onListen), so until now nothing was watching
      // the vault at all. Events are QUEUED while [_startupInProgress] (see
      // [_onFileEvent]) and processed by [_drainStartupQueue] once the
      // pipeline finishes — so they can't race with the pull / StartupDiff
      // that mutate the store, yet none are dropped. Engine's own writes
      // during the pull are still suppressed by the change provider, so the
      // queue only collects real user edits.
      _startupInProgress = true;
      _fileEventsSub = changeProvider.changes.listen(_onFileEvent);

      _emit(SyncConnecting(attempt: 1));

      // Discover server-side external blob config FIRST — before any
      // operation that touches blob storage. The whole point of this
      // discovery is "this user is on a BYO-storage tier; pick up the
      // S3/WebDAV creds the user already configured on another device,
      // so subsequent pull/push use the right backend." If we wait
      // until after _pull/_push (the old order), they will themselves
      // fail with `app_policy.feature.managed_storage_unavailable`
      // before discovery ever runs — and the plugin will sit forever
      // in "sync paused, server refused" without ever knowing the
      // user's BYO config was sitting on the server the whole time.
      //
      // The account-server RPC behind this check is independent of the
      // sync server's blob policy, so it works even when the user has
      // no managed-storage access at all.
      final swExt = Stopwatch()..start();
      await _checkExternalBlobConfig();
      swExt.stop();
      _log.info(
        'startup phase: external_blob_config '
        '${swExt.elapsedMilliseconds}ms',
      );
      if (!_running) return;

      // Initial pull: brings local in line with whatever the server knows.
      final swPull = Stopwatch()..start();
      await _pull();
      swPull.stop();
      _log.info(
        'startup phase: initial_pull '
        '${swPull.elapsedMilliseconds}ms',
      );
      if (!_running) return;

      // Disk reconciliation: detect new/modified files, upload their blobs.
      final uploadStart = Stopwatch();
      var lastTotal = 0;
      final diff = await StateStartupDiff(
        store: _store!,
        blobStore: blobStore,
        remoteBlobStorage: _getRemoteBlobStorage(),
        io: io,
        vaultPath: vaultPath,
        vaultId: config.vaultId,
        nodeId: nodeId,
        readClock: () => _store!.nextHlc(),
        writeClock: (_) {},
        logger: _log,
        sigStore: _sigStore,
        maxFileSizeBytes: _maxFileSizeBytes,
        uploadConcurrency: startupUploadConcurrency,
        // Same keyed scheme for BOTH the binary upload and its change
        // detection; otherwise stored (HMAC) chunk ids never match the
        // recomputed ones and every binary re-uploads (or never persists).
        blobIdKey: _resolveBlobIdKey(),
        // Route text files through the Fugue reconciler so startup uses the
        // same blob format as the runtime path. Without this, text was
        // re-uploaded as raw bytes every startup (disk sha never matches the
        // Fugue blob hash), bumping every text file's HLC and flooding
        // putStates — which starved the server's per-vault seq allocator.
        reconcileText: (relPath) => _reconciler!.reconcileWithDisk(relPath),
        onUploadProgress: (completed, total) {
          lastTotal = total;
          if (completed == 0) uploadStart.start();
          _emit(
            SyncStartupBlobUploadProgress(completed: completed, total: total),
          );
        },
      ).call();
      if (lastTotal > 0) {
        uploadStart.stop();
        _emit(
          SyncStartupBlobUploadDone(
            totalUploaded: lastTotal,
            elapsed: uploadStart.elapsed,
          ),
        );
      }
      _log.info(
        'Startup diff: ${diff.newFiles} new, ${diff.modifiedFiles} modified, ${diff.missingFileIds.length} missing',
      );

      // Surface files skipped for exceeding the size limit and seed the shared
      // blocked-set so the reconciler can later emit SyncFileSizeUnblocked when
      // one is deleted or shrinks. Re-emitted every startup → the UI's list is
      // rebuilt from truth rather than lost across restarts.
      for (final b in diff.blocked) {
        _sizeBlockedPaths.add(b.path);
        _emit(SyncFileSizeBlocked(
          path: b.path,
          sizeBytes: b.sizeBytes,
          limitBytes: b.limitBytes,
        ));
      }

      final swStartupPush = Stopwatch()..start();
      await _push();
      await _store!.persistMeta();
      swStartupPush.stop();
      _log.info(
        'startup phase: push+persist '
        '${swStartupPush.elapsedMilliseconds}ms',
      );

      _emit(SyncConnected());

      // Startup pipeline complete — process the file edits captured while it
      // ran. The change listener was attached before the pipeline; typing is
      // only subscribed now so the debounce coordinator doesn't schedule a
      // reconcile mid-startup.
      await _drainStartupQueue();

      // Housekeeping (local-blob GC + server blob-integrity verify) now runs
      // as low-priority BACKGROUND tasks rather than inline — off the startup
      // critical path (the user can edit sooner) and preemptible by user
      // edits, which yields the connection back to interactive sync.
      _scheduleHousekeeping();

      _typingSub = changeProvider.typing.listen(_onTypingEvent);
      _setupNotify();
      _watchConnection(conn);
      _log.info('StateSyncEngine started');
    } catch (e) {
      _log.error('StateSyncEngine start error: $e');
      final rejected = _rejections.fromException(e);
      _emit(rejected ?? SyncError(e.toString()));
      // Start is atomic: on ANY failure tear down fully so the engine
      // returns to a clean idle state. A partial start (e.g. connected +
      // store loaded, but notify / typing / reconnect-watch never wired) is
      // a zombie that healthCheck would still report as healthy — blocking
      // the host's health-gated restart and leaving sync silently dead.
      // The host decides how to surface the error (banner / re-auth modal /
      // "configure external storage") and when to retry start().
      await stop();
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    _startupInProgress = false;
    _startupEventQueue.clear();
    _pendingFileIds.clear();
    _lastEmittedHasPending = false;
    _wasOnline = false;
    await _connSub?.cancel();
    _connSub = null;
    await _notifyCoordinator?.stop();
    _notifyCoordinator = null;
    await _fileEventsSub?.cancel();
    _fileEventsSub = null;
    await _typingSub?.cancel();
    _typingSub = null;
    _blobHub?.dispose();
    _blobHub = null;
    await _conn?.dispose();
    _conn = null;
    _store = null;
    _fugueStore = null;
    _reconciler = null;
    _recordCodec = null;
    _puller = null;
    _pusher = null;
    // Drop cipher-derived session state so the next start() re-derives it
    // from the current cipher. Without this, swapping the cipher (vault
    // switch / passphrase change) and restarting reuses the OLD vault's
    // blob-id key, so recomputed blob ids diverge from what is stored.
    _blobIdKey = null;
    _blobIdKeyResolved = false;
    _textDebounce.cancelAll();
    _userActiveTimer?.cancel();
    _userActiveTimer = null;
    // The scheduler is host-owned and shared: drop only our work, and lift any
    // typing gate we set so the host's lifecycle lane isn't left paused behind
    // us. Never dispose it — the host does, on its own teardown.
    _scheduler.cancelGroup(_schedulerGroup);
    _scheduler.clearMinPriority();
    _emit(SyncStopped());
  }

  @override
  Future<bool> healthCheck({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_running) return false;
    final caller = _conn?.stateCaller;
    final store = _store;
    if (caller == null || store == null) return false;
    try {
      // sinceCursor = current cursor — the server returns an empty record
      // batch when there is nothing new, so this is the cheapest unary
      // we can issue without side effects. Awaiter-level timeout (not
      // RpcContext deadline) so the timer doesn't tick during the auth
      // interceptor's await on ensureValidToken().
      await caller
          .getStates(
            StateGetRequest(
              vaultId: config.vaultId,
              sinceCursor: store.serverCursor,
            ),
          )
          .timeout(timeout);
      return true;
    } catch (e) {
      _log.warning('healthCheck failed: $e');
      return false;
    }
  }

  @override
  Future<void> triggerPull() async {
    if (!_running) return;
    // Foreground task, coalesced by 'pull' — a burst of notifies collapses to
    // one pull, and it is serialized behind any interactive reconcile/push.
    //
    // PREEMPTIBLE: an interactive reconcile+push ([_pInteractive]) can signal
    // this task's token while the pull runs, so a slow or wedged blob download
    // no longer starves the user's own push on the single sync lane (the
    // freeze this fixes). The scheduler token is bridged to an
    // [RpcCancellationToken]/[RpcContext] threaded through the puller into every
    // blob download; on preemption the pull unwinds ([RpcCancelledException])
    // and we re-schedule it to finish once interactive work clears — mirroring
    // [_scheduleBackground]. Re-scheduling is fire-and-forget: awaiting it here
    // would hold the lane and deadlock the very push we yielded for.
    await _scheduler.schedule(
      key: 'pull',
      group: _schedulerGroup,
      priority: _pForeground,
      preemptible: true,
      run: (token) async {
        if (!_running) return;
        final rpcToken = RpcCancellationToken();
        unawaited(
          token.onCancel.then((_) {
            if (!rpcToken.isCancelled) {
              rpcToken.cancel('pull preempted by interactive work');
            }
          }),
        );
        final context = RpcContext.withCancellation(rpcToken);
        try {
          await _pull(context: context);
          await _store?.persistMeta();
          // Causal-stability GC piggybacks on pull cadence; it self-throttles.
          await _causalGc.run();
        } on RpcCancelledException catch (_) {
          _log.info('Pull preempted by interactive work — re-scheduling');
          if (_running) unawaited(triggerPull());
        } catch (e) {
          _log.warning('Pull error: $e');
        }
      },
    );
  }

  @override
  Future<void> triggerReset() async {
    if (!_running) return;
    _log.info('Reset: wiping server and re-uploading from this device');

    final caller = _conn?.stateCaller;
    if (caller != null) {
      try {
        await caller.wipeVault(
          StateWipeRequest(
            vaultId: config.vaultId,
            sourceClientId: config.clientName,
          ),
        );
        _log.info('Reset: server vault wiped');
      } catch (e) {
        _log.error('Reset: server wipe failed: $e');
        _emit(SyncError('Reset failed: server wipe error: $e'));
        return;
      }
    }

    await stop();
    await _store?.wipeAll();
    await _fugueStore?.wipeAll();
    await _sigStore?.wipeAll();
    // Re-open stores with fresh state so wipeAll persists.
    await FileStateStore(client: dataClient, vaultId: config.vaultId).wipeAll();
    await FugueStore(client: dataClient, vaultId: config.vaultId).wipeAll();
    await StatSigStore(client: dataClient, vaultId: config.vaultId).wipeAll();
    // Drop the local blob cache too. Server's blob collection was wiped
    // above (state_sync_responder.wipeVault), so any cached blob is now
    // referenced by nothing and would either accumulate as garbage or
    // mask a "fresh download" expectation (the prefetch progress bar
    // would never appear because every blobRef would cache-hit). After
    // start() the StartupDiff re-uploads from disk; new sha256-keyed
    // blobs will be written into a clean cache.
    try {
      await blobStore.wipeAll(vaultId: config.vaultId);
    } catch (e) {
      // Non-fatal: stale entries are harmless (sha256-addressed) — they
      // just waste disk. Log and continue.
      _log.warning('Reset: local blob cache wipe failed: $e');
    }
    await start();
  }

  @override
  Future<void> wipeLocalState() async {
    final vaultId = config.vaultId;
    _log.info('wipeLocalState: wiping local data for vaultId=$vaultId');
    await FileStateStore(client: dataClient, vaultId: vaultId).wipeAll();
    await FugueStore(client: dataClient, vaultId: vaultId).wipeAll();
    await StatSigStore(client: dataClient, vaultId: vaultId).wipeAll();
    try {
      await blobStore.wipeAll(vaultId: vaultId);
    } catch (e) {
      // Non-fatal: stale blobs are sha256-keyed and won't conflict; they
      // just waste disk until next GC pass.
      _log.warning('wipeLocalState: blob cache wipe failed: $e');
    }
  }

  @override
  Future<void> triggerRestoreFromServer() async {
    if (!_running) return;
    _log.info('Restore: downloading from server');
    await stop();
    await FileStateStore(client: dataClient, vaultId: config.vaultId).wipeAll();
    await FugueStore(client: dataClient, vaultId: config.vaultId).wipeAll();
    await StatSigStore(client: dataClient, vaultId: config.vaultId).wipeAll();
    // Drop the local blob cache too. Restore is semantically "fresh
    // download from server"; keeping the cache would mask a corrupted
    // blob (the obvious reason a user clicks Restore in the first
    // place) and would hide the prefetch progress bar via universal
    // cache-hits. Trade-off: every blob is re-downloaded even when
    // server-side bytes are identical to the cache.
    try {
      await blobStore.wipeAll(vaultId: config.vaultId);
    } catch (e) {
      _log.warning('Restore: local blob cache wipe failed: $e');
    }

    // Delete local files so they don't shadow what server tells us.
    final allFiles = await io.listFiles(vaultPath);
    final failedDeletes = <String>[];
    for (final absPath in allFiles) {
      final rel = absPath.substring(vaultPath.length + 1);
      if (rel.split('/').any((s) => s.startsWith('.'))) continue;
      try {
        changeProvider.suppress(rel);
        await io.deleteFile(absPath);
      } catch (e) {
        // A file we can't delete stays and shadows the server copy — the
        // exact corruption the user clicked Restore to fix. Never swallow
        // this: collect and surface it.
        _log.warning('Restore: failed to delete local file $rel: $e');
        failedDeletes.add(rel);
      }
    }
    if (failedDeletes.isNotEmpty) {
      _emit(
        SyncError(
          'Restore could not remove ${failedDeletes.length} local file(s) '
          'that may still shadow the server copy: '
          '${failedDeletes.take(5).join(', ')}'
          '${failedDeletes.length > 5 ? ', …' : ''}',
        ),
      );
    }
    await start();
  }

  @override
  Future<void> triggerRepair() async {
    if (!_running) return;
    final store = _store;
    final fugueStore = _fugueStore;
    if (store == null || fugueStore == null) return;
    if (_repairInFlight) {
      // Re-entrant click while the previous repair is still walking the
      // vault. Two concurrent reseed loops would race on the same
      // FugueStore and FileStateStore entries — better to ignore the
      // duplicate click outright. The UI will still show the original
      // run's progress.
      _log.info('Repair: already in progress, ignoring duplicate request');
      return;
    }
    _repairInFlight = true;

    _log.info('Repair: rebuilding text-file CRDT state from disk');
    try {
      final result = await RepairVaultUseCase(
        io: io,
        vaultPath: vaultPath,
        vaultId: config.vaultId,
        store: store,
        fugueStore: fugueStore,
        uploadSequenceBlob: _reconciler!.uploadSequenceBlob,
        emit: _emit,
        logWarning: _log.warning,
      )();
      _log.info(
        'Repair: ${result.repaired}/${result.total} files reseeded, '
        'failed=${result.failed}',
      );
      // Push the rebuilt state. Each file's HLC was bumped to dominate
      // any prior bloated record on the server.
      await _push();
      await store.persistMeta();
    } catch (e) {
      _log.warning('Repair failed: $e');
    } finally {
      _repairInFlight = false;
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _eventsController.close();
  }

  // ---------------------------------------------------------------------------
  // Pull
  // ---------------------------------------------------------------------------

  Future<void> _pull({RpcContext? context}) async {
    final puller = _puller;
    if (puller == null) return;
    await puller.pull(context: context);
  }

  // ---------------------------------------------------------------------------
  // Push
  // ---------------------------------------------------------------------------

  /// Push every dirty file as one Δ-state TaggedValue per file.
  ///
  /// No OCC, no retry loop (doc §5.1): each item carries the writer's
  /// HLC + CausalContext, and the server's MvRegister.join handles
  /// dominance. The only batch-level rejection is epoch mismatch.
  Future<void> _push({RpcContext? context}) async {
    final pusher = _pusher;
    if (pusher == null) return;
    await pusher.push(context: context);
  }

  /// FileIds whose latest local state hasn't yet been acknowledged by
  /// the server. Tracked incrementally — added on every mutation, dropped
  /// after a successful push — so the indicator doesn't have to scan
  /// the full FileStateStore on every keystroke.
  final Set<String> _pendingFileIds = {};
  bool _lastEmittedHasPending = false;

  void _markPending(String fileId) {
    if (!_running) return;
    final added = _pendingFileIds.add(fileId);
    if (added) _emitPendingIfChanged();
  }

  void _clearPending(Iterable<String> fileIds) {
    if (!_running) return;
    final before = _pendingFileIds.length;
    _pendingFileIds.removeAll(fileIds);
    if (_pendingFileIds.length != before) _emitPendingIfChanged();
  }

  void _emitPendingIfChanged() {
    final has = _pendingFileIds.isNotEmpty;
    if (has == _lastEmittedHasPending) return;
    _lastEmittedHasPending = has;
    _emit(SyncPending(hasPending: has));
  }

  // ---------------------------------------------------------------------------
  // File events
  // ---------------------------------------------------------------------------

  /// Processes the file edits captured by [_onFileEvent] while the startup
  /// pipeline ran. Reconciles each affected path IMMEDIATELY (not via the
  /// text debounce — these edits already settled during startup, they aren't
  /// a live keystroke burst) and pushes ONCE at the end, all still inside
  /// [start]. Because the host bootstrap runs `await engine.start()` and only
  /// then launches settings sync, draining synchronously here guarantees the
  /// user's notes are pushed BEFORE settings sync starts competing for the
  /// shared connection. (When the unified scheduler lands this becomes the
  /// startup phase's drain task — see [[engine_sync_scheduler_plan]].)
  Future<void> _drainStartupQueue() async {
    _startupInProgress = false;
    if (_startupEventQueue.isEmpty) return;
    final queued = List<FileChangeEvent>.of(_startupEventQueue);
    _startupEventQueue.clear();
    _log.info(
      'Draining ${queued.length} startup file event(s) (notes before settings)',
    );
    for (final event in queued) {
      try {
        switch (event) {
          case FileCreatedEvent(:final relativePath):
          case FileModifiedEvent(:final relativePath):
            final rel = normalizeVaultPath(relativePath);
            _textDebounce.forget(rel);
            await _onFileChanged(rel);
          case FileDeletedEvent(:final relativePath):
            final rel = normalizeVaultPath(relativePath);
            _textDebounce.forget(rel);
            _reconciler?.forgetStat(rel);
            await _onFileDeleted(rel);
          case FileMovedEvent(:final fromPath, :final toPath):
            final from = normalizeVaultPath(fromPath);
            final to = normalizeVaultPath(toPath);
            _textDebounce.forget(from);
            _textDebounce.forget(to);
            _reconciler?.forgetStat(from);
            _reconciler?.forgetStat(to);
            await _onFileDeleted(from);
            await _onFileChanged(to);
        }
      } catch (e) {
        _log.warning('Startup drain failed for $event: $e');
      }
    }
    await _push();
  }

  Future<void> _onFileEvent(FileChangeEvent event) async {
    if (!_running) return;
    if (_store == null) return;
    if (_startupInProgress) {
      // Captured during the startup pipeline; processed by
      // [_drainStartupQueue] once it completes, so we neither lose the edit
      // nor race with the pull / StartupDiff that are mutating the store.
      _startupEventQueue.add(event);
      return;
    }
    switch (event) {
      case FileCreatedEvent(:final relativePath):
      case FileModifiedEvent(:final relativePath):
        // Text rides the debounce front-coalescer (Obsidian autosaves per
        // keystroke); it hands ONE settled edit to the scheduler. Amber shows
        // immediately; the reconcile clears it if the edit was a no-op.
        final rel = normalizeVaultPath(relativePath);
        if (const FileTypeDetector().isText(rel)) {
          _markPending(_deterministicFileId(rel));
          _textDebounce.onDiskEvent(rel);
          return;
        }
        _scheduleReconcile(rel);
      case FileDeletedEvent(:final relativePath):
        final rel = normalizeVaultPath(relativePath);
        _textDebounce.forget(rel);
        _reconciler?.forgetStat(rel);
        _scheduleReconcile(rel);
      case FileMovedEvent(:final fromPath, :final toPath):
        final from = normalizeVaultPath(fromPath);
        final to = normalizeVaultPath(toPath);
        _textDebounce.forget(from);
        _textDebounce.forget(to);
        _reconciler?.forgetStat(from);
        _reconciler?.forgetStat(to);
        _scheduleReconcile(from);
        _scheduleReconcile(to);
    }
  }

  /// Enqueues reconcile+push for [relPath] as an [_pInteractive] task,
  /// coalesced by fileId. A newer edit or a keystroke ([_onTypingEvent])
  /// supersedes an in-flight task for the same file via the scheduler's
  /// cancellation. Returns when the task has run.
  Future<void> _scheduleReconcile(String relPath) {
    if (!_running) return Future<void>.value();
    final fileId = _deterministicFileId(relPath);
    return _scheduler.schedule(
      key: fileId,
      group: _schedulerGroup,
      priority: _pInteractive,
      run: (token) => _runReconcilePush(relPath, fileId, token),
    );
  }

  /// The reconcile+push work unit, run by the scheduler. The scheduler's
  /// [TaskCancelToken] is bridged to an [RpcCancellationToken] so a supersede
  /// aborts the in-flight chunk upload / putStates. Cancellation between
  /// "wire send" and "local persist" leaves the dirty bit set — the next
  /// reconcile picks the work back up.
  Future<void> _runReconcilePush(
    String relPath,
    String fileId,
    TaskCancelToken token,
  ) async {
    if (!_running) return;
    final reconciler = _reconciler;
    if (reconciler == null) return;
    final rpcToken = RpcCancellationToken();
    unawaited(
      token.onCancel.then((_) {
        if (!rpcToken.isCancelled) rpcToken.cancel('superseded by newer edit');
      }),
    );
    final context = RpcContext.withCancellation(rpcToken);
    try {
      final changed = await reconciler.reconcileWithDisk(
        relPath,
        context: context,
      );
      if (changed) {
        _emit(SyncFileModified(relPath));
        _markPending(fileId);
        await _push(context: context);
      } else {
        _clearPending([fileId]);
      }
    } on RpcCancelledException catch (_) {
      _log.info('Reconcile/push superseded for $relPath');
    } on TimeoutException catch (e) {
      // Push hung — almost always a silently-dead WebSocket after a resume.
      // Surface as SyncError so the host's visibilitychange handler rebuilds
      // the engine on next focus.
      _log.warning('Reconcile/push timed out for $relPath: $e');
      _emit(SyncError('sync timed out — connection may be stale'));
    } catch (e) {
      _log.warning('Reconcile/push failed for $relPath: $e');
    }
  }

  /// Enqueues [run] as a low-priority, PREEMPTIBLE background task. When an
  /// interactive edit needs the connection, the scheduler signals the task's
  /// token; [run]'s RpcContext reflects that, and if it bails
  /// ([RpcCancelledException]) the task re-schedules itself to finish once
  /// interactive work clears.
  void _scheduleBackground(Object key, Future<void> Function(RpcContext) run) {
    if (!_running) return;
    _scheduler.schedule(
      key: key,
      group: _schedulerGroup,
      priority: _pBackground,
      preemptible: true,
      run: (token) async {
        if (!_running) return;
        final rpcToken = RpcCancellationToken();
        unawaited(
          token.onCancel.then((_) {
            if (!rpcToken.isCancelled) {
              rpcToken.cancel('preempted by interactive work');
            }
          }),
        );
        try {
          await run(RpcContext.withCancellation(rpcToken));
        } on RpcCancelledException catch (_) {
          if (_running) _scheduleBackground(key, run); // finish later
        } catch (e) {
          _log.warning('background task "$key" failed: $e');
        }
      },
    );
  }

  /// Runs [task] as a low-priority background unit on the engine's sync
  /// scheduler, so a sibling subsystem (e.g. the Obsidian settings sync)
  /// shares the same connection-fair lane: it is serialized behind, and
  /// yields to, interactive note sync, and is paused while the user is
  /// actively editing (the [_onTypingEvent] gate). Coalesced by [key] when
  /// given. Runs [task] directly when the engine is not started.
  ///
  /// Exposed so settings sync need not open a second connection or race the
  /// note engine for the shared one — see [[engine_sync_scheduler_plan]].
  Future<void> scheduleBackground(
    Future<void> Function() task, {
    Object? key,
  }) {
    // Before a session is up the engine connection isn't available; run the
    // sibling task directly so callers (e.g. settings sync) still proceed.
    if (!_running) return task();
    return _scheduler.schedule(
      key: key,
      group: _schedulerGroup,
      priority: _pBackground,
      run: (_) => task(),
    );
  }

  /// Local-blob GC + server blob-integrity verify, as background tasks (see
  /// [_scheduleBackground]). Verify heals orphans left by silently-lost chunk
  /// uploads; it is cooperative (checks the context token between batches).
  void _scheduleHousekeeping() {
    _scheduleBackground('local-blob-gc', (_) async {
      final store = _store;
      if (store == null) return;
      final gc = await LocalBlobGc(
        store: store,
        blobStore: blobStore,
        vaultId: config.vaultId,
      )();
      if (gc.deleted > 0) {
        _log.info('Local blob GC: scanned=${gc.scanned} deleted=${gc.deleted}');
      }
    });
    _scheduleBackground('verify-blobs', (ctx) async {
      final store = _store;
      final remote = _getRemoteBlobStorage();
      if (store == null || remote == null) return;
      final verify = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: blobStore,
        vaultId: config.vaultId,
        logger: _log,
      )(context: ctx);
      if (!verify.isClean) _log.info('Startup blob verify: $verify');
    });
  }

  /// Wait after the last typing keystroke OR the last disk modify
  /// event before pushing a text edit. Sized comfortably above
  /// Obsidian's autosave cadence so a single editing session pushes
  /// once at the end rather than on every intermediate save.
  static const Duration _textReconcileDebounce = Duration(seconds: 3);

  /// Per-keystroke handler from the change provider. Forwards the path
  /// to the debounce coordinator AND cancels the in-flight sync token,
  /// if any — so a typing burst aborts a still-running reconcile/push.
  void _onTypingEvent(String relPath) {
    _textDebounce.onTypingEvent(relPath);
    if (!_running) return;
    // Supersede an in-flight reconcile/push for this file — it acted on
    // now-stale text (scheduler aborts its RpcContext) — or drop the pending
    // one. The debounce will re-enqueue once the user pauses.
    _scheduler.cancel(_deterministicFileId(relPath));
    // Pause background work while the user is actively editing; reopen the
    // gate once typing stops for the debounce window.
    _scheduler.setMinPriority(_pInteractive);
    _userActiveTimer?.cancel();
    _userActiveTimer = Timer(
      _textReconcileDebounce,
      _scheduler.clearMinPriority,
    );
  }

  /// Callback fired by [_textDebounce] when a path's quiet period
  /// elapsed and a disk event was observed during the window. Creates a
  /// fresh [RpcCancellationToken] for this sync session; the typing
  /// handler can cancel it to abort reconcile + push mid-flight.
  ///
  /// Cancellation between "wire send" and "local persist" is the
  /// intended state — dirty bits stay set, the next debounced reconcile
  /// picks the work up with whatever the user's typed since.
  Future<void> _runDebouncedTextReconcile(String relPath) {
    // The debounce window elapsed with a disk event — hand the settled edit
    // to the scheduler. All the reconcile/push/cancellation logic lives in
    // [_runReconcilePush].
    return _scheduleReconcile(relPath);
  }

  Future<void> _onFileChanged(String relPath) async {
    final reconciler = _reconciler;
    if (reconciler == null) return;
    final changed = await reconciler.reconcileWithDisk(relPath);
    if (changed) {
      _emit(SyncFileModified(relPath));
      _markPending(_deterministicFileId(relPath));
    }
  }

  Future<void> _onFileDeleted(String relPath) async {
    await _reconciler?.reconcileWithDisk(relPath);
    _markPending(_deterministicFileId(relPath));
  }

  // ---------------------------------------------------------------------------
  // Epoch
  // ---------------------------------------------------------------------------

  Future<void> _handleEpochMismatch(int newEpoch) async {
    if (_epochRestoreInFlight) return;
    _epochRestoreInFlight = true;
    _emit(SyncVaultReset());
    // Restore is detached on purpose: it stop()s the scheduler group this
    // handler was invoked from (the pull task), so it cannot be awaited
    // inline without self-cancelling. But detached means its failure would
    // be an unobserved async error — and SyncVaultReset was already emitted,
    // so the UI would think the reset succeeded. Observe and surface it.
    Future<void>.microtask(() async {
      try {
        await triggerRestoreFromServer();
      } catch (e) {
        _log.error('Epoch restore failed: $e');
        _emit(SyncError('Vault reset/restore failed: $e'));
      } finally {
        _epochRestoreInFlight = false;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Notify
  // ---------------------------------------------------------------------------

  /// (Re)subscribes the notify stream on the current endpoint. Idempotent:
  /// stops any existing coordinator first, so it is safe to call again after a
  /// reconnect to reissue the subscription on the fresh transport.
  @override
  Future<void> reissueNotify() async {
    if (!_running) return;
    _setupNotify();
  }

  void _setupNotify() {
    final endpoint = _conn?.endpoint;
    if (endpoint == null) return;
    unawaited(_notifyCoordinator?.stop());
    _notifyCoordinator = NotifyCoordinator(
      endpoint: endpoint,
      topic: 'vault:${config.vaultId}',
      onNotify: (_) {
        _log.info('Notify received — triggering pull');
        triggerPull();
      },
      onWarning: _log.warning,
    )..start();
  }

  /// Reacts to transport reconnects. rpc_dart's reconnecting transport swaps the
  /// underlying socket but does NOT carry in-flight calls across the swap — the
  /// notify server-stream goes permanently silent (its old stream id never
  /// errors or completes). So on every return to online AFTER the initial
  /// connect, reissue the notify subscription on the fresh transport and pull to
  /// catch up on anything missed while offline.
  void _watchConnection(SyncConnection connection) {
    // We are confirmed online at setup time; the broadcast state stream only
    // delivers FUTURE transitions, so the next online we observe is a reconnect.
    _wasOnline = true;
    unawaited(_connSub?.cancel());
    _connSub = connection.stateChanges.listen((s) {
      if (!_running) return;
      switch (s) {
        case SyncConnState.connecting:
          _emit(SyncConnecting(attempt: 1));
        case SyncConnState.online:
          if (_wasOnline) {
            _log.info('Reconnected — reissuing notify + catch-up pull');
            _setupNotify();
            triggerPull();
          }
          _wasOnline = true;
          _emit(SyncConnected());
        case SyncConnState.offline:
          // Reconnect loop exhausted its attempts; the engine is offline until a
          // restart (plugin resume health-check / push-timeout SyncError).
          _emit(SyncDisconnected());
      }
    });
  }

  Future<void> _checkExternalBlobConfig() async {
    if (config.externalBlobConfig != null) return;
    final storage = metaStorage;
    if (storage == null) {
      // No meta storage means we can't ask the server whether the user
      // already configured external blob storage on another device. The
      // most common cause is that the engine was constructed before the
      // user signed in (or session refresh failed); the host must call
      // `engine.metaStorage = ...` whenever the auth client changes.
      _log.info(
        'External blob config check skipped: metaStorage is null. '
        'Has the auth client been wired to the engine since sign-in?',
      );
      return;
    }
    final c = cipher;
    if (c == null) {
      // VaultMetaService is now strict about requiring a cipher (the
      // external-storage credentials must never round-trip cleartext).
      // If the engine reaches this point without one, the user hasn't
      // unlocked the vault yet — the load will resume on the next
      // start() after passphrase entry.
      _log.info(
        'External blob config check skipped: cipher is null '
        '(vault not unlocked).',
      );
      return;
    }
    try {
      final metaService = VaultMetaService(
        storage: storage,
        vaultId: config.vaultId,
        cipher: c,
      );
      final remote = await metaService.loadExternalBlobConfig();
      if (remote != null) {
        const code = 'feature.external_blob_config_discovered';
        const msg = 'external blob config available on the server';
        final params = {'config': remote.toJson()};
        _emit(_rejections.build(code, msg, params));
      }
    } catch (e) {
      _log.warning('External blob config check failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Builds a [FileVersionViewer] for browsing and restoring per-file
  /// history. Returns null when the engine is not connected.
  FileVersionViewer? createFileVersionViewer() {
    final browser = createHistoryBrowser();
    final remote = _getRemoteBlobStorage();
    if (browser == null || remote == null) return null;
    return FileVersionViewer(
      browser: browser,
      // Assemble past versions through the chunk manifest (and, for text,
      // project the Fugue tree) — same path the runtime write uses.
      chunkedIOBuilder: _newChunkedIO,
      io: io,
      changeProvider: changeProvider,
      vaultPath: vaultPath,
      vaultId: config.vaultId,
    );
  }

  /// Builds a [HistoryBrowser] wired to the engine's current connection
  /// and cipher. UI calls this to display decrypted history entries.
  /// Returns null when the engine is not connected or the cipher is unset.
  HistoryBrowser? createHistoryBrowser() {
    final history = _conn?.historyCaller;
    final c = cipher;
    if (history == null || c == null) return null;
    return HistoryBrowser(
      historyCaller: history,
      cipher: c,
      vaultId: config.vaultId,
    );
  }

  /// Builds a [BlobJanitor] wired to the engine's current connection and
  /// stores. UI calls this when the user opens the storage-cleanup modal.
  /// Returns null when the engine is not connected.
  BlobJanitor? createBlobJanitor() {
    final history = _conn?.historyCaller;
    final remote = _getRemoteBlobStorage();
    final s = _store;
    if (history == null || remote == null || s == null) return null;
    final endpoint = _conn?.endpoint;
    return BlobJanitor(
      historyCaller: history,
      blobStorage: remote,
      store: s,
      vaultId: config.vaultId,
      maintenanceCaller:
          endpoint != null ? VaultMaintenanceContractCaller(endpoint) : null,
    );
  }

  /// Builds a [DeviceRegistryUseCase] wired to the current connection. UI
  /// calls this to list/forget devices. Null when not connected.
  DeviceRegistryUseCase? createDeviceRegistry() {
    final history = _conn?.historyCaller;
    final s = _store;
    if (history == null || s == null) return null;
    return DeviceRegistryUseCase(
      historyCaller: history,
      vaultId: config.vaultId,
      thisDeviceId: s.deviceId,
    );
  }

  IStateConflictResolver _newResolver() {
    final chunkedIO = _newChunkedIO();
    final factory = _resolverFactory;
    if (factory != null) {
      return factory(
        ResolverContext(
          store: _store!,
          blobStore: blobStore,
          remoteBlobStorage: _getRemoteBlobStorage(),
          chunkedBlobIO: chunkedIO,
          vaultId: config.vaultId,
          nodeId: _store!.deviceId,
          findHistoryBaseRef: _findHistoryBaseRef,
        ),
      );
    }
    return StateConflictResolver(
      store: _store!,
      blobStore: blobStore,
      remoteBlobStorage: _getRemoteBlobStorage(),
      chunkedBlobIO: chunkedIO,
      vaultId: config.vaultId,
      nodeId: _store!.deviceId,
      findHistoryBaseRef: _findHistoryBaseRef,
    );
  }

  /// Per-vault HMAC subkey for content-addressing blob ids. Derived once from
  /// the vault cipher; null when the cipher is a non-[VaultCipher] fake (tests)
  /// or absent, in which case blob ids fall back to a raw sha256.
  Uint8List? _blobIdKey;
  bool _blobIdKeyResolved = false;

  /// Resolves (and memoizes) the blob-id subkey from the vault cipher. Every
  /// blob-id producer (ChunkedBlobIO, StateStartupDiff change detection) must
  /// share this so stored and recomputed ids agree.
  Uint8List? _resolveBlobIdKey() {
    if (!_blobIdKeyResolved) {
      final c = cipher;
      _blobIdKey = c is VaultCipher ? c.deriveBlobIdKey() : null;
      _blobIdKeyResolved = true;
    }
    return _blobIdKey;
  }

  /// Builds a ChunkedBlobIO bound to the current remote storage. Returns
  /// null only when no remote storage is configured (offline-only run).
  ChunkedBlobIO? _newChunkedIO() {
    final remote = _getRemoteBlobStorage();
    if (remote == null) return null;
    return ChunkedBlobIO(
      blobStore: blobStore,
      remoteBlobStorage: remote,
      vaultId: config.vaultId,
      blobIdKey: _resolveBlobIdKey(),
    );
  }

  /// Aggregates every chunk hash referenced by some current file_state
  /// or lastSyncedBlobRef. This is the "server already has these"
  /// candidate set for the next upload.
  Set<String> _collectKnownChunks() {
    final store = _store;
    if (store == null) return const {};
    final known = <String>{};
    // Pull from every concurrent value across all registers — a chunk
    // referenced by any surviving TaggedValue is already on the server.
    for (final state in store.allValuesFlat) {
      known.addAll(state.chunks);
      if (state.chunks.isEmpty &&
          state.blobRef.isNotEmpty &&
          !state.tombstone) {
        known.add(state.blobRef);
      }
    }
    return known;
  }

  /// Looks up an ancestor blobRef via the history service, used by the
  /// conflict resolver when no local lastSyncedBlobRef is available
  /// (new device, restore from server, etc).
  ///
  /// Returns the newest history event's blobRef for [fileId] whose hlc
  /// is strictly less than [beforeHlc]. Null if no such event exists in
  /// the retention window.
  Future<String?> _findHistoryBaseRef(String fileId, Hlc beforeHlc) async {
    final history = _conn?.historyCaller;
    if (history == null) return null;
    try {
      final response = await history.getHistory(
        HistoryGetRequest(
          vaultId: config.vaultId,
          fileId: fileId,
          beforeHlcPacked: beforeHlc.pack(),
          limit: 1,
        ),
      );
      if (response.events.isEmpty) return null;
      final ref = response.events.first.blobRef;
      return ref.isEmpty ? null : ref;
    } catch (e) {
      _log.warning('history base lookup failed for $fileId: $e');
      return null;
    }
  }

  /// Returns the per-session [BlobTransferHub], building it lazily on
  /// first call after the connection is up. The hub is the single
  /// in-process choke point for blob IO: it dedups concurrent transfers
  /// of the same blob id, caps the number of inner calls in flight, and
  /// can be cancelled wholesale on `stop()` / `triggerReset()`.
  ///
  /// Returns null only when neither external blob config nor an active
  /// endpoint is available — i.e. the engine cannot reach any blob
  /// backend yet.
  IBlobStorage? _getRemoteBlobStorage() {
    final cached = _blobHub;
    if (cached != null) return cached;
    final inner = _buildInnerBlobStorage();
    if (inner == null) return null;
    final hub = BlobTransferHub(inner: inner);
    _blobHub = hub;
    return hub;
  }

  IBlobStorage? _buildInnerBlobStorage() => _blobStorageBuilder(
    config: config,
    cipher: cipher,
    httpClient: httpClient,
    endpoint: _conn?.endpoint,
  );

  String _deterministicFileId(String relPath) =>
      const Uuid().v5(config.vaultId, normalizeVaultPath(relPath));

  void _emit(SyncEngineEvent event) {
    if (!_eventsController.isClosed) _eventsController.add(event);
  }
}
