import 'dart:async';

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart'
    show
        LogPath,
        NotifyCoordinator,
        PluginDirManifest,
        SettingsSync,
        SettingsCrdtKind,
        TaskCancelController,
        TaskCancelToken,
        canonicalJsonBytes,
        jsonCanonicalEqual;
import 'package:rpc_dart/rpc_dart.dart';

import '../engine/session_contracts.dart';
import 'blob_dir_sync.dart';
import 'enabled_list_gating.dart';
import 'obsidian_settings_registry.dart';
import 'plugin_code_overview.dart';
import 'plugin_uninstall_detection.dart';

/// Platform glue that drives [SettingsSync] against the Obsidian `.obsidian`
/// config directory.
///
/// `.obsidian` emits no vault events and settings change rarely, so there is no
/// background polling timer (that would just spam the server). Local -> remote
/// sync runs at well-defined moments only: once (deferred) after [start], when
/// the user leaves or returns to Obsidian (the plugin wires visibility to
/// [sync]), when the settings dialog closes (the plugin wraps `app.setting`),
/// and on the manual "Sync settings now" command. The signature guard makes
/// these triggers a no-op when nothing actually changed.
///
/// Remote -> local is event-driven: a [NotifyCoordinator] on the config
/// keyspace topic (`vault:<vaultId>_config`) reacts to another device's push
/// with a pull-only [pullRemote] (no local scan — the remote changed, not us),
/// so a settings change on one device lands on the others within seconds
/// instead of only on the next resume.
///
/// Change detection and echo suppression both ride a persisted per-resource
/// source signature (`mtime:size`, opaque to [SettingsSync]): a scan only reads
/// and diffs files whose on-disk signature differs from the last sync, and a
/// pull-write records the new signature so it is not re-pushed. This keeps the
/// hot path off the file bytes entirely for the common "nothing changed" case.
class ObsidianConfigSync implements SessionConfigSync {
  ObsidianConfigSync({
    required AdapterHandle adapter,
    required SettingsSync sync,
    required Set<SettingsCategory> enabledCategories,
    Set<SettingsCategory> pullOnlyCategories = const {},
    Duration initialScanDelay = const Duration(seconds: 4),
    BlobDirSync? pluginCode,
    Future<int?> Function(List<String> blobIds)? releaseBlobs,

    /// The engine's CURRENT caller endpoint, resolved per use.
    ///
    /// Doubles as the connectivity check: null means the engine has no
    /// connection right now, and a scan that cannot reach the server is work
    /// nobody can use. Captured once, it went stale on every engine restart
    /// the plugin did not orchestrate — notably the re-upload and restore
    /// buttons, which stop and start the engine from inside — and the notify
    /// then retried a dead socket for the rest of the session.
    RpcCallerEndpoint? Function()? notifyEndpoint,
    String? notifyTopic,
    void Function(bool active)? onActivity,
    void Function()? onRemoteApplied,
    LogScope? log,
    Future<void> Function(
      Future<void> Function(TaskCancelToken token) task, {
      Object? key,
    })?
    runBackground,
  }) : _adapter = adapter,
       _sync = sync,
       _enabled = enabledCategories,
       _pullOnly = pullOnlyCategories,
       _initialScanDelay = initialScanDelay,
       _blobDirs = pluginCode,
       _releaseBlobs = releaseBlobs,
       _notifyEndpointOf = notifyEndpoint,
       _notifyTopic = notifyTopic,
       _onActivity = onActivity,
       _onRemoteApplied = onRemoteApplied,
       _log = log ?? LogScope.noop,
       _runBackground = runBackground;

  static const _configDir = '.obsidian';

  /// The list of enabled community plugins. Special-cased on both directions of
  /// the wire because it references plugins whose code arrives separately.
  static const _enabledListResource = 'community-plugins.json';

  /// Whole-file resources (themes, snippet CSS, plugin data.json) larger than
  /// this are NOT synced: the content is inlined and encrypted with a pure-Dart
  /// cipher on the single UI thread, so a multi-MB file freezes the app. Such
  /// files (themes especially) are reinstallable. Structured fieldMap/orSet
  /// settings are small and never hit this.
  static const _maxWholeFileBytes = 1 << 20; // 1 MiB

  final AdapterHandle _adapter;
  final SettingsSync _sync;
  final Set<SettingsCategory> _enabled;

  /// How many categories this vault syncs.
  ///
  /// The panel asks for coverage rather than bytes: "9 categories" answers
  /// what is being kept in step, where "156 KB" answers a question nobody has.
  int get enabledCategoryCount => _enabled.length;

  /// Whether plugin CODE is synced, as opposed to plugin settings.
  ///
  /// Its absence is how the feature is turned off — no dir sync is
  /// constructed — so this is the difference between "no plugins yet" and
  /// "plugins are not being synced", which a panel cannot tell from an empty
  /// overview.
  bool get pluginCodeEnabled => _blobDirs != null;

  /// Whether settings sync has work in flight or left over.
  ///
  /// Readable at any moment, which is the point. Pushing this to the surfaces
  /// on each transition left anything built afterwards holding the value it
  /// was born with: a panel reopened mid-sync showed "up to date" beside a dot
  /// that was still blue, because the transition it needed had happened before
  /// it existed.
  bool get hasOutstandingWork => _busy || _outstanding;

