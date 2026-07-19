// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../i18n/i18n.dart';
import 'server_rejections.dart';

/// Docked right-side panel surfacing live sync state and the actions/warnings
/// that don't fit the status-bar dot. Deliberately leads with what a
/// managed-sync competitor *can't* show — end-to-end encryption, conflict-free
/// text merges, the storage tier — not just a stats table.
///
/// The view class itself (an Obsidian `ItemView` subclass) is authored in JS
/// and injected into `main.js` by `bin/build.dart` — dart2js can't subclass a
/// JS class. Its constructor lands on `globalThis.__rhyoliteSyncPanelViewCtor`;
/// its `onOpen`/`onClose` call back into the callbacks this class installs.
class SyncPanel {
  SyncPanel({
    required PluginHandle plugin,
    required ISyncEngine engine,
    required String vaultName,
    required bool encrypted,
    required String backendLabel,
    required String planLabel,
    required void Function() onOpenSettings,
    required Future<void> Function() onBrowseVersions,
    required bool Function() isPaused,
    required Future<void> Function(bool paused) onSetPaused,
    Future<void> Function()? onReconnect,
    Future<({int usedBytes, int quotaBytes})?> Function()? onFetchUsage,
    Future<int> Function()? onSettingsSize,
    void Function()? onStorageDetails,
    LogScope? logger,
  }) : _plugin = plugin,
       _engine = engine,
       _vaultName = vaultName,
       _encrypted = encrypted,
       _backendLabel = backendLabel,
       _planLabel = planLabel,
       _onOpenSettings = onOpenSettings,
       _onBrowseVersions = onBrowseVersions,
       _isPaused = isPaused,
       _onSetPaused = onSetPaused,
       _onReconnect = onReconnect,
       _onFetchUsage = onFetchUsage,
       _onSettingsSize = onSettingsSize,
       _onStorageDetails = onStorageDetails,
       _log = logger;

  static const viewType = 'rhyolite-sync-panel';

  final PluginHandle _plugin;
  final ISyncEngine _engine;
  final String _vaultName;
  final bool _encrypted;
  final String _backendLabel;
  final String _planLabel;
  final void Function() _onOpenSettings;
  final Future<void> Function() _onBrowseVersions;
  final bool Function() _isPaused;
  final Future<void> Function(bool paused) _onSetPaused;
  final Future<void> Function()? _onReconnect;
  final Future<({int usedBytes, int quotaBytes})?> Function()? _onFetchUsage;
  final Future<int> Function()? _onSettingsSize;
  final void Function()? _onStorageDetails;
  final LogScope? _log;

  /// Approx synced-settings footprint, fetched once per open (null until then
  /// or when settings sync has never run).
  int? _settingsBytes;

  StreamSubscription<SyncEngineEvent>? _sub;
  Timer? _renderTimer;

  /// contentEl of the currently-open view, or null when the panel is closed.
  JSObject? _contentEl;

  // ── Live state ───────────────────────────────────────────────────────────
  // Connection/activity model — green ("ready") means genuinely connected with
  // no work pending. The engine emits no "sync finished" event, so activity is
  // a transient overlay cleared by an idle-debounce timer.
  bool _everStarted = false;
  bool _connected = false;
  bool _connecting = false;
  int _connectAttempt = 0;
  _Blocker _blocker = _Blocker.none;
  bool _activity = false;
  Timer? _activityTimer;
  Timer? _errorTimer;

  bool _hasPending = false;
  ({int completed, int total})? _progress;
  String? _lastError;
  DateTime? _lastSyncedAt;
  int _uploaded = 0;
  int _downloaded = 0;

  /// Last ~8 synced files, newest first — proves sync is alive, per-file.
  final List<({bool up, String path})> _recent = [];

  /// Size-blocked files keyed by path (latest event per path wins).
  final Map<String, SyncFileSizeBlocked> _blocked = {};

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
    final ctor = jsu.getProperty<JSObject?>(
      jsu.globalThis,
      '__rhyoliteSyncPanelViewCtor',
    );
    if (ctor == null) {
      _log?.warning('sync panel: view ctor missing — build shim not injected');
      return;
    }

    // Re-point the JS view's callbacks at THIS instance every boot.
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

