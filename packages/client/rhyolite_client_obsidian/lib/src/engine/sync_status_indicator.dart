// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

import 'server_rejections.dart';

/// Unified sync state indicator — a coloured dot followed by a short
/// progress label.
///
/// Rendering surface picks itself by platform:
///
/// - **Desktop**: Obsidian's status bar item. Native placement,
///   keyboard navigation, theme-consistent.
/// - **Mobile**: floating fixed-position pill in the bottom-right
///   corner. Obsidian Mobile hides the status bar entirely, and ribbon
///   icons live behind the slide-out panel, so a body-attached element
///   is the only persistent surface.
///
/// Either way the content is identical: a single coloured dot + a
/// terse status label that grows to include progress counts during
/// initial upload/download. Click opens settings.
class SyncStatusIndicator {
  SyncStatusIndicator({
    required PluginHandle plugin,
    required ISyncEngine engine,
    LogScope? logger,
  }) : _plugin = plugin,
       _engine = engine,
       _log = logger;

  final PluginHandle _plugin;
  final ISyncEngine _engine;
  final LogScope? _log;

  static const _pluginId = 'rhyolite_sync';
  static const _revertDelay = Duration(seconds: 3);
  static const _errorRevertDelay = Duration(seconds: 5);

  /// Outer container: status bar item element on desktop, floating
  /// `<div>` on mobile.
  JSObject? _container;

  /// Cached `Document` — needed for createElement on every state
  /// transition. Fetched once at init via the container's
  /// `ownerDocument` so we don't depend on `globalContext.document`
  /// at hot-path time.
  JSObject? _document;

  /// Set when we appended a floating element to body — used in
  /// dispose() to remove it cleanly.
  JSObject? _floatingParent;

  StreamSubscription<SyncEngineEvent>? _sub;
  Timer? _revertTimer;
  ({int completed, int total})? _progress;

  /// True while the engine has local edits it hasn't pushed yet.
  /// Drives a distinct dot colour at idle so the user knows their
  /// work hasn't reached the server. Sticky between SyncPending events.
  bool _hasPending = false;

  /// Last state passed to [_set]. Needed so SyncPending can repaint
  /// the dot without forcing a logical state transition.
  _State _currentState = _State.off;

  /// True while `.obsidian` settings sync is in flight. Surfaced as a subtle
  /// overlay only when notes sync is otherwise idle — notes activity, errors
  /// and auth/sub states always dominate the single dot.
  bool _settingsSyncing = false;

  void init() {
    final mobile = _detectMobile();
    _log?.info('sync indicator: platform=${mobile ? "mobile" : "desktop"}');
    if (mobile) {
      _initFloating();
    } else {
      _initStatusBar();
    }
    _set(_State.off);
    _sub = _engine.events.listen(_onEvent);
  }

  void dispose() {
    _sub?.cancel();
    _revertTimer?.cancel();
    final parent = _floatingParent;
    final el = _container;
    if (parent != null && el != null) {
      try {
        jsu.callMethod<void>(parent, 'removeChild', [el]);
      } catch (_) {}
    }
    _container = null;
    _floatingParent = null;
  }

  // ---------------------------------------------------------------------------
  // Platform-specific setup
  // ---------------------------------------------------------------------------

  void _initStatusBar() {
    final item = _plugin.addStatusBarItem();
    _container = item;
    _document = jsu.getProperty<JSObject?>(item, 'ownerDocument');
    final style = jsu.getProperty<JSObject>(item, 'style');
    jsu.setProperty(style, 'cursor', 'pointer');
    _registerClick(item);
    jsu.setProperty(item, 'aria-label', 'Rhyolite Sync');
    jsu.setProperty(item, 'role', 'button');
  }