  /// Categories this device syncs DOWN but must not push up.
  ///
  /// The one producer is the plugin-code storage gate: a quota that is too
  /// small, or not known yet because the subscription lookup failed. Both mean
  /// "do not spend managed storage from here", which is a statement about
  /// uploads only — the bytes a pull brings down are already stored, and cost
  /// the quota nothing.
  ///
  /// Deliberately NOT expressed by dropping the category from [_enabled] or
  /// from the classifier the way it once was. That set is the sync scope: it
  /// decides which records the store keeps and is hashed into the cursor's
  /// scope token, so narrowing it purges the local CRDT state for those
  /// resources and invalidates the cursor. A transient `getSubscription`
  /// timeout then cost a full re-download of every plugin the moment the
  /// lookup succeeded again (measured: 21 plugins, 154 s). Scope follows the
  /// user's own toggles and nothing else; the gate lives here instead.
  final Set<SettingsCategory> _pullOnly;

  final Duration _initialScanDelay;

  /// Moves blob-backed directories — plugin code and themes — between disk and
  /// the vault's blob bucket. Null only when neither of their categories is on;
  /// those directories are then not enumerated at all. Which of the two kinds
  /// actually syncs is decided per resource by the enabled-category check, and
  /// which may be uploaded by [_pullOnly]. The storage gate does NOT null this:
  /// applying what the vault already holds must keep working.
  final BlobDirSync? _blobDirs;

  /// Asks the server to reclaim blobs a plugin update superseded. Returns how
  /// many it actually deleted, or null when unavailable. Null callback = no
  /// immediate reclaim; the full sweep still covers it.
  final Future<int?> Function(List<String> blobIds)? _releaseBlobs;
  final RpcCallerEndpoint? Function()? _notifyEndpointOf;
  final String? _notifyTopic;
  final void Function(bool active)? _onActivity;

  /// Fired after a pull that changed on-disk settings while Obsidian is already
  /// running (a notify push or a resume/manual sync — NOT the initial start
  /// pull, since a fresh app reads settings at launch). Obsidian doesn't
  /// hot-apply config files, so the host uses this to prompt a one-click reload.
  final void Function()? _onRemoteApplied;

  /// The same LogScope everything else uses, so a path here can be declared
  /// with [LogPath.config] instead of being interpolated into a string. The
  /// plain `void Function(String)` callback this replaced had no way to carry
  /// structured data, which put these files outside the redaction the rest of
  /// the plugin relies on.
  final LogScope _log;

  /// Routes connection-using settings work onto the note engine's
  /// connection-fair scheduler (low-priority background lane), so settings
  /// sync yields to interactive note sync and pauses while the user is
  /// actively editing. Null → run directly (no engine scheduler).
  final Future<void> Function(
    Future<void> Function(TaskCancelToken token) task, {
    Object? key,
  })?
  _runBackground;

  /// Cancel token of the background task currently running, if any. Read
  /// through [_cancelled] at every loop boundary so a pause stops this work
  /// instead of letting it hold the shared data client to completion.
  TaskCancelToken? _taskToken;

  NotifyCoordinator? _notify;
  bool _busy = false;

  /// A pass ended before it finished its work, so work remains.
  ///
  /// Settings run at background priority and are marked preemptible, which
  /// means the scheduler signals their token the moment anything above them
  /// wants the slot. The task returns early and its future completes
  /// NORMALLY — indistinguishable, to the caller, from having finished.
  ///
  /// Reporting that as "no longer active" is how the panel came to say
  /// "up to date" while settings files sat in the transfer queue. What the
  /// host is told now is whether WORK REMAINS, not whether a call is in
  /// flight, and this is the difference between the two.
  bool _outstanding = false;
  bool _disposed = false;

  /// The settings store has loaded, so [liveBlobIds] can answer truthfully.
  bool _ready = false;

  /// Plugin directories whose missing manifest was already re-captured in this
  /// session. Bounds the repair so a persistently unrepairable resource cannot
  /// turn every scan into a full re-upload.
  final Set<String> _repairedThisSession = {};

  /// Enabled-plugin ids deliberately kept out of the on-disk list because their
  /// code has not landed here yet. Merged back in before any local read of the
  /// list is diffed, so our own withholding is never mistaken for the user
  /// disabling those plugins. See [_withholdUninstalled].
  final Set<String> _withheldPluginIds = {};

  /// Runs [body] on the engine scheduler (background) when available, else
  /// directly. Keeps `.obsidian` sync off the connection while notes sync.
  Future<void> _bg(Object key, Future<void> Function() body) {
    Future<void> withToken(TaskCancelToken token) async {
      _taskToken = token;
      // Bridge to the RPC layer so a signal actually cuts a call already in
      // flight. Checking between resources is not enough: the pull that held
      // everything up was a SINGLE server call, and nothing between iterations
      // could reach it.
      final rpcToken = RpcCancellationToken();
      unawaited(
        token.onCancel.then((_) {
          if (!rpcToken.isCancelled) rpcToken.cancel('settings sync paused');
        }),
      );
      _sync.context = RpcContext.withCancellation(rpcToken);
      try {
        await body();
      } on RpcCancelledException {
        _log.warning('config: cancelled mid-call');
      } finally {
        if (identical(_taskToken, token)) {
          _taskToken = null;
          _sync.context = null;
        }
      }
    }

    final run = _runBackground;
    return run != null
        ? run(withToken, key: key)
        : withToken(TaskCancelController().token);
  }

  /// True once this work is no longer wanted — the plugin unloaded, or the
  /// user paused and the scheduler signalled our group.
  bool get _cancelled => _disposed || (_taskToken?.isCancelled ?? false);

  Future<void> start() async {
    // Initial pull only: getting remote settings onto disk is cheap and enough
    // to render them. The local scan (read + diff every file) is CPU-heavy and
    // would jank the UI while the notes engine is also starting, so defer it
    // off the app-open critical path.
    await _bg('settings:start', () async {
      final changed = await _sync.start();
      // The store is loaded from here on, so the local blob GC may consult us.
      _ready = true;
      final sw = Stopwatch()..start();
      await _writeChanged(changed);
      _log.info(
        'config start: writeChanged ${changed.length} '
        'in ${sw.elapsedMilliseconds}ms',
      );
    });
    Future<void>.delayed(_initialScanDelay, () {
      if (!_disposed) unawaited(sync());
    });

    _setupNotify();
  }

