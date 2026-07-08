import 'dart:async';
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart' as core;
import 'package:rpc_dart/logger.dart';

class ObsidianChangeProvider implements core.IChangeProvider {
  ObsidianChangeProvider(this._plugin, {LogScope? logger}) : _log = logger;

  final PluginHandle _plugin;
  final LogScope? _log;

  StreamController<core.FileChangeEvent>? _controller;
  StreamController<String>? _typingController;
  VaultEvents? _vaultEvents;
  JSObject? _editorChangeRef;
  final Map<String, Timer> _suppressionTimers = {};
  final Map<String, int> _suppressionCounts = {};

  @override
  void suppress(
    String path, {
    int count = 1,
    Duration holdFor = const Duration(seconds: 2),
  }) {
    _suppressionCounts[path] = (_suppressionCounts[path] ?? 0) + count;
    _suppressionTimers[path]?.cancel();
    _suppressionTimers[path] = Timer(holdFor, () {
      _suppressionTimers.remove(path);
      _suppressionCounts.remove(path);
    });
  }

  @override
  void unsuppress(String path) {
    _suppressionTimers[path]?.cancel();
    _suppressionTimers.remove(path);
    _suppressionCounts.remove(path);
  }

  bool _consumeSuppression(String path) {
    final remaining = _suppressionCounts[path];
    if (remaining == null || remaining <= 0) return false;
    if (remaining <= 1) {
      _suppressionCounts.remove(path);
      _suppressionTimers[path]?.cancel();
      _suppressionTimers.remove(path);
    } else {
      _suppressionCounts[path] = remaining - 1;
    }
    return true;
  }

  @override
  Stream<core.FileChangeEvent> get changes {
    _controller ??= StreamController<core.FileChangeEvent>.broadcast(
      onListen: _startVaultEvents,
      onCancel: _stopVaultEvents,
    );
    return _controller!.stream;
  }

  @override
  Stream<String> get typing {
    // Independent lifecycle from `changes`: editor-change attaches when
    // `typing` is first listened and detaches when its last listener
    // leaves. Previously editor-change was bound to the `changes` stream,
    // so `typing` silently never emitted unless `changes` was also
    // listened, and tearing down `changes` closed this controller out from
    // under a live typing subscriber.
    _typingController ??= StreamController<String>.broadcast(
      onListen: _attachEditorChangeListener,
      onCancel: _stopTyping,
    );
    return _typingController!.stream;
  }

  /// Subscribes to Obsidian's `editor-change` workspace event, which
  /// fires per keystroke (before any disk write). The active file is
  /// resolved from workspace.getActiveFile() — the event payload
  /// (editor + view) does not carry a path uniformly across Obsidian
  /// versions, but `getActiveFile()` is reliable.
  ///
  /// The returned EventRef is stored so `_stop` can call `workspace.offref`
  /// on it — `plugin.registerEvent` alone would only release on plugin
  /// unload, leaking duplicate handlers across engine start/stop cycles.
  void _attachEditorChangeListener() {
    final ws = _plugin.app.workspace;
    final handler = jsu.allowInterop((JSAny? _, JSAny? __) {
      if (_typingController == null || _typingController!.isClosed) return;
      final active = _plugin.app.workspace.getActiveFile();
      final path = active?.path;
      if (path == null || path.isEmpty) return;
      _typingController!.add(path);
    });
    // ignore: invalid_runtime_check_with_js_interop_types
    final ref = ws.on('editor-change', handler as JSFunction);
    _editorChangeRef = ref;
    _plugin.registerEvent(ref);
  }

  void _detachEditorChangeListener() {
    final ref = _editorChangeRef;
    if (ref == null) return;
    _editorChangeRef = null;
    // `offref` lives on the raw JS workspace, not the Dart WorkspaceHandle
    // wrapper — calling it on the wrapper throws "offref is not a function"
    // (uncaught, on every engine stop / plugin reload). Best-effort:
    // plugin.registerEvent still releases the handler on unload.
    try {
      final rawWs = jsu.getProperty<JSObject?>(_plugin.app.raw, 'workspace');
      if (rawWs != null) jsu.callMethod<void>(rawWs, 'offref', [ref]);
    } catch (_) {}
  }

  void _startVaultEvents() {
    _log?.info('ObsidianChangeProvider: attaching vault event listeners');
    final events = VaultEvents(_plugin)..attach();
    _vaultEvents = events;

    events.created.listen((e) {
      final suppressed = _consumeSuppression(e.file.path);
      _log?.info(
        'Obsidian event: CREATED ${e.file.path}${suppressed ? " [SUPPRESSED]" : ""}',
      );
      if (!suppressed) {
        _controller?.add(core.FileCreatedEvent(relativePath: e.file.path));
      }
    });

    events.modified.listen((e) {
      final suppressed = _consumeSuppression(e.file.path);
      _log?.info(
        'Obsidian event: MODIFIED ${e.file.path}${suppressed ? " [SUPPRESSED]" : ""}',
      );
      if (!suppressed) {
        _controller?.add(core.FileModifiedEvent(relativePath: e.file.path));
      }
    });

    events.deleted.listen((e) {
      final suppressed = _consumeSuppression(e.file.path);
      _log?.info(
        'Obsidian event: DELETED ${e.file.path}${suppressed ? " [SUPPRESSED]" : ""}',
      );
      if (!suppressed) {
        _controller?.add(core.FileDeletedEvent(relativePath: e.file.path));
      }
    });

    events.renamed.listen((e) {
      final oldPath = e.oldPath;
      if (oldPath != null) {
        final suppressed =
            _consumeSuppression(oldPath) || _consumeSuppression(e.file.path);
        _log?.info(
          'Obsidian event: RENAMED $oldPath -> ${e.file.path}${suppressed ? " [SUPPRESSED]" : ""}',
        );
        if (!suppressed) {
          _controller?.add(
            core.FileMovedEvent(fromPath: oldPath, toPath: e.file.path),
          );
        }
      } else {
        final suppressed = _consumeSuppression(e.file.path);
        _log?.info(
          'Obsidian event: RENAMED (no oldPath) ${e.file.path}${suppressed ? " [SUPPRESSED]" : ""}',
        );
        if (!suppressed) {
          _controller?.add(core.FileCreatedEvent(relativePath: e.file.path));
        }
      }
    });
  }

  void _stopVaultEvents() {
    _log?.info('ObsidianChangeProvider: detaching vault event listeners');
    _vaultEvents?.dispose();
    _vaultEvents = null;
    for (final timer in _suppressionTimers.values) {
      timer.cancel();
    }
    _suppressionTimers.clear();
    _suppressionCounts.clear();
    // Close before nulling so the broadcast controller and its onListen/
    // onCancel wiring are released, not leaked, each start/stop cycle.
    final controller = _controller;
    _controller = null;
    controller?.close();
  }

  void _stopTyping() {
    _detachEditorChangeListener();
    final controller = _typingController;
    _typingController = null;
    controller?.close();
  }
}