  void _initFloating() {
    final document = _fetchDocument();
    if (document == null) {
      _log?.warning('sync indicator: no document available');
      return;
    }
    final body = jsu.getProperty<JSObject?>(document, 'body');
    if (body == null) {
      _log?.warning('sync indicator: no body available');
      return;
    }
    _document = document;
    final div = jsu.callMethod<JSObject>(document, 'createElement', ['div']);
    _container = div;
    _floatingParent = body;

    final style = jsu.getProperty<JSObject>(div, 'style');
    jsu.setProperty(style, 'position', 'fixed');
    jsu.setProperty(style, 'zIndex', '300');
    jsu.setProperty(
      style,
      'bottom',
      'calc(env(safe-area-inset-bottom, 0px) + 14px)',
    );
    jsu.setProperty(
      style,
      'right',
      'calc(env(safe-area-inset-right, 0px) + 14px)',
    );
    jsu.setProperty(style, 'padding', '4px 8px');
    jsu.setProperty(style, 'borderRadius', '12px');
    jsu.setProperty(style, 'background', 'var(--background-secondary)');
    jsu.setProperty(
      style,
      'boxShadow',
      '0 1px 4px rgba(0,0,0,0.18), 0 0 0 1px rgba(0,0,0,0.08)',
    );
    jsu.setProperty(style, 'fontSize', '11px');
    jsu.setProperty(style, 'cursor', 'pointer');
    jsu.setProperty(style, 'userSelect', 'none');
    jsu.setProperty(style, 'pointerEvents', 'auto');
    jsu.setProperty(style, 'transition', 'background 150ms ease');

    jsu.setProperty(div, 'aria-label', 'Rhyolite Sync');
    jsu.setProperty(div, 'role', 'button');
    _registerClick(div);

    jsu.callMethod<void>(body, 'appendChild', [div]);
  }