  /// Push local `.obsidian` changes then pull remote ones. Called (deferred) on
  /// start, on resume (return to Obsidian), and from the manual command.
  /// Reentrancy-safe: overlapping calls are dropped while one is in flight.
  @override
  Future<void> sync() async {
    if (_busy || _disposed) return;
    // Nothing to reach. Silent rather than an error: being offline is not a
    // fault, and this runs on every window switch.
    if (_notifyEndpointOf?.call() == null) return;
    _busy = true;
    _onActivity?.call(true);
    var remoteChanged = 0;
    var completed = false;
    try {
      await _bg('settings:sync', () async {
        await _scanAndPush();
        final changed = await _sync.pull();
        await _writeChanged(changed);
        remoteChanged = changed.length;
        completed = true;
      });
    } catch (e) {
      _log.warning('config sync error: $e');
    } finally {
      _busy = false;
      _outstanding = !completed && !_disposed;
      _onActivity?.call(_outstanding);
    }
    if (remoteChanged > 0) _onRemoteApplied?.call();
  }

  /// Pull-only: fetch remote changes and write them to disk, WITHOUT a local
  /// scan/push. This is the notify reaction — the remote changed, not us, so a
  /// full scan would be wasted work. Shares [_busy] with [sync] so a notify
  /// pull and a resume sync never overlap.
  Future<void> pullRemote() async {
    if (_busy || _disposed) return;
    if (_notifyEndpointOf?.call() == null) return;
    _busy = true;
    _onActivity?.call(true);
    var remoteChanged = 0;
    var completed = false;
    try {
      await _bg('settings:pull', () async {
        final changed = await _sync.pull();
        await _writeChanged(changed);
        remoteChanged = changed.length;
        completed = true;
      });
    } catch (e) {
      _log.warning('config notify pull error: $e');
    } finally {
      _busy = false;
      _outstanding = !completed && !_disposed;
      _onActivity?.call(_outstanding);
    }
    if (remoteChanged > 0) _onRemoteApplied?.call();
  }

  /// Re-upload: make THIS device authoritative — wipe the server settings
  /// keyspace + local store, then push every enabled `.obsidian` resource from
  /// disk. Other devices re-sync on their next pull/notify.
  @override
  Future<void> resetFromThisDevice() async {
    if (_disposed) return;
    _busy = true;
    _onActivity?.call(true);
    try {
      await _sync.wipeServerAndLocal();
      await _scanAndPush();
      // Runs outside the scheduler and cannot be preempted, so reaching here
      // really does mean nothing is left over from an earlier partial pass.
      _outstanding = false;
    } finally {
      _busy = false;
      _onActivity?.call(_outstanding);
    }
  }

  /// Download: discard local settings state and re-download everything from the
  /// server, overwriting the on-disk `.obsidian` files. Most settings apply
  /// after an Obsidian restart.
  @override
  Future<void> restoreFromServer() async {
    if (_disposed) return;
    _busy = true;
    _onActivity?.call(true);
    try {
      final changed = await _sync.restoreFromServer();
      await _writeChanged(changed);
      _outstanding = false;
    } finally {
      _busy = false;
      _onActivity?.call(_outstanding);
    }
  }

  /// After a transport reconnect the notify server-stream is dead (rpc_dart
  /// does not carry in-flight calls across the socket swap). Reissue the
  /// subscription on the fresh transport and pull to catch up on missed pushes.
  @override
  void handleReconnect() {
    if (_disposed) return;
    _setupNotify();
    unawaited(pullRemote());
  }

