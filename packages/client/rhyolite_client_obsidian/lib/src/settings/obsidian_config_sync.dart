import 'dart:async';
import 'dart:typed_data';

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart'
    show NotifyCoordinator, SettingsSync, SettingsCrdtKind;
import 'package:rpc_dart/rpc_dart.dart' show RpcCallerEndpoint;

import 'obsidian_settings_registry.dart';

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
class ObsidianConfigSync {
  ObsidianConfigSync({
    required AdapterHandle adapter,
    required SettingsSync sync,
    required Set<SettingsCategory> enabledCategories,
    Duration initialScanDelay = const Duration(seconds: 4),
    RpcCallerEndpoint? notifyEndpoint,
    String? notifyTopic,
    void Function(bool active)? onActivity,
    void Function()? onRemoteApplied,
    void Function(String message)? log,
    Future<void> Function(Future<void> Function() task, {Object? key})?
        runBackground,
  })  : _adapter = adapter,
        _sync = sync,
        _enabled = enabledCategories,
        _initialScanDelay = initialScanDelay,
        _notifyEndpoint = notifyEndpoint,
        _notifyTopic = notifyTopic,
        _onActivity = onActivity,
        _onRemoteApplied = onRemoteApplied,
        _log = log,
        _runBackground = runBackground;

  static const _configDir = '.obsidian';

  /// Whole-file resources (themes, snippet CSS, plugin data.json) larger than
  /// this are NOT synced: the content is inlined and encrypted with a pure-Dart
  /// cipher on the single UI thread, so a multi-MB file freezes the app. Such
  /// files (themes especially) are reinstallable. Structured fieldMap/orSet
  /// settings are small and never hit this.
  static const _maxWholeFileBytes = 1 << 20; // 1 MiB

  final AdapterHandle _adapter;
  final SettingsSync _sync;
  final Set<SettingsCategory> _enabled;
  final Duration _initialScanDelay;
  final RpcCallerEndpoint? _notifyEndpoint;
  final String? _notifyTopic;
  final void Function(bool active)? _onActivity;

  /// Fired after a pull that changed on-disk settings while Obsidian is already
  /// running (a notify push or a resume/manual sync — NOT the initial start
  /// pull, since a fresh app reads settings at launch). Obsidian doesn't
  /// hot-apply config files, so the host uses this to prompt a one-click reload.
  final void Function()? _onRemoteApplied;

  final void Function(String message)? _log;

  /// Routes connection-using settings work onto the note engine's
  /// connection-fair scheduler (low-priority background lane), so settings
  /// sync yields to interactive note sync and pauses while the user is
  /// actively editing. Null → run directly (no engine scheduler).
  final Future<void> Function(Future<void> Function() task, {Object? key})?
      _runBackground;

  NotifyCoordinator? _notify;
  bool _busy = false;
  bool _disposed = false;

  /// Runs [body] on the engine scheduler (background) when available, else
  /// directly. Keeps `.obsidian` sync off the connection while notes sync.
  Future<void> _bg(Object key, Future<void> Function() body) {
    final run = _runBackground;
    return run != null ? run(body, key: key) : body();
  }

  Future<void> start() async {
    // Initial pull only: getting remote settings onto disk is cheap and enough
    // to render them. The local scan (read + diff every file) is CPU-heavy and
    // would jank the UI while the notes engine is also starting, so defer it
    // off the app-open critical path.
    await _bg('settings:start', () async {
      final changed = await _sync.start();
      final sw = Stopwatch()..start();
      await _writeChanged(changed);
      _log?.call('config start: writeChanged ${changed.length} '
          'in ${sw.elapsedMilliseconds}ms');
    });
    Future<void>.delayed(_initialScanDelay, () {
      if (!_disposed) unawaited(sync());
    });

    _setupNotify();
  }

