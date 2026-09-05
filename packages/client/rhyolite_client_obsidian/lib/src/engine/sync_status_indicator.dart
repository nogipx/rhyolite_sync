// ignore_for_file: deprecated_member_use
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import 'sync_activity.dart';
import 'sync_status.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../i18n/i18n.dart';
import 'session_contracts.dart';

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
class SyncStatusIndicator implements SessionIndicator {
  SyncStatusIndicator({
    required PluginHandle plugin,
    LogScope? logger,
    void Function()? onTap,
    void Function()? onReconnect,
    bool Function()? settingsBusy,
    bool Function()? paused,
    bool Function()? blocked,
    SyncStatusModel? status,
  }) : _plugin = plugin,
       _log = logger,
       _onTap = onTap,
       _onReconnect = onReconnect,
       // Accepted rather than always built, so a host that also shows the
       // panel can hand both surfaces the SAME object. Two models folding the
       // same stream would agree today and be free to drift tomorrow, which is
       // the shape of the bug this replaced.
       _status =
           status ??
           SyncStatusModel(
             settingsBusy: settingsBusy,
             paused: paused,
             blocked: blocked,
           );

  final PluginHandle _plugin;
  final LogScope? _log;

  /// Click action. Defaults to opening settings; the plugin overrides it to
  /// reveal the docked sync panel.
  final void Function()? _onTap;

  /// Recovery action, run instead of [_onTap] when the dot is in a stuck state
  /// (offline / error / auth-expired). Lets the user force a reconnect+refresh
  /// by tapping the red dot they already reach for, without waiting for a DOM
  /// online/visibility event.
  final void Function()? _onReconnect;

  /// The shared answer to "is anything working" — see [SyncActivity]. Reached
  /// through the status model so there is exactly one of it.
  SyncActivity get _activity => _status.activity;

  static const _pluginId = 'rhyolite-sync';

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


  /// The engine is inside work the user must not interrupt. Held between the
  /// phase-specific events rather than inferred from their spacing — see
  /// [SyncBusy]. Guards the idle paint so green never means "done" while a
  /// download is still running.

  /// The status, shared with the panel. Not a second reading of the same
  /// events — the same object's answer, so the two cannot disagree.
  final SyncStatusModel _status;

  /// True while `.obsidian` settings sync is in flight. Surfaced as a subtle
  /// overlay only when notes sync is otherwise idle — notes activity, errors
  /// and auth/sub states always dominate the single dot.

  void init() {
    final mobile = _detectMobile();
    _log?.info('sync indicator: platform=${mobile ? "mobile" : "desktop"}');
    if (mobile) {
      _initFloating();
    } else {
      _initStatusBar();
    }
    _repaint();
    // Repaints when the SHARED model says the answer moved. Not a second
    // subscription to the event stream: the model folds it once, and a surface
    // that folded it again would be told nothing had changed and would sit
    // there stale — which is precisely how the dot stopped updating at all.
    _removeStatusListener = _status.addListener(_repaint);
  }

  void Function()? _removeStatusListener;