  void _registerClick(JSObject el) {
    final handler = jsu.allowInterop((JSAny? _) => _openSettings());
    // Route the listener through Obsidian's plugin lifecycle so the
    // handler is auto-unregistered when the plugin unloads — required
    // by Obsidian's community plugin review (no leaked listeners on
    // disable).
    jsu.callMethod<void>(_plugin.raw, 'registerDomEvent', [
      el,
      'click',
      handler,
    ]);
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  void _onEvent(SyncEngineEvent event) {
    switch (event) {
      case SyncStarted():
        _set(_State.connecting);
      case SyncStopped():
        _cancelRevert();
        _set(_State.off);
      case SyncConnecting():
        _set(_State.connecting);
      case SyncConnected():
        _cancelRevert();
        _set(_State.idle);
      case SyncDisconnected():
        _cancelRevert();
        _set(_State.off);
      case SyncPushing():
        _cancelRevert();
        _set(_State.pushing);
      case SyncPulling():
        _cancelRevert();
        _set(_State.pulling);
      case SyncPending(:final hasPending):
        if (hasPending == _hasPending) break;
        _hasPending = hasPending;
        // Repaint with the same logical state — only the idle colour
        // changes (amber vs green), so we don't want a state transition.
        _set(_currentState);
      case SyncFilePushed():
        _setWithRevert(_State.pushing, _revertDelay);
      case SyncFilePulled():
        _setWithRevert(_State.pulling, _revertDelay);
      case SyncStartupBlobUploadProgress(:final completed, :final total):
        _cancelRevert();
        _progress = (completed: completed, total: total);
        _set(_State.uploading);
      case SyncStartupBlobUploadDone():
        _progress = null;
        _set(_State.idle);
      case SyncBlobDownloadProgress(:final completed, :final total):
        _cancelRevert();
        _progress = (completed: completed, total: total);
        _set(_State.downloading);
      case SyncBlobDownloadDone():
        _progress = null;
        _set(_State.idle);
      case SyncRepairStarted(:final totalFiles):
        _cancelRevert();
        _progress = (completed: 0, total: totalFiles);
        _set(_State.repairing);
      case SyncRepairProgress(:final completed, :final total):
        _cancelRevert();
        _progress = (completed: completed, total: total);
        _set(_State.repairing);
      case SyncRepairDone():
        _progress = null;
        _set(_State.idle);
      case SyncError():
        _setWithRevert(_State.error, _errorRevertDelay);
      case SessionExpired():
        _cancelRevert();
        _set(_State.authExpired);
      case SubscriptionRequired():
        _cancelRevert();
        _set(_State.subExpired);
      // Any other policy/auth rejection (managed storage unavailable,
      // quota exceeded, permission denied, etc.) presents as "sync paused
      // due to subscription/policy state" — same visual as SubscriptionRequired
      // until we add per-reason copy. Engine has already stopped, so the
      // dot stays orange until the user fixes the underlying state.
      case SyncServerRejected(:final code)
          when code.startsWith('auth.') || code.startsWith('app_policy.'):
        _cancelRevert();
        _set(_State.subExpired);
      default:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  /// Called by the settings-sync driver as a `.obsidian` sync starts/ends.
  /// Repaints with the same logical notes state — the overlay only changes the
  /// dot when notes sync is idle, so this never forces a state transition.
  void setSettingsActivity(bool active) {
    if (active == _settingsSyncing) return;
    _settingsSyncing = active;
    _set(_currentState);
  }

  static const _settingsColor = 'rgb(48, 128, 240)';

  void _set(_State state) {
    _currentState = state;
    final el = _container;
    final doc = _document;
    if (el == null || doc == null) return;
    // Settings-sync overlay wins only over idle — notes activity, progress,
    // errors and auth/sub all dominate the single dot.
    final overlay = _settingsSyncing && state == _State.idle;
    final color = overlay
        ? _settingsColor
        : _colorFor(state, hasPending: _hasPending);
    final label = overlay ? 'settings' : _labelFor(state);
    final glow = overlay
        ? '0 0 0 1px rgba(0,0,0,0.18), 0 0 6px '
              '${_settingsColor.replaceFirst('rgb(', 'rgba(').replaceFirst(')', ',0.7)')}'
        : _glowFor(state, color);

    // DOM-API construction — required by Obsidian community plugin
    // review (no innerHTML / outerHTML / insertAdjacentHTML). The
    // tree we build is the same as the old html string:
    //   <span flex-row>[dot][label?]</span>
    final wrap = jsu.callMethod<JSObject>(doc, 'createElement', ['span']);
    final wrapStyle = jsu.getProperty<JSObject>(wrap, 'style');
    jsu.setProperty(wrapStyle, 'display', 'inline-flex');
    jsu.setProperty(wrapStyle, 'alignItems', 'center');
    jsu.setProperty(wrapStyle, 'gap', '6px');
    jsu.setProperty(wrapStyle, 'lineHeight', '1');

    final dot = jsu.callMethod<JSObject>(doc, 'createElement', ['span']);
    final dotStyle = jsu.getProperty<JSObject>(dot, 'style');
    jsu.setProperty(dotStyle, 'display', 'inline-block');
    jsu.setProperty(dotStyle, 'width', '9px');
    jsu.setProperty(dotStyle, 'height', '9px');
    jsu.setProperty(dotStyle, 'borderRadius', '50%');
    jsu.setProperty(dotStyle, 'background', color);
    jsu.setProperty(dotStyle, 'boxShadow', glow);
    jsu.setProperty(dotStyle, 'flexShrink', '0');
    jsu.callMethod<void>(wrap, 'appendChild', [dot]);

    if (label.isNotEmpty) {
      final lbl = jsu.callMethod<JSObject>(doc, 'createElement', ['span']);
      // textContent — safe sink that never parses HTML.
      jsu.setProperty(lbl, 'textContent', label);
      jsu.callMethod<void>(wrap, 'appendChild', [lbl]);
    }

    // Atomic replace — clears any prior child structure in one step.
    jsu.callMethod<void>(el, 'replaceChildren', [wrap]);
    jsu.setProperty(
      el,
      'aria-label',
      overlay ? 'Rhyolite Sync: syncing settings' : _tooltipFor(state),
    );
  }

  void _setWithRevert(_State state, Duration delay) {
    _cancelRevert();
    _set(state);
    _revertTimer = Timer(delay, () => _set(_State.idle));
  }

  void _cancelRevert() {
    _revertTimer?.cancel();
    _revertTimer = null;
  }

  void _openSettings() {
    final setting = jsu.getProperty<Object?>(_plugin.app.raw, 'setting');
    if (setting == null) return;
    jsu.callMethod<void>(setting, 'open', []);
    jsu.callMethod<void>(setting, 'openTabById', [_pluginId]);
  }

  // ---------------------------------------------------------------------------
  // State → presentation
  // ---------------------------------------------------------------------------

  String _labelFor(_State state) {
    // Only progress-bearing states get a label — the dot colour carries
    // the rest. Counters (`up 3/47` etc.) are kept because they prove
    // long-running operations are alive; one-shot states (off, idle,
    // pushing without a counter, error, auth, sub) would just be noise.
    final p = _progress;
    // Only show the counter when there's more than one item to process
    // — `up 1/1` adds no information over the dot colour.
    if (p == null || p.total <= 1) return '';
    return switch (state) {
      _State.uploading => 'up ${p.completed}/${p.total}',
      _State.downloading => 'down ${p.completed}/${p.total}',
      _State.repairing => 'repair ${p.completed}/${p.total}',
      _ => '',
    };
  }

  String _tooltipFor(_State state) {
    final p = _progress;
    if (state == _State.uploading && p != null) {
      return 'Rhyolite Sync: uploading ${p.completed} of ${p.total} files';
    }
    if (state == _State.downloading && p != null) {
      return 'Rhyolite Sync: downloading ${p.completed} of ${p.total} files';
    }
    if (state == _State.repairing && p != null) {
      return 'Rhyolite Sync: repairing ${p.completed} of ${p.total} files '
          '— rebuilding sync state, this can take a while';
    }
    return switch (state) {
      _State.off => 'Rhyolite Sync: stopped',
      _State.connecting => 'Rhyolite Sync: connecting…',
      _State.idle => 'Rhyolite Sync: connected',
      _State.pushing => 'Rhyolite Sync: uploading changes',
      _State.pulling => 'Rhyolite Sync: downloading changes',
      _State.uploading => 'Rhyolite Sync: uploading initial files',
      _State.downloading => 'Rhyolite Sync: downloading files',
      _State.repairing =>
        'Rhyolite Sync: repairing vault — rebuilding sync state',
      _State.error => 'Rhyolite Sync: error — tap to open settings',
      _State.authExpired =>
        'Rhyolite Sync: session expired — tap to open settings',
      _State.subExpired =>
        'Rhyolite Sync: subscription expired — tap to open settings',
    };
  }

  static String _colorFor(_State state, {required bool hasPending}) =>
      switch (state) {
        _State.off => 'rgb(128, 128, 128)',
        _State.connecting => 'rgb(180, 180, 180)',
        // Amber when idle-with-pending — local edits exist that the
        // engine hasn't pushed yet. Distinct from orange (auth/sub)
        // since user can fix it just by waiting for sync.
        _State.idle => hasPending ? 'rgb(220, 180, 60)' : 'rgb(48, 168, 96)',
        _State.pushing => 'rgb(48, 128, 240)',
        _State.pulling => 'rgb(48, 128, 240)',
        _State.uploading => 'rgb(48, 128, 240)',
        _State.downloading => 'rgb(48, 128, 240)',
        _State.repairing => 'rgb(160, 96, 220)', // purple — distinct from sync
        _State.error => 'rgb(220, 56, 56)',
        _State.authExpired => 'rgb(240, 150, 48)',
        _State.subExpired => 'rgb(240, 150, 48)',
      };

  static String _glowFor(_State state, String color) {
    const baseShadow = '0 0 0 1px rgba(0,0,0,0.18)';
    final active = switch (state) {
      _State.pushing ||
      _State.pulling ||
      _State.uploading ||
      _State.downloading ||
      _State.repairing ||
      _State.connecting ||
      _State.error ||
      _State.authExpired ||
      _State.subExpired => true,
      _State.off || _State.idle => false,
    };
    if (!active) return baseShadow;
    // Soften the colour into the glow.
    final tint = color.replaceFirst('rgb(', 'rgba(').replaceFirst(')', ',0.7)');
    return '$baseShadow, 0 0 6px $tint';
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  bool _detectMobile() {
    // Preferred: Obsidian's documented `app.isMobile` flag.
    try {
      final flag = jsu.getProperty<bool?>(_plugin.app.raw, 'isMobile');
      if (flag != null) return flag;
    } catch (_) {}
    // Fallback: user-agent sniff. Not perfect but reliable for
    // distinguishing Obsidian Mobile from desktop in the field.
    try {
      final nav = jsu.getProperty<JSObject?>(globalContext, 'navigator');
      if (nav != null) {
        final ua = jsu.getProperty<String?>(nav, 'userAgent') ?? '';
        return ua.contains('Mobi') || ua.contains('Android');
      }
    } catch (_) {}
    return false;
  }

  static JSObject? _fetchDocument() {
    try {
      return jsu.getProperty<JSObject>(globalContext, 'document');
    } catch (_) {
      return null;
    }
  }
}

enum _State {
  off,
  connecting,
  idle,
  pushing,
  pulling,
  uploading,
  downloading,
  repairing,
  error,
  authExpired,
  subExpired,
}