  /// Push local `.obsidian` changes then pull remote ones. Called (deferred) on
  /// start, on resume (return to Obsidian), and from the manual command.
  /// Reentrancy-safe: overlapping calls are dropped while one is in flight.
  Future<void> sync() async {
    if (_busy || _disposed) return;
    _busy = true;
    _onActivity?.call(true);
    var remoteChanged = 0;
    try {
      await _bg('settings:sync', () async {
        await _scanAndPush();
        final changed = await _sync.pull();
        await _writeChanged(changed);
        remoteChanged = changed.length;
      });
    } catch (e) {
      _log?.call('config sync error: $e');
    } finally {
      _busy = false;
      _onActivity?.call(false);
    }
    if (remoteChanged > 0) _onRemoteApplied?.call();
  }

  /// Pull-only: fetch remote changes and write them to disk, WITHOUT a local
  /// scan/push. This is the notify reaction — the remote changed, not us, so a
  /// full scan would be wasted work. Shares [_busy] with [sync] so a notify
  /// pull and a resume sync never overlap.
  Future<void> pullRemote() async {
    if (_busy || _disposed) return;
    _busy = true;
    _onActivity?.call(true);
    var remoteChanged = 0;
    try {
      await _bg('settings:pull', () async {
        final changed = await _sync.pull();
        await _writeChanged(changed);
        remoteChanged = changed.length;
      });
    } catch (e) {
      _log?.call('config notify pull error: $e');
    } finally {
      _busy = false;
      _onActivity?.call(false);
    }
    if (remoteChanged > 0) _onRemoteApplied?.call();
  }

  /// Re-upload: make THIS device authoritative — wipe the server settings
  /// keyspace + local store, then push every enabled `.obsidian` resource from
  /// disk. Other devices re-sync on their next pull/notify.
  Future<void> resetFromThisDevice() async {
    if (_disposed) return;
    _busy = true;
    _onActivity?.call(true);
    try {
      await _sync.wipeServerAndLocal();
      await _scanAndPush();
    } finally {
      _busy = false;
      _onActivity?.call(false);
    }
  }

  /// Download: discard local settings state and re-download everything from the
  /// server, overwriting the on-disk `.obsidian` files. Most settings apply
  /// after an Obsidian restart.
  Future<void> restoreFromServer() async {
    if (_disposed) return;
    _busy = true;
    _onActivity?.call(true);
    try {
      final changed = await _sync.restoreFromServer();
      await _writeChanged(changed);
    } finally {
      _busy = false;
      _onActivity?.call(false);
    }
  }

  /// After a transport reconnect the notify server-stream is dead (rpc_dart
  /// does not carry in-flight calls across the socket swap). Reissue the
  /// subscription on the fresh transport and pull to catch up on missed pushes.
  void handleReconnect() {
    if (_disposed) return;
    _setupNotify();
    unawaited(pullRemote());
  }

  /// (Re)subscribes the config-keyspace notify stream. Idempotent — stops any
  /// existing coordinator first, so it is safe to call again after a reconnect.
  void _setupNotify() {
    final endpoint = _notifyEndpoint;
    final topic = _notifyTopic;
    if (endpoint == null || topic == null) return;
    unawaited(_notify?.stop());
    _notify = NotifyCoordinator(
      endpoint: endpoint,
      topic: topic,
      onNotify: (sourceClientId) {
        if (_disposed) return;
        // The server echoes our own pushes back on this topic. Ignore them —
        // otherwise every settings push (and every file of a re-upload)
        // self-notifies and pulls its own change back.
        if (sourceClientId != null && sourceClientId == _sync.clientId) return;
        _log?.call('config notify received — pulling');
        unawaited(pullRemote());
      },
      onWarning: _log,
    )..start();
  }

  void dispose() {
    _disposed = true;
    unawaited(_notify?.stop());
    _notify = null;
  }

  // -- local -> remote ------------------------------------------------------