  @override
  void dispose() {
    // Only our own listener. The model belongs to whoever built it — the
    // panel, in the plugin — and outlives this surface.
    _removeStatusListener?.call();
    _removeStatusListener = null;
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
    // iOS floats the pill much higher than Android with the same rule: the
    // home-indicator safe-area inset (~34px) plus 14px pushes it well up the
    // screen. On iPhone drop the inset and sit near the bottom edge; Android
    // keeps the inset-aware offset (looks right there).
    final isAndroid = _userAgent().contains('Android');
    jsu.setProperty(
      style,
      'bottom',
      isAndroid ? 'calc(env(safe-area-inset-bottom, 0px) + 14px)' : '8px',
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
    final handler = jsu.allowInterop((JSAny? _) {
      // In a stuck state, the tap becomes "reconnect now" — the dot is the
      // surface the user instinctively reaches for when sync looks dead.
      final kind = _status.kind;
      final stuck =
          kind == SyncStatusKind.offline ||
          kind == SyncStatusKind.error ||
          kind == SyncStatusKind.authExpired;
      final onReconnect = _onReconnect;
      if (stuck && onReconnect != null) {
        _log?.info('sync indicator: tap in $kind — reconnecting');
        onReconnect();
        return;
      }
      final onTap = _onTap;
      onTap != null ? onTap() : _openSettings();
    });
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

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  /// Called by the settings-sync driver as a `.obsidian` sync starts/ends.
  /// Repaints with the same logical notes state — the overlay only changes the
  @override
  void setSettingsActivity(bool active) {
    // The VALUE comes from [SyncActivity] through the model, which reads it
    // live; this is only the nudge to repaint at the moment it changes.
    //
    // Everyone, not just this surface. Settings work changes the SHARED
    // answer, and a nudge that repainted only whoever was told is the second
    // way these two came apart: the host tells one of them, and the other sits
    // on the previous answer until an unrelated event happens along.
    _status.notifyListeners();
  }

  static const _settingsColor = 'rgb(48, 128, 240)';

  void _repaint() {
    final kind = _status.kind;
    final phase = _status.phase;
    final el = _container;
    final doc = _document;
    if (el == null || doc == null) return;
    // The tint distinguishes settings-only work from the engine's, and it is
    // only ever a tint: the STATE is busy either way, so this can no longer
    // make the dot read as resting. Anything louder than settings — progress,
    // errors, auth — still dominates.
    final overlay =
        _activity.settingsBusy &&
        !_activity.engineBusy &&
        kind == SyncStatusKind.syncing;
    final color = overlay
        ? _settingsColor
        : _colorFor(kind, phase, hasPending: _status.hasPending);
    final label = overlay ? S.overlaySettings : _labelFor(phase);
    final glow = overlay
        ? '0 0 0 1px rgba(0,0,0,0.18), 0 0 6px '
              '${_settingsColor.replaceFirst('rgb(', 'rgba(').replaceFirst(')', ',0.7)')}'
        : _glowFor(kind, color);

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
      overlay ? S.tipSyncingSettings : _tooltipFor(kind, phase),
    );
  }

  /// No revert timers any more, and none needed.
  ///
  /// A per-file flash used to be painted and then unpainted a few seconds
  /// later, which meant guessing what to fall back TO — and the guess was the
  /// resting state, which is how a finished push repainted a disconnected
  /// vault green. A phase now lives exactly as long as the work does: the
  /// model only reports one while the status is `syncing`, and `syncing`
  /// requires a connection and something in flight.

  void _openSettings() {
    final setting = jsu.getProperty<Object?>(_plugin.app.raw, 'setting');
    if (setting == null) return;
    jsu.callMethod<void>(setting, 'open', []);
    jsu.callMethod<void>(setting, 'openTabById', [_pluginId]);
  }

  // ---------------------------------------------------------------------------
  // State → presentation
  // ---------------------------------------------------------------------------

  String _labelFor(SyncPhase phase) {
    // Only progress-bearing states get a label — the dot colour carries
    // the rest. Counters (`up 3/47` etc.) are kept because they prove
    // long-running operations are alive; one-shot states (off, idle,
    // pushing without a counter, error, auth, sub) would just be noise.
    final p = _status.progress;
    // Only show the counter when there's more than one item to process
    // — `up 1/1` adds no information over the dot colour.
    if (p == null || p.total <= 1) return '';
    return switch (phase) {
      SyncPhase.uploading => S.labelUp(p.completed, p.total),
      SyncPhase.downloading => S.labelDown(p.completed, p.total),
      SyncPhase.repairing => S.labelRepair(p.completed, p.total),
      _ => '',
    };
  }

  String _tooltipFor(SyncStatusKind kind, SyncPhase phase) {
    final p = _status.progress;
    if (p != null) {
      switch (phase) {
        case SyncPhase.uploading:
          return S.tipUploading(p.completed, p.total);
        case SyncPhase.downloading:
          return S.tipDownloading(p.completed, p.total);
        case SyncPhase.repairing:
          return S.tipRepairing(p.completed, p.total);
        default:
          break;
      }
    }
    // Phase before status, but only INSIDE syncing — the model refuses to
    // report a phase in any other status, so this cannot describe work over a
    // vault we cannot reach.
    final byPhase = switch (phase) {
      SyncPhase.pushing => S.tipUploadingChanges,
      SyncPhase.pulling => S.tipDownloadingChanges,
      SyncPhase.uploading => S.tipUploadingInitial,
      SyncPhase.downloading => S.tipDownloadingFiles,
      SyncPhase.repairing => S.tipRepairingVault,
      SyncPhase.none => null,
    };
    if (byPhase != null) return byPhase;
    return switch (kind) {
      SyncStatusKind.stopped => S.tipStopped,
      SyncStatusKind.paused => S.tipStopped,
      SyncStatusKind.blocked => S.tipStopped,
      SyncStatusKind.offline => S.tipOffline,
      SyncStatusKind.connecting => S.tipConnecting,
      SyncStatusKind.ready => S.tipConnected,
      SyncStatusKind.pending => S.tipConnected,
      // Working, but no phase has reported yet — the generic busy gap the
      // engine's SyncBusy exists to cover.
      SyncStatusKind.syncing => S.tipUploadingChanges,
      SyncStatusKind.error => S.tipError,
      SyncStatusKind.authExpired => S.tipAuthExpired,
      SyncStatusKind.subExpired => S.tipSubExpired,
    };
  }

  /// The colour, from the table the panel's stylesheet is generated from.
  /// Not a copy of it — the same map.
  static String _colorFor(
    SyncStatusKind kind,
    SyncPhase phase, {
    required bool hasPending,
  }) => syncToneColor[toneFor(kind, phase, hasPending: hasPending)]!;

  static String _glowFor(SyncStatusKind kind, String color) {
    const baseShadow = '0 0 0 1px rgba(0,0,0,0.18)';
    // Everything that wants attention glows; the two resting answers do not.
    final active = switch (kind) {
      SyncStatusKind.stopped ||
      SyncStatusKind.ready ||
      SyncStatusKind.pending => false,
      _ => true,
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

  /// Best-effort navigator.userAgent, '' on failure. Used to place the floating
  /// pill differently on iOS vs Android.
  static String _userAgent() {
    try {
      final nav = jsu.getProperty<JSObject?>(globalContext, 'navigator');
      if (nav == null) return '';
      return jsu.getProperty<String?>(nav, 'userAgent') ?? '';
    } catch (_) {
      return '';
    }
  }
}