  /// (Re)subscribes the config-keyspace notify stream. Idempotent — stops any
  /// existing coordinator first, so it is safe to call again after a reconnect.
  void _setupNotify() {
    final topic = _notifyTopic;
    if (topic == null) return;
    unawaited(_notify?.stop());
    _notify = NotifyCoordinator(
      // Asked again on every attempt. Captured once, this kept resubscribing
      // to the connection that existed at setup — so after a transport swap
      // the config keyspace went deaf and stayed deaf, retrying a dead
      // endpoint until something outside happened to rebuild the coordinator.
      resolveEndpoint: () => _notifyEndpointOf?.call(),
      topic: topic,
      onNotify: (sourceClientId) {
        if (_disposed) return;
        // The server echoes our own pushes back on this topic. Ignore them —
        // otherwise every settings push (and every file of a re-upload)
        // self-notifies and pulls its own change back.
        if (sourceClientId != null && sourceClientId == _sync.clientId) return;
        _log.info('config notify received — pulling');
        unawaited(pullRemote());
      },
      onWarning: _log.warning,
      onInfo: _log.info,
    )..start();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_notify?.stop());
    _notify = null;
  }

  // -- local -> remote ------------------------------------------------------

  /// One scan, one push.
  ///
  /// Everything inside runs with pushes deferred, so N changed resources cost
  /// one `putStates` instead of N. That includes the removal detection at the
  /// end, which publishes tombstones through the same path.
  Future<void> _scanAndPush() => _sync.batched(_scanAndPushInner);

  Future<void> _scanAndPushInner() async {
    final candidates = await _enumerate();
    // Plugin-code sync is the one category whose absence from a scan is
    // invisible otherwise — every other resource shows up as a processed file.
    // Which is why the pause is named: a scan with no plugin dirs in it reads
    // identically to the feature being off, and the two need telling apart
    // from a log alone.
    if (_blobDirs != null) {
      final dirs = candidates.keys.where(_isPluginDir).length;
      final paused = _pullOnly.map((c) => c.name).join(',');
      _log.info(
        'config scan: $dirs plugin dir(s) of '
        '${candidates.length} candidates'
        '${_scanSkipCount == 0 ? '' : ', $_scanSkipCount dir(s) skipped'}'
        '${paused.isEmpty ? '' : ' (upload paused: $paused)'}',
      );
      // The names, once. The count above is on every scan, so "was anything
      // declined" is always answerable; what stops repeating is the list,
      // which does not change between two window switches and is the same
      // dozen-odd lines for the life of the vault.
      if (!_loggedScanSkips && _scanSkips.isNotEmpty) {
        _loggedScanSkips = true;
        for (final skip in _scanSkips.toList()..sort()) {
          _log.info(
            'config scan skipped',
            data: {'resource': LogPath.config(skip)},
          );
        }
        // Never read again, and the collection sites stop building the
        // strings at all once this is set.
        _scanSkips.clear();
      }
    }
    var processed = 0;
    final sw = Stopwatch()..start();
    for (final entry in candidates.entries) {
      final resourceId = entry.key;
      final cand = entry.value;
      // Cheap change-detection: an unchanged signature means the file is
      // already synced — skip the read, decode, diff and crypto entirely.
      //
      // That shortcut rests on "a signature was recorded" implying "the content
      // reached the CRDT", and for a plugin directory the two can come apart: a
      // capture whose manifest was suppressed still records the signature, and
      // the directory is then skipped forever while holding no state at all —
      // invisible in the UI and never re-uploaded. Treat a signature with no
      // manifest behind it as a change, so the pairing repairs itself.
      if (_sync.sourceSigOf(resourceId) == cand.sig) {
        if (!_isPluginDir(resourceId) ||
            _pluginManifestOf(resourceId) != null ||
            // Once per session. If the re-capture did not restore the manifest,
            // repeating it every scan would re-read, re-chunk, re-encrypt and
            // re-upload every plugin on every resume — the storm this whole
            // signature guard exists to prevent. One more attempt next launch.
            !_repairedThisSession.add(resourceId)) {
          continue;
        }
        _log.info(
          'plugin dir has a signature but no manifest, '
          're-capturing: $resourceId',
        );
      }
      // Isolate per-resource: a malformed file (e.g. unexpected JSON shape)
      // must not abort the push for every other resource in this scan.
      try {
        final each = Stopwatch()..start();
        if (_isPluginDir(resourceId)) {
          // Only a capture that actually produced a manifest counts. A refused
          // one (mid-download, missing entry point, over the size cap) retries
          // on the next scan by design — reporting it as captured would make
          // the log claim work that did not happen, on every scan, forever.
          if (await _capturePluginDir(resourceId, cand.sig)) {
            processed++;
            _log.info(
              'config captured $resourceId '
              'in ${each.elapsedMilliseconds}ms',
            );
          }
          continue;
        }
        var bytes = await _adapter.readBinary(cand.path);
        if (resourceId == _enabledListResource) {
          bytes = restoreWithheld(bytes, {
            ..._withheldPluginIds,
            ..._unrunnableHere(),
          });
        }
        await _sync.applyLocalChange(resourceId, bytes, sourceSig: cand.sig);
        processed++;
        _log.info(
          'config processed $resourceId (${bytes.length} B) '
          'in ${each.elapsedMilliseconds}ms',
        );
      } catch (e, st) {
        // With the stack, because without it this is unactionable. A real
        // report read `config push failed: Null check operator used on a null
        // value`, repeated for every resource in the scan, and named neither
        // the resource's role in it nor a line to look at. The `!` is
        // somewhere down a path that spans the adapter, the withheld-list
        // rewrite and the settings store, and picking between them by reading
        // is guesswork.
        //
        // First frames only: dart2js stacks are long and mostly async
        // machinery, and the whole point is that this fires once per resource.
        final frames = st.toString().split('\n').take(4).join(' | ');
        _log.warning(
          'config push failed: $e | $frames',
          data: {'resource': LogPath.config(resourceId)},
        );
      }
    }
    if (processed > 0) {
      _log.info(
        'config scan: ${candidates.length} candidates, '
        '$processed processed in ${sw.elapsedMilliseconds}ms',
      );
    }

    await _detectPluginUninstalls();

    // Whole-file settings deletions are still not propagated (a transient read
    // miss must never wipe settings on other devices). Plugin directories are:
    // an uninstalled plugin left in the vault holds its blobs alive forever,
    // with no way to reclaim them — see [_detectPluginUninstalls] for the
    // evidence required before concluding one.
  }

  /// Marks plugins the user uninstalled here as removed for the whole vault.
  ///
  /// Gathers the evidence and hands the decision to [detectPluginUninstalls],
  /// which refuses on anything less than five agreeing signals. Note the two
  /// deliberate asymmetries: a failed listing is passed through as null rather
  /// than as an empty set, and the enabled set comes from the MERGED CRDT value
  /// rather than the file on disk (which we ourselves shorten while a plugin's
  /// code is still in flight).
  Future<void> _detectPluginUninstalls() async {
    if (_blobDirs == null) return;
    for (final kind in const [SyncedDirKind.plugin, SyncedDirKind.theme]) {
      await _detectRemovalsOf(kind);
    }
  }

  Future<void> _detectRemovalsOf(SyncedDirKind kind) async {
    // A removal is a push like any other. A device barred from sending this
    // category's code is the last one that should be telling the vault the code
    // is gone — from here the directories look absent either way.
    if (_pullOnly.contains(kind.category)) return;
    final listed = await _safeList('$_configDir/${kind.folder}');

    final live = <String>[];
    for (final entry in blobDirResources()) {
      if (entry.kind != kind) continue;
      final id = kind.idOf(entry.resourceId);
      if (id != null) live.add(id);
    }
    if (live.isEmpty) return;

    // Plugins corroborate with the vault's enabled set; themes have no such
    // list in Obsidian at all (only the SELECTED theme is recorded), so they
    // lean on "this device once had it" instead.
    final isPlugin = kind == SyncedDirKind.plugin;
    final rendered = isPlugin
        ? _sync.renderResource(_enabledListResource)
        : null;

    final decision = detectPluginUninstalls(
      vaultPluginIds: live,
      installedDirs: listed == null
          ? null
          : {for (final f in listed.folders) _baseName(f)},
      enabledInVault: rendered == null
          ? null
          : parseEnabledList(rendered)?.toSet(),
      requiresEnabledList: isPlugin,
      // A recorded signature is the record of this device having synced it.
      hadItHere: (id) => _sync.sourceSigOf('${kind.folder}/$id') != null,
    );

    if (decision.aborted) {
      _log.info('${kind.folder} removal detection: ${decision.abortReason}');
      return;
    }
    for (final id in decision.tombstone) {
      await _removeFromVault('${kind.folder}/$id');
    }
  }

  /// Publishes "this plugin is gone" for the whole vault.
  ///
  /// The removal is a normal value of the register, so a later reinstall simply
  /// wins by HLC. It carries no files, which is what lets the superseded blobs
  /// be released immediately instead of waiting for a sweep that would never
  /// come — nothing else ever drops that reference.
  Future<bool> _removeFromVault(String resourceId) async {
    final code = _blobDirs;
    final kind = SyncedDirKind.forResource(resourceId);
    final dirId = kind?.idOf(resourceId);
    final previous = _pluginManifestOf(resourceId);
    if (code == null || kind == null || dirId == null) return false;
    if (previous == null || previous.deleted) return false;

    final removed = PluginDirManifest.removed(
      pluginId: dirId,
      version: previous.version,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      updatedBy: code.deviceLabel,
    ).withHistoryFrom(previous);

    await _sync.applyLocalChange(resourceId, removed.toBytes());
    _log.info(
      'removed from vault: $resourceId '
      '(was ${previous.version ?? "?"})',
    );
    await _releaseSupersededBlobs(resourceId, previous, removed);
    return true;
  }

  /// Removes a plugin from the vault on the user's explicit request, and from
  /// this device too. Unlike the scan-time detection there is nothing to infer:
  /// the user said so.
  @override
  Future<bool> removeFromVault(String resourceId) async {
    if (_disposed) return false;
    final code = _blobDirs;
    final kind = SyncedDirKind.forResource(resourceId);
    if (code == null || kind == null) return false;
    final removed = await _removeFromVault(resourceId);
    if (!removed) return false;
    final manifest = _pluginManifestOf(resourceId);
    if (manifest != null) await code.apply(kind, resourceId, manifest);
    return true;
  }

  /// Uploads a plugin directory's code and folds the resulting manifest into
  /// the CRDT. The bytes go to the blob bucket; only references are pushed.
  /// Returns whether a manifest was produced and folded in.
  Future<bool> _capturePluginDir(String resourceId, String sig) async {
    final code = _blobDirs;
    final kind = SyncedDirKind.forResource(resourceId);
    final dirId = kind?.idOf(resourceId);
    if (code == null || kind == null || dirId == null) return false;

    final previous = _pluginManifestOf(resourceId);
    final manifest = await code.capture(kind, dirId, previous: previous);
    // Not a usable install right now (mid-download, no main.js, over the size
    // cap). Deliberately no signature recorded: the next scan retries, so a
    // finished install is picked up without waiting for another change.
    if (manifest == null) return false;

    // applyLocalChange is a no-op when the file set is byte-identical to what
    // the vault already holds (BlobDirCodec suppresses by content hash), which
    // is the common case right after another device's version landed here.
    // Recording the signature regardless is what stops the next scan from
    // re-reading and re-hashing the same megabytes.
    await _sync.applyLocalChange(
      resourceId,
      manifest.toBytes(),
      sourceSig: sig,
    );

    await _releaseSupersededBlobs(resourceId, previous, manifest);
    return true;
  }

  /// Frees the storage the replaced plugin version was holding.
  ///
  /// Runs only AFTER the push returned, so the vault never points at blobs we
  /// asked to delete. Candidates are what the old version referenced and the
  /// new one does not; the server intersects that against everything else it
  /// holds and keeps whatever is still referenced — a chunk shared with another
  /// plugin, with a note, or with a peer's concurrent value of this same
  /// record. Best-effort throughout: on an older server, or with no
  /// connection, the blobs simply wait for the next full sweep.
  Future<void> _releaseSupersededBlobs(
    String resourceId,
    PluginDirManifest? previous,
    PluginDirManifest captured,
  ) async {
    final release = _releaseBlobs;
    if (release == null || previous == null) return;
    // Did the capture actually win? A suppressed no-op, or a concurrent
    // version that dominated ours, must not trigger a release of blobs the
    // vault is still using.
    final merged = _pluginManifestOf(resourceId);
    if (merged == null || merged.contentHash != captured.contentHash) return;
    if (previous.contentHash == captured.contentHash) return;

    final superseded = previous.liveBlobIds.toSet()
      ..removeAll(captured.liveBlobIds);
    if (superseded.isEmpty) return;
    try {
      final deleted = await release(superseded.toList());
      _log.info(
        'plugin ${captured.pluginId}: released '
        '${deleted ?? 0}/${superseded.length} superseded blobs',
      );
    } catch (e) {
      _log.warning(
        'plugin blob release failed: $e',
        data: {'resource': LogPath.config(resourceId)},
      );
    }
  }

  // -- remote -> local ------------------------------------------------------

  Future<void> _writeChanged(Set<String> changed) async {
    var pluginLanded = false;
    for (final resourceId in changed) {
      // Between resources, not inside one: a half-written file is worse than
      // a late stop, and every resource is self-contained.
      if (_cancelled) {
        _log.warning('config: write cancelled, ${changed.length} pending');
        return;
      }
      if (_isPluginDir(resourceId)) {
        if (await _applyPluginDir(resourceId)) pluginLanded = true;
        continue;
      }
      await _writeResource(resourceId);
    }
    // Code just landed for a plugin whose id we were withholding from the
    // enabled list — write the list again now that Obsidian can actually load
    // it. Unconditional, because `changed` is a Set: the list may well have
    // been written earlier in this very loop, before the code arrived. The
    // write is idempotent and a no-op when nothing was withheld.
    if (pluginLanded) await _writeResource(_enabledListResource);
  }

  Future<void> _writeResource(String resourceId) async {
    var bytes = _sync.renderResource(resourceId);
    if (bytes == null) return;
    final path = '$_configDir/$resourceId';

    // The enabled list is the one resource whose render depends on what else
    // has landed here (see [_withholdUninstalled]).
    final filtered = resourceId == _enabledListResource
        ? await _withholdUninstalled(bytes)
        : null;
    bytes = filtered ?? bytes;

    // If the file on disk is already this content in Obsidian's own format,
    // don't overwrite it with our canonical (sorted/minified) render — that
    // pointless reformat is what made every synced settings file churn
    // (our write flips it to canonical, Obsidian flips it back, repeat).
    // Still record the current signature so the next scan treats it as
    // already synced rather than a fresh local change.
    final existing = await _readBinaryOrNull(path);
    final matches = filtered == null
        ? _sync.diskMatchesRendered(resourceId, existing ?? Uint8List(0))
        : jsonCanonicalEqual(existing ?? Uint8List(0), filtered);
    if (existing != null && matches) {
      final st = await _adapter.stat(path);
      if (st != null) await _sync.recordSourceSig(resourceId, _sigOf(st));
      return;
    }

    await _ensureParentDir(path);
    await _adapter.writeBinary(path, bytes);
    // Record the written file's signature so the next scan recognises it as
    // our own echo rather than a fresh local change to push back.
    final st = await _adapter.stat(path);
    if (st != null) await _sync.recordSourceSig(resourceId, _sigOf(st));
  }

  /// Plugin ids this platform cannot run, and therefore cannot speak for.
  ///
  /// Obsidian drops a desktop-only plugin from the enabled list on mobile as a
  /// matter of course — it could not load it either way. Diffing that into the
  /// shared set would let a phone quietly disable desktop plugins on every
  /// other device, which is what happens without this.
  ///
  /// Only what the vault's own manifests declare: with plugin-code sync off
  /// there are no manifests, and a device cannot tell a desktop-only plugin
  /// from one it simply does not have.
  Set<String> _unrunnableHere() {
    final code = _blobDirs;
    if (code == null || !code.isMobile) return const {};
    return {
      for (final entry in blobDirResources())
        if (entry.kind == SyncedDirKind.plugin && entry.manifest.desktopOnly)
          entry.manifest.pluginId,
    };
  }

  /// Drops from the enabled list any plugin whose code the vault is going to
  /// deliver but that has not arrived on this device yet, and remembers what
  /// was dropped (see [partitionEnabledList]).
  ///
  /// Returns null when nothing was withheld.
  Future<Uint8List?> _withholdUninstalled(Uint8List rendered) async {
    final code = _blobDirs;
    if (code == null) return null;
    final ids = parseEnabledList(rendered);
    if (ids == null) return null;

    // The two predicates are resolved up front: one is a disk stat, and
    // partitionEnabledList is deliberately synchronous and pure.
    final installed = <String>{};
    for (final id in ids) {
      if (await code.isInstalled(SyncedDirKind.plugin, id)) installed.add(id);
    }
    final split = partitionEnabledList(
      ids,
      vaultHasCode: (id) => _sync.renderResource('plugins/$id') != null,
      installedHere: installed.contains,
    );

    _withheldPluginIds
      ..clear()
      ..addAll(split.withheld);
    if (split.withheld.isEmpty) return null;
    _log.info(
      'enabled list: withholding ${split.withheld.join(", ")} '
      'until their code lands',
    );
    return canonicalJsonBytes(split.keep);
  }

  /// Materializes a plugin directory the vault moved ahead on: fetch the blobs,
  /// write the files, cycle the plugin.
  ///
  /// Failures are contained here — one plugin whose blob is missing must not
  /// stop the rest of a pull from landing.
  Future<bool> _applyPluginDir(String resourceId) async {
    final code = _blobDirs;
    final kind = SyncedDirKind.forResource(resourceId);
    final manifest = _pluginManifestOf(resourceId);
    if (code == null || kind == null || manifest == null) return false;
    final bool applied;
    try {
      applied = await code.apply(kind, resourceId, manifest);
    } catch (e) {
      _log.warning(
        'plugin apply failed: $e',
        data: {'resource': LogPath.config(resourceId)},
      );
      return false;
    }
    // Record what we just wrote as the synced signature, or the next scan reads
    // this install back, re-chunks it and re-uploads what it just downloaded.
    final dirId = kind.idOf(resourceId);
    final sig = dirId == null ? null : await code.dirSignature(kind, dirId);
    if (sig != null) await _sync.recordSourceSig(resourceId, sig);
    return applied;
  }

  /// Blob ids this sync needs kept in the shared local cache.
  ///
  /// Handed to the engine's local blob GC, whose own live set covers notes
  /// only. Returns null until the settings store has loaded — an empty answer
  /// would be indistinguishable from "no plugins", and the GC would evict every
  /// plugin blob. Empty (not null) once loaded with plugin-code sync off: there
  /// is then genuinely nothing of ours to keep, including leftovers from when
  /// it was on.
  @override
  Set<String>? liveBlobIds() {
    if (!_ready) return null;
    final out = <String>{};
    // EVERY blob-backed kind, not just plugins: themes keep their bytes in the
    // same cache, and a live set that forgot them would have the GC evict them
    // on the next sweep.
    for (final entry in blobDirResources()) {
      out.addAll(entry.manifest.liveBlobIds);
    }
    return out;
  }

  /// Every blob-backed directory the vault currently holds, with the resource
  /// id it came from — the vault's view, which may be ahead of or behind this
  /// device's disk. Empty when blob-backed sync is off.
  List<({String resourceId, SyncedDirKind kind, PluginDirManifest manifest})>
  blobDirResources() {
    if (_blobDirs == null) return const [];
    final out =
        <
          ({String resourceId, SyncedDirKind kind, PluginDirManifest manifest})
        >[];
    for (final id in _sync.resourceIdsOfKind(SettingsCrdtKind.blobDir)) {
      final kind = SyncedDirKind.forResource(id);
      final manifest = _pluginManifestOf(id);
      // Removals are records, not content — they exist to propagate, and hold
      // nothing. Neither the UI nor the blob live set should see them.
      if (kind == null || manifest == null || manifest.deleted) continue;
      out.add((resourceId: id, kind: kind, manifest: manifest));
    }
    out.sort((a, b) => a.resourceId.compareTo(b.resourceId));
    return out;
  }

  /// The vault's plugin set joined with what this device actually has on disk,
  /// for the storage overview and the sync panel. Reads one small
  /// `manifest.json` per plugin, so it is user-triggered, never polled.
  @override
  Future<PluginCodeOverview> pluginOverview() async {
    final code = _blobDirs;
    if (code == null) return PluginCodeOverview.empty;
    final rows = <PluginCodeRow>[];
    for (final entry in blobDirResources()) {
      final manifest = entry.manifest;
      rows.add(
        PluginCodeRow(
          resourceId: entry.resourceId,
          isTheme: entry.kind == SyncedDirKind.theme,
          pluginId: manifest.pluginId,
          sizeBytes: manifest.totalSize,
          vaultVersion: manifest.version,
          localVersion: await _localVersionOf(
            code,
            entry.kind,
            entry.resourceId,
          ),
          updatedBy: manifest.updatedBy,
          updatedAtMs: manifest.updatedAtMs,
          desktopOnly: manifest.desktopOnly,
        ),
      );
    }
    return PluginCodeOverview(rows);
  }

  /// This device's installed version, looked up by the VALIDATED resource id
  /// rather than by the record's own id — the same rule the apply path follows.
  Future<String?> _localVersionOf(
    BlobDirSync code,
    SyncedDirKind kind,
    String resourceId,
  ) async {
    final id = kind.idOf(resourceId);
    return id == null ? null : code.localVersion(kind, id);
  }

  /// The merged manifest currently held for a plugin-directory resource.
  PluginDirManifest? _pluginManifestOf(String resourceId) {
    final rendered = _sync.renderResource(resourceId);
    return rendered == null ? null : PluginDirManifest.tryParse(rendered);
  }

  bool _isPluginDir(String resourceId) =>
      ObsidianSettingsRegistry.classify(resourceId)?.kind ==
      SettingsCrdtKind.blobDir;

  Future<Uint8List?> _readBinaryOrNull(String path) async {
    if (await _adapter.stat(path) == null) return null;
    try {
      return await _adapter.readBinary(path);
    } catch (_) {
      return null;
    }
  }

  // -- enumeration ----------------------------------------------------------

  /// Stats every allowlisted + enabled resource currently on disk, returning a
  /// `resourceId -> (path, signature)` map. Bounded: top-level files, one level
  /// into each plugin dir, and the themes/snippets trees — never a blind
  /// recursive walk of `plugins/**`. Stat is cheap (no bytes read); the caller
  /// reads only the resources whose signature changed.
  /// How many directories this scan declined. Always counted — one int, and
  /// it is what keeps "nothing to sync" distinguishable from "the feature is
  /// off" on every scan.
  int _scanSkipCount = 0;

  /// Why, in words — collected only until [_loggedScanSkips]. Every entry
  /// describes a STEADY state: our own plugin folder, or one Obsidian left
  /// behind when the user uninstalled a plugin (it removes the manifest, not
  /// the directory). That set only grows over a vault's life, and a scan runs
  /// on every window switch, so logging it per scan repeated the same dozen
  /// lines forever.
  final Set<String> _scanSkips = {};

  /// Set once the names have been logged. After that the collection sites do
  /// not even build the strings — which makes this cheaper than what it
  /// replaced, where they were built and then dropped on the floor by a
  /// release LogController that has no outputs at all.
  bool _loggedScanSkips = false;

  Future<Map<String, ({String path, String sig})>> _enumerate() async {
    _scanSkipCount = 0;
    final out = <String, ({String path, String sig})>{};
    final top = await _safeList(_configDir);
    if (top == null) return out;

    for (final f in top.files) {
      await _tryAdd(f, out);
    }

    for (final folder in top.folders) {
      final name = _baseName(folder);
      if (name == 'plugins') {
        final plugins = await _safeList(folder);
        for (final pdir in plugins?.folders ?? const <String>[]) {
          await _tryAddPluginDir(pdir, out);
          final pf = await _safeList(pdir);
          for (final f in pf?.files ?? const <String>[]) {
            await _tryAdd(f, out);
          }
        }
      } else if (name == 'themes') {
        // A theme is a directory resource now, exactly like a plugin. Its
        // files classify to nothing on their own.
        final themes = await _safeList(folder);
        for (final tdir in themes?.folders ?? const <String>[]) {
          await _tryAddPluginDir(tdir, out);
        }
      } else if (name == 'snippets') {
        await _collectTree(folder, out, depth: 2);
      }
    }
    return out;
  }

  Future<void> _collectTree(
    String dir,
    Map<String, ({String path, String sig})> out, {
    required int depth,
  }) async {
    final listed = await _safeList(dir);
    if (listed == null) return;
    for (final f in listed.files) {
      await _tryAdd(f, out);
    }
    if (depth <= 1) return;
    for (final sub in listed.folders) {
      await _collectTree(sub, out, depth: depth - 1);
    }
  }

  /// Registers a plugin directory as a single blob-backed resource, keyed
  /// `plugins/<id>`. Its signature covers all three code files at once, so the
  /// whole install is captured or skipped as one unit.
  Future<void> _tryAddPluginDir(
    String adapterPath,
    Map<String, ({String path, String sig})> out,
  ) async {
    final code = _blobDirs;
    if (code == null) return;
    final resourceId = _toResourceId(adapterPath);
    final cls = ObsidianSettingsRegistry.classify(resourceId);
    if (cls == null || cls.kind != SettingsCrdtKind.blobDir) {
      // Not a plugin directory at all (our own, or an unexpected path shape).
      // Recorded because a silent skip here looks exactly like the feature
      // being off, and the two need telling apart from a log alone.
      _scanSkipCount++;
      if (!_loggedScanSkips) {
        _scanSkips.add(
          'not a resource: $resourceId (kind=${cls?.kind.name ?? "none"})',
        );
      }
      return;
    }
    if (!_enabled.contains(cls.category)) return;
    // Enumeration feeds the push path only, so leaving a pull-only category out
    // of it is exactly "keep receiving this, never send it".
    if (_pullOnly.contains(cls.category)) return;
    final kind = SyncedDirKind.forResource(resourceId);
    final dirId = kind?.idOf(resourceId);
    if (kind == null || dirId == null) {
      _log.info(
        'blob dir has no id',
        data: {'resource': LogPath.config(resourceId)},
      );
      return;
    }
    // Null signature = no manifest.json, i.e. not a usable install (a leftover
    // or half-downloaded folder). Not a resource.
    final sig = await code.dirSignature(kind, dirId);
    if (sig == null) {
      // Almost always a folder Obsidian left behind when the user uninstalled
      // the plugin — it removes the manifest, not the directory. So this set
      // only grows over a vault's life and would repeat on every scan forever.
      _scanSkipCount++;
      if (!_loggedScanSkips) {
        _scanSkips.add('${kind.folder}/$dirId: no manifest.json');
      }
      return;
    }
    out[resourceId] = (path: adapterPath, sig: sig);
  }

  /// Classifies [adapterPath] (vault-relative, includes `.obsidian/`), and if it
  /// is an enabled resource, stats it and records `(path, signature)`.
  Future<void> _tryAdd(
    String adapterPath,
    Map<String, ({String path, String sig})> out,
  ) async {
    final resourceId = _toResourceId(adapterPath);
    final cls = ObsidianSettingsRegistry.classify(resourceId);
    if (cls == null || !_enabled.contains(cls.category)) return;
    if (_pullOnly.contains(cls.category)) return;
    try {
      final st = await _adapter.stat(adapterPath);
      if (st == null) return;
      // Skip large whole-file resources (a multi-MB theme CSS, or a bloated
      // plugin data.json): reading + parse/canonicalize + double-base64 +
      // pure-Dart encrypt of them on the UI thread freezes the app for tens of
      // seconds. Caught here via stat — no read, no crypto.
      final wholeFileKind =
          cls.kind == SettingsCrdtKind.wholeFile ||
          cls.kind == SettingsCrdtKind.jsonWholeFile;
      if (wholeFileKind && (st.size ?? 0) > _maxWholeFileBytes) {
        _log.info(
          'config skip large ${cls.kind.name}: $resourceId '
          '(${st.size} B > $_maxWholeFileBytes)',
        );
        return;
      }
      out[resourceId] = (path: adapterPath, sig: _sigOf(st));
    } catch (e) {
      _log.warning('config stat failed: $adapterPath: $e');
    }
  }

  // -- helpers --------------------------------------------------------------

  String _sigOf(StatHandle st) => '${st.mtime}:${st.size ?? -1}';

  String _toResourceId(String adapterPath) {
    const prefix = '$_configDir/';
    return adapterPath.startsWith(prefix)
        ? adapterPath.substring(prefix.length)
        : adapterPath;
  }

  String _baseName(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  Future<void> _ensureParentDir(String path) async {
    final i = path.lastIndexOf('/');
    if (i <= 0) return;
    final dir = path.substring(0, i);
    try {
      if (!await _adapter.exists(dir)) {
        await _adapter.mkdir(dir);
      }
    } catch (_) {
      // mkdir races / already-exists are harmless.
    }
  }

  Future<ListedFilesHandle?> _safeList(String path) async {
    try {
      if (!await _adapter.exists(path)) return null;
      return await _adapter.list(path);
    } catch (e) {
      _log.warning(
        'config list failed: $e',
        data: {'resource': LogPath.config(path)},
      );
      return null;
    }
  }
}