    // registerView must run exactly once per plugin load — Obsidian throws on
    // a duplicate view type, and a soft engine restart re-runs boot with the
    // SAME plugin object. The flag lives on the plugin (torn down on unload,
    // fresh on re-enable), so registration tracks the plugin lifecycle.
    final already =
        jsu.getProperty<bool?>(_plugin.raw, '__rhyolitePanelRegistered') ??
        false;
    if (!already) {
      jsu.callMethod<void>(_plugin.raw, 'registerView', [
        viewType,
        jsu.allowInterop(
          (JSObject leaf) => jsu.callConstructor<JSObject>(ctor, [leaf]),
        ),
      ]);
      jsu.setProperty(_plugin.raw, '__rhyolitePanelRegistered', true);
    }

    _sub = _engine.events.listen(_onEvent);
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _renderTimer?.cancel();
    _renderTimer = null;
    _activityTimer?.cancel();
    _activityTimer = null;
    _errorTimer?.cancel();
    _errorTimer = null;
    _contentEl = null;
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
    _contentEl = jsu.getProperty<JSObject>(view, 'contentEl');
    _render();
    _maybeFetchUsage();
    _fetchSettingsSize();
  }

  void _fetchSettingsSize() {
    final fetch = _onSettingsSize;
    if (fetch == null) return;
    fetch().then((n) {
      _settingsBytes = n;
      _scheduleRender();
    }).catchError((Object e) {
      _log?.warning('sync panel: settings size fetch failed: $e');
    });
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
    _contentEl = null;
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  void _onEvent(SyncEngineEvent event) {
    switch (event) {
      case SyncStarted():
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
        _clearActivity();
      case SyncDisconnected():
        _connected = false;
        _connecting = false;
        _clearActivity();
      case SyncPushing():
      case SyncPulling():
        _bumpActivity();
      case SyncFilePushed(:final path):
        _lastSyncedAt = event.timestamp;
        _uploaded++;
        _pushRecent(up: true, path: path);
        _blocked.remove(path); // shrank below the limit and synced
        _bumpActivity();
      case SyncFilePulled(:final path):
        _lastSyncedAt = event.timestamp;
        _downloaded++;
        if (path.isNotEmpty) _pushRecent(up: false, path: path);
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
          _transfers[path] =
              (upload: event.upload, sent: event.sentBytes, total: event.totalBytes);
        }
        _bumpActivity();
      case SyncFileSizeBlocked():
        _blocked[event.path] = event;
      case SyncFileSizeUnblocked(:final path):
        _blocked.remove(path);
      case SyncFileDeleted(:final path):
        _blocked.remove(path);
      case SyncDataLoss():
        _dataLoss.add(event);
        // Bounded: data-loss is rare, but a very long session must not grow the
        // list without limit. Keep the most recent entries.
        if (_dataLoss.length > 100) _dataLoss.removeRange(0, _dataLoss.length - 100);
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
      _render();
    });
  }

  void _clearActivity() {
    _activityTimer?.cancel();
    _activityTimer = null;
    _activity = false;
    _progress = null;
  }

  void _pushRecent({required bool up, required String path}) {
    _recent.removeWhere((e) => e.path == path && e.up == up);
    _recent.insert(0, (up: up, path: path));
    if (_recent.length > 8) _recent.removeRange(8, _recent.length);
  }

  // ---------------------------------------------------------------------------
  // Storage usage (managed only)
  // ---------------------------------------------------------------------------

  /// Force a re-fetch of the managed usage meter (the ↻ button).
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

  void _render() {
    final root = _contentEl;
    if (root == null) return;
    jsu.callMethod<void>(root, 'empty', []);
    _style(root, 'padding', '10px 12px');

    final stats = _engine.statsSnapshot();

    // ── Status ──
    final statusRow = _el(root, 'div');
    _flexRow(statusRow, gap: '8px');
    final dot = _el(statusRow, 'span');
    final ds = jsu.getProperty<JSObject>(dot, 'style');
    jsu.setProperty(ds, 'width', '10px');
    jsu.setProperty(ds, 'height', '10px');
    jsu.setProperty(ds, 'borderRadius', '50%');
    jsu.setProperty(ds, 'flexShrink', '0');
    jsu.setProperty(ds, 'background', _statusColor());
    final label = _el(statusRow, 'span', text: _statusLabel());
    _style(label, 'fontWeight', '600');

    // ── Trust sub-line: encryption + last sync ──
    final sub = _el(root, 'div');
    _style(sub, 'fontSize', '12px');
    _style(sub, 'color', 'var(--text-muted)');
    _style(sub, 'marginTop', '3px');
    final bits = <String>[
      if (_encrypted) '🔒 ${S.endToEndEncrypted}',
      if (_lastSyncedAt != null) S.syncedAgo(_ago(_lastSyncedAt!)),
    ];
    _setText(sub, bits.isEmpty ? S.notConnected : bits.join('  ·  '));

    if (_lastError != null && _blocker == _Blocker.error) {
      final err = _el(root, 'div', text: _lastError!);
      _style(err, 'fontSize', '12px');
      _style(err, 'color', 'var(--text-error)');
      _style(err, 'marginTop', '4px');
    }

    // ── Stats table ──
    final table = _el(root, 'div');
    _style(table, 'marginTop', '12px');
    _style(table, 'fontSize', '13px');
    _kv(table, S.vaultSection, _vaultName.isEmpty ? '—' : _vaultName);
    _kv(table, S.panelStorageLabel, _backendLabel);
    if (stats != null) {
      _kv(table, S.files, '${stats.totalFiles - stats.tombstones}');
      _kv(table, S.vaultSizeLabel, _bytes(stats.totalSizeBytes));
    }
    if (_settingsBytes != null && _settingsBytes! > 0) {
      _kv(table, S.settingsSizeLabel, _bytes(_settingsBytes!));
    }

    // ── Storage meter (managed) ──
    final usage = _usage;
    if (usage != null && usage.quotaBytes > 0) {
      _storageMeter(root, usage);
    }

    // ── Storage details link (+ usage refresh) ──
    final onDetails = _onStorageDetails;
    if (onDetails != null) {
      final row = _el(root, 'div');
      _flexRow(row, gap: '8px');
      // Push the refresh to the far right so it isn't next to the link — no
      // mis-taps between the two.
      _style(row, 'justifyContent', 'space-between');
      _style(row, 'marginTop', '6px');

      final link = _el(row, 'span', text: S.storageDetails);
      _style(link, 'fontSize', '12px');
      _style(link, 'color', 'var(--text-accent)');
      _style(link, 'cursor', 'pointer');
      _onClick(link, onDetails);

      // Small refresh for the managed usage meter (self-host/BYO have none).
      if (_onFetchUsage != null) {
        final refresh = _el(row, 'span', text: _usageFetching ? '↻…' : '↻');
        _style(refresh, 'fontSize', '12px');
        _style(refresh, 'color', 'var(--text-muted)');
        _style(refresh, 'cursor', _usageFetching ? 'default' : 'pointer');
        jsu.setProperty(refresh, 'aria-label', S.refreshStorageUsage);
        if (!_usageFetching) _onClick(refresh, _refreshUsage);
      }
    }

    // ── Text-merge trust line ──
    final merge = _el(root, 'div', text: S.textMergesLine);
    _style(merge, 'fontSize', '12px');
    _style(merge, 'color', 'var(--text-muted)');
    _style(merge, 'marginTop', '10px');

    // ── Report ──
    if (_uploaded > 0 || _downloaded > 0) {
      final report = _el(
        root,
        'div',
        text: S.uploadDownloadReport(_uploaded, _downloaded),
      );
      _style(report, 'fontSize', '12px');
      _style(report, 'marginTop', '6px');
    }

    // ── Actions ──
    final actions = _el(root, 'div');
    _flexRow(actions, gap: '8px');
    _style(actions, 'marginTop', '12px');
    _style(actions, 'flexWrap', 'wrap');

    // When sync is stuck (offline / error / auth-expired) the primary control
    // becomes Reconnect — a Pause toggle is useless when we can't reach the
    // server, and the user's intent there is "get me back online". Otherwise the
    // single sync control is the Pause/Resume toggle (Resume highlighted so a
    // paused vault is obviously actionable).
    final status = _effective();
    final stuck = !_isPaused() &&
        (status == _Status.offline ||
            status == _Status.error ||
            status == _Status.authExpired);
    final onReconnect = _onReconnect;
    if (stuck && onReconnect != null) {
      final reconnectBtn = _el(actions, 'button', text: S.reconnect);
      jsu.setProperty(reconnectBtn, 'className', 'mod-cta');
      _onClick(reconnectBtn, onReconnect);
    } else {
      final pauseBtn = _el(
        actions,
        'button',
        text: _isPaused() ? S.resumeSync : S.pauseSync,
      );
      if (_isPaused()) jsu.setProperty(pauseBtn, 'className', 'mod-cta');
      _onClick(pauseBtn, _handleTogglePause);
    }

    final settingsBtn = _el(actions, 'button', text: S.settingsButton);
    _onClick(settingsBtn, _onOpenSettings);

    // ── Active transfers ──
    if (_transfers.isNotEmpty) {
      _sectionHeader(root, S.activeTransfers(_transfers.length));
      for (final entry in _transfers.entries) {
        _transferRow(root, entry.key, entry.value);
      }
    }

    // ── Recent activity ──
    if (_recent.isNotEmpty) {
      _sectionHeader(root, S.recent);
      for (final e in _recent) {
        final row = _el(root, 'div', text: '${e.up ? '↑' : '↓'} ${e.path}');
        _style(row, 'fontSize', '12px');
        _style(row, 'padding', '1px 0');
        _style(row, 'whiteSpace', 'nowrap');
        _style(row, 'overflow', 'hidden');
        _style(row, 'textOverflow', 'ellipsis');
      }
      final histBtn = _el(root, 'button', text: S.browseVersions);
      _style(histBtn, 'marginTop', '6px');
      _onClick(histBtn, _onBrowseVersions);
    }

    // ── Size-blocked files ──
    if (_blocked.isNotEmpty) {
      _sectionHeader(root, S.tooLargeToSync(_blocked.length));
      final hint = _el(root, 'div', text: S.tooLargeHint);
      _style(hint, 'fontSize', '12px');
      _style(hint, 'color', 'var(--text-muted)');
      _style(hint, 'marginBottom', '4px');
      final entries = _blocked.values.toList()
        ..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
      for (final b in entries.take(20)) {
        final row = _el(root, 'div');
        _style(row, 'fontSize', '12px');
        _style(row, 'padding', '2px 0');
        _el(row, 'div', text: b.path);
        final meta = _el(
          row,
          'div',
          text: S.blockedMeta(_bytes(b.sizeBytes), _bytes(b.limitBytes)),
        );
        _style(meta, 'color', 'var(--text-muted)');
      }
      if (_blocked.length > 20) {
        final more = _el(
          root,
          'div',
          text: S.andMore(_blocked.length - 20),
        );
        _style(more, 'fontSize', '12px');
        _style(more, 'color', 'var(--text-muted)');
      }
    }

    // ── Hard conflict / data-loss warnings ──
    if (_dataLoss.isNotEmpty) {
      _sectionHeader(root, S.conflictsLostContent(_dataLoss.length));
      for (final d in _dataLoss.reversed.take(20)) {
        final row = _el(root, 'div');
        _style(row, 'fontSize', '12px');
        _style(row, 'padding', '2px 0');
        final path = _el(row, 'div', text: d.path.isEmpty ? d.fileId : d.path);
        _style(path, 'color', 'var(--text-error)');
        final meta = _el(row, 'div', text: d.reason);
        _style(meta, 'color', 'var(--text-muted)');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _handleTogglePause() async {
    final next = !_isPaused();
    // _onSetPaused flips the shared pause flag synchronously (before its first
    // await), so an immediate re-render already reflects the new state.
    final done = _onSetPaused(next);
    _render();
    try {
      await done;
    } catch (e) {
      _log?.warning('sync panel: toggle pause failed: $e');
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

  void _kv(JSObject parent, String key, String value) {
    final row = _el(parent, 'div');
    _flexRow(row, gap: '8px');
    _style(row, 'justifyContent', 'space-between');
    _style(row, 'padding', '2px 0');
    final k = _el(row, 'span', text: key);
    _style(k, 'color', 'var(--text-muted)');
    final v = _el(row, 'span', text: value);
    _style(v, 'fontWeight', '500');
    _style(v, 'textAlign', 'right');
  }

  void _storageMeter(JSObject root, ({int usedBytes, int quotaBytes}) u) {
    final frac = (u.usedBytes / u.quotaBytes).clamp(0.0, 1.0);
    final near = frac >= 0.9;
    final wrap = _el(root, 'div');
    _style(wrap, 'marginTop', '10px');
    final head = _el(wrap, 'div');
    _flexRow(head, gap: '8px');
    _style(head, 'justifyContent', 'space-between');
    _style(head, 'fontSize', '12px');
    final title = _el(head, 'span', text: S.storageMeterTitle(_planLabel));
    _style(title, 'color', 'var(--text-muted)');
    _el(head, 'span', text: '${_bytes(u.usedBytes)} / ${_bytes(u.quotaBytes)}');
    final track = _el(wrap, 'div');
    _style(track, 'height', '6px');
    _style(track, 'borderRadius', '3px');
    _style(track, 'background', 'var(--background-modifier-border)');
    _style(track, 'marginTop', '4px');
    _style(track, 'overflow', 'hidden');
    final fill = _el(track, 'div');
    _style(fill, 'height', '100%');
    _style(fill, 'width', '${(frac * 100).toStringAsFixed(1)}%');
    _style(
      fill,
      'background',
      near ? 'var(--text-error)' : 'var(--interactive-accent)',
    );
  }

  void _transferRow(
    JSObject root,
    String path,
    ({bool upload, int sent, int total}) t,
  ) {
    final frac = t.total > 0 ? (t.sent / t.total).clamp(0.0, 1.0) : 0.0;
    final wrap = _el(root, 'div');
    _style(wrap, 'padding', '3px 0');

    final head = _el(wrap, 'div');
    _flexRow(head, gap: '8px');
    _style(head, 'justifyContent', 'space-between');
    _style(head, 'fontSize', '12px');
    final name = _el(head, 'span', text: '${t.upload ? '↑' : '↓'} $path');
    _style(name, 'whiteSpace', 'nowrap');
    _style(name, 'overflow', 'hidden');
    _style(name, 'textOverflow', 'ellipsis');
    final amount = _el(head, 'span',
        text: '${_bytes(t.sent)} / ${_bytes(t.total)}');
    _style(amount, 'flexShrink', '0');
    _style(amount, 'color', 'var(--text-muted)');

    final track = _el(wrap, 'div');
    _style(track, 'height', '4px');
    _style(track, 'borderRadius', '2px');
    _style(track, 'background', 'var(--background-modifier-border)');
    _style(track, 'marginTop', '3px');
    _style(track, 'overflow', 'hidden');
    final fill = _el(track, 'div');
    _style(fill, 'height', '100%');
    _style(fill, 'width', '${(frac * 100).toStringAsFixed(0)}%');
    _style(fill, 'background', 'var(--interactive-accent)');
  }

  void _sectionHeader(JSObject root, String text) {
    final h = _el(root, 'div', text: text);
    _style(h, 'fontWeight', '600');
    _style(h, 'fontSize', '13px');
    _style(h, 'marginTop', '16px');
    _style(h, 'marginBottom', '4px');
    _style(h, 'borderTop', '1px solid var(--background-modifier-border)');
    _style(h, 'paddingTop', '10px');
  }

  void _style(JSObject el, String prop, String value) {
    jsu.setProperty(jsu.getProperty<JSObject>(el, 'style'), prop, value);
  }

  void _setText(JSObject el, String text) {
    jsu.setProperty(el, 'textContent', text);
  }

  void _flexRow(JSObject el, {String gap = '6px'}) {
    _style(el, 'display', 'flex');
    _style(el, 'flexDirection', 'row');
    _style(el, 'alignItems', 'center');
    _style(el, 'gap', gap);
  }

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
  /// Priority: paused > hard blocker > live activity > connection state.
  /// Green ("ready") is reserved for a genuine connected-and-idle state.
  _Status _effective() {
    if (_isPaused()) return _Status.paused;
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
    if (_activity) return _Status.syncing;
    if (_connected) return _hasPending ? _Status.pending : _Status.ready;
    if (_connecting) return _Status.connecting;
    if (_everStarted) return _Status.offline;
    return _Status.stopped;
  }

  String _statusLabel() => switch (_effective()) {
    _Status.stopped => S.syncStopped,
    _Status.connecting => _connectAttempt <= 2 ? S.connecting : S.reconnecting,
    _Status.offline => S.offlineCantReach,
    _Status.ready => S.upToDate,
    _Status.pending => S.pendingChanges,
    _Status.syncing => _progress != null
        ? S.syncingProgress(_progress!.completed, _progress!.total)
        : S.syncingEllipsis,
    _Status.error => S.syncErrorStatus,
    _Status.authExpired => S.sessionExpiredStatus,
    _Status.subExpired => S.subscriptionRequiredStatus,
    _Status.paused => S.pausedStatus,
  };

  String _statusColor() => switch (_effective()) {
    // green — connected, nothing to do
    _Status.ready => 'rgb(48, 168, 96)',
    // amber — attention, resolves on its own (edits queued / connecting)
    _Status.pending => 'rgb(220, 180, 60)',
    _Status.connecting => 'rgb(200, 180, 90)',
    // blue — actively transferring
    _Status.syncing => 'rgb(48, 128, 240)',
    // orange — sync is blocked until connection/auth/subscription recovers
    _Status.offline => 'rgb(230, 110, 50)',
    _Status.authExpired => 'rgb(240, 150, 48)',
    _Status.subExpired => 'rgb(240, 150, 48)',
    // red — hard error
    _Status.error => 'rgb(220, 56, 56)',
    // grey — intentionally not running
    _Status.stopped => 'rgb(128, 128, 128)',
    _Status.paused => 'rgb(150, 150, 150)',
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