  Future<void> _scanAndPush() async {
    final candidates = await _enumerate();
    var processed = 0;
    final sw = Stopwatch()..start();
    for (final entry in candidates.entries) {
      final resourceId = entry.key;
      final cand = entry.value;
      // Cheap change-detection: an unchanged signature means the file is
      // already synced — skip the read, decode, diff and crypto entirely.
      if (_sync.sourceSigOf(resourceId) == cand.sig) continue;
      // Isolate per-resource: a malformed file (e.g. unexpected JSON shape)
      // must not abort the push for every other resource in this scan.
      try {
        final each = Stopwatch()..start();
        final bytes = await _adapter.readBinary(cand.path);
        await _sync.applyLocalChange(resourceId, bytes, sourceSig: cand.sig);
        processed++;
        _log?.call('config processed $resourceId (${bytes.length} B) '
            'in ${each.elapsedMilliseconds}ms');
      } catch (e) {
        _log?.call('config push failed: $resourceId: $e');
      }
    }
    if (processed > 0) {
      _log?.call('config scan: ${candidates.length} candidates, '
          '$processed processed in ${sw.elapsedMilliseconds}ms');
    }
    // Whole-file deletions are intentionally not propagated in v1 (a transient
    // read miss must never wipe settings on other devices).
  }

  // -- remote -> local ------------------------------------------------------

  Future<void> _writeChanged(Set<String> changed) async {
    for (final resourceId in changed) {
      final bytes = _sync.renderResource(resourceId);
      if (bytes == null) continue;
      final path = '$_configDir/$resourceId';

      // If the file on disk is already this content in Obsidian's own format,
      // don't overwrite it with our canonical (sorted/minified) render — that
      // pointless reformat is what made every synced settings file churn
      // (our write flips it to canonical, Obsidian flips it back, repeat).
      // Still record the current signature so the next scan treats it as
      // already synced rather than a fresh local change.
      final existing = await _readBinaryOrNull(path);
      if (existing != null && _sync.diskMatchesRendered(resourceId, existing)) {
        final st = await _adapter.stat(path);
        if (st != null) await _sync.recordSourceSig(resourceId, _sigOf(st));
        continue;
      }

      await _ensureParentDir(path);
      await _adapter.writeBinary(path, bytes);
      // Record the written file's signature so the next scan recognises it as
      // our own echo rather than a fresh local change to push back.
      final st = await _adapter.stat(path);
      if (st != null) await _sync.recordSourceSig(resourceId, _sigOf(st));
    }
  }

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
  Future<Map<String, ({String path, String sig})>> _enumerate() async {
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
          final pf = await _safeList(pdir);
          for (final f in pf?.files ?? const <String>[]) {
            await _tryAdd(f, out);
          }
        }
      } else if (name == 'themes' || name == 'snippets') {
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

  /// Classifies [adapterPath] (vault-relative, includes `.obsidian/`), and if it
  /// is an enabled resource, stats it and records `(path, signature)`.
  Future<void> _tryAdd(
    String adapterPath,
    Map<String, ({String path, String sig})> out,
  ) async {
    final resourceId = _toResourceId(adapterPath);
    final cls = ObsidianSettingsRegistry.classify(resourceId);
    if (cls == null || !_enabled.contains(cls.category)) return;
    try {
      final st = await _adapter.stat(adapterPath);
      if (st == null) return;
      // Skip large whole-file resources (a multi-MB theme CSS, or a bloated
      // plugin data.json): reading + parse/canonicalize + double-base64 +
      // pure-Dart encrypt of them on the UI thread freezes the app for tens of
      // seconds. Caught here via stat — no read, no crypto.
      final wholeFileKind = cls.kind == SettingsCrdtKind.wholeFile ||
          cls.kind == SettingsCrdtKind.jsonWholeFile;
      if (wholeFileKind && (st.size ?? 0) > _maxWholeFileBytes) {
        _log?.call('config skip large ${cls.kind.name}: $resourceId '
            '(${st.size} B > $_maxWholeFileBytes)');
        return;
      }
      out[resourceId] = (path: adapterPath, sig: _sigOf(st));
    } catch (e) {
      _log?.call('config stat failed: $adapterPath: $e');
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
      _log?.call('config list failed: $path: $e');
      return null;
    }
  }
}
