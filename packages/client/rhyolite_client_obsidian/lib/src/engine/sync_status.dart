import 'dart:async';

import 'package:rhyolite_sync/rhyolite_sync.dart';

import 'server_rejections.dart';
import 'sync_activity.dart';

/// The one status both the panel and the status dot show.
///
/// Extends the argument [SyncActivity] already makes for "is anything
/// working": two rules that must agree are better replaced by one rule. That
/// class settled activity; connection was left duplicated, and the two
/// surfaces disagreed on it in the way that is worst — quietly, and in the
/// reassuring direction.
///
/// With no network the panel said "not connected" while the dot a few
/// centimetres below it was green. Not because they read different events —
/// both fold the same four — but because they combine them differently. The
/// panel keeps connection as its own flag and applies precedence when it
/// renders. The dot was a state machine in which the last event won, so
/// `SyncDisconnected` painted it orange and the next `SyncBusy` (local work
/// carries on perfectly well with no server) painted it green again. Every
/// arm that resolved to the resting state did this: a finished push, a
/// finished download, a finished repair.
///
/// So the fix is not a shared flag, it is a shared SHAPE. Status and phase are
/// separated here because they answer different questions and only one of them
/// is a claim about the world:
///
///   * [SyncStatusKind] is the claim, and both surfaces must agree on it.
///   * [SyncPhase] is presentation detail — which icon the dot spins — and it
///     is deliberately unable to overrule the connection. That inability is
///     the bug fix, expressed as a type rather than as care.
///
/// Presentation stays with each surface. This owns what the state IS; colours,
/// copy, revert timers and spinners are how each one chooses to show it.
enum SyncStatusKind {
  /// Never started, or deliberately stopped.
  stopped,

  /// The user paused sync.
  paused,

  /// A precondition is missing — not signed in, no vault, locked. Outranks
  /// everything below: the engine is not merely disconnected, it was never
  /// able to run, and no amount of reconnecting changes that.
  blocked,

  /// The session ended and cannot be renewed without the user.
  authExpired,

  /// Subscription or policy stopped sync.
  subExpired,

  /// A transient failure the next live connection clears.
  error,

  /// Reaching for the server.
  connecting,

  /// The engine was running and lost the backend.
  offline,

  /// Connected and working.
  syncing,

  /// Connected, idle, with local changes not yet sent.
  pending,

  /// Connected, idle, nothing outstanding. The only genuinely green state.
  ready,
}

/// What kind of work is in flight, when [SyncStatusKind.syncing] is showing.
///
/// Never a status of its own. A phase that could stand in for one is exactly
/// how a dot came to be green while the vault was unreachable.
enum SyncPhase { none, pushing, pulling, uploading, downloading, repairing }

/// Sticky sync-blocking condition, cleared when a live connection is
/// (re)established (error) or the underlying state is fixed (auth/sub).
enum SyncBlocker { none, error, auth, sub }

/// Folds engine events into the status both surfaces render.
///
/// Host state that this cannot observe — paused, missing preconditions — is
/// READ through predicates rather than folded, for the reason [SyncActivity]
/// gives: a surface built after a transition still gets the truth, where one
/// holding a pushed flag keeps whatever it was born with.
class SyncStatusModel {
  SyncStatusModel({
    bool Function()? settingsBusy,
    bool Function()? paused,
    bool Function()? blocked,
    SyncActivity? activity,
    DateTime Function()? now,
  }) : activity = activity ?? SyncActivity(settingsBusy: settingsBusy),
       _paused = paused,
       _blocked = blocked,
       _now = now ?? DateTime.now;

  final DateTime Function() _now;

  StreamSubscription<SyncEngineEvent>? _sub;
  final List<void Function()> _listeners = [];

  /// Folds [events] into this model, once.
  ///
  /// The subscription lives HERE and not in the surfaces, because when both of
  /// them held one and both called [observe], the same event was folded twice:
  /// whichever listener ran second saw a model that had already moved, was
  /// told "nothing changed", and did not repaint. The panel subscribed first,
  /// so the dot simply stopped updating — a worse disagreement than the one
  /// that started all this, and introduced while fixing it.
  ///
  /// One fold, one notification, no ordering to get right.
  void bind(Stream<SyncEngineEvent> events) {
    // Refused rather than replaced. A second bind means a second owner thinks
    // it is responsible for feeding this model, and the version of that
    // mistake that already happened — two surfaces folding one model — was
    // invisible: the second folder was simply told nothing had changed, and
    // the surface it belonged to stopped repainting. Loud beats subtle.
    if (_sub != null) {
      throw StateError(
        'SyncStatusModel is already bound. It folds the stream once; '
        'surfaces observe it through addListener.',
      );
    }
    _sub = events.listen((e) {
      if (_fold(e)) notifyListeners();
    });
  }

  /// Registers [listener] to repaint. Returns a function that removes it.
  void Function() addListener(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Repaint everyone. Called on a fold that moved the answer, and by hosts
  /// after they change something this READS rather than folds — pausing,
  /// resolving a start block, settings work starting.
  void notifyListeners() {
    // Copied: a listener that removes itself while we iterate is legitimate
    // (a surface being disposed mid-render) and must not break the rest.
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _listeners.clear();
  }

  /// How long a transient error stays on screen.
  ///
  /// It expires rather than being cleared by a timer, so there is no callback
  /// to wire and nothing to cancel: whoever asks after the deadline is simply
  /// told there is no error. Both surfaces used to run their own timer for
  /// this — six seconds in the panel, five in the dot — which is two answers
  /// to one question, on the same screen, differing by a second.
  ///
  /// A surface that wants the pixel to change at the exact moment can still
  /// set its own repaint nudge; being late only means showing red slightly
  /// longer, never showing green over a live fault.
  static const errorLinger = Duration(seconds: 6);

  DateTime? _errorAt;



  /// Shared with the surfaces so the debounce and the transfer set stay one
  /// object rather than two that drift.
  final SyncActivity activity;

  final bool Function()? _paused;
  final bool Function()? _blocked;

  bool _everStarted = false;
  bool _connected = false;
  bool _connecting = false;
  bool _resuming = false;
  bool _hasPending = false;
  SyncBlocker _blocker = SyncBlocker.none;
  SyncPhase _phase = SyncPhase.none;
  ({int completed, int total})? _progress;

  bool get everStarted => _everStarted;
  bool get connected => _connected;
  bool get hasPending => _hasPending;
  SyncBlocker get blocker => _blocker;
  ({int completed, int total})? get progress => _progress;

  /// The host is bringing the engine back after a resume; not yet connecting,
  /// but no longer honestly "offline" either.
  set resuming(bool value) => _resuming = value;

  /// What kind of work is in flight. Meaningful only while [kind] is
  /// [SyncStatusKind.syncing]; forced to [SyncPhase.none] otherwise so a
  /// caller cannot paint a spinner over a disconnected vault.
  SyncPhase get phase =>
      kind == SyncStatusKind.syncing ? _phase : SyncPhase.none;



  /// The single answer.
  ///
  /// Order is the whole content of this method. Work in progress outranks
  /// "connecting" and "up to date" — but NOT the connection checks below it,
  /// which is the ordering the status dot did not have.
  SyncStatusKind get kind {
    if (_paused?.call() ?? false) return SyncStatusKind.paused;
    if (_blocked?.call() ?? false) return SyncStatusKind.blocked;
    switch (_blocker) {
      case SyncBlocker.auth:
        return SyncStatusKind.authExpired;
      case SyncBlocker.sub:
        return SyncStatusKind.subExpired;
      case SyncBlocker.error:
        final at = _errorAt;
        if (at != null && _now().difference(at) < errorLinger) {
          return SyncStatusKind.error;
        }
        // Expired: the engine stays connected and keeps retrying, so a
        // transient failure must not sit red forever.
        break;
      case SyncBlocker.none:
        break;
    }
    if (!_everStarted && !_connecting && !_resuming) {
      return SyncStatusKind.stopped;
    }
    // Connection first among the remaining answers. Local work continues
    // perfectly well with no server, and reporting it as "syncing" — or worse,
    // letting it resolve to a resting green — is the contradiction this class
    // exists to make unrepresentable.
    if (!_connected) {
      if (_connecting || _resuming) return SyncStatusKind.connecting;
      return SyncStatusKind.offline;
    }
    if (activity.isWorking) return SyncStatusKind.syncing;
    return _hasPending ? SyncStatusKind.pending : SyncStatusKind.ready;
  }

  /// Folds one event. Returns whether the rendered answer changed, so a caller
  /// can repaint only when it did.
  ///
  /// For tests and for [bind]. Production code must not call this: a surface
  /// that folds the stream itself races the bound one, and whichever loses is
  /// told nothing changed and quietly stops repainting. Use [addListener].
  bool observeForTest(SyncEngineEvent event) => _fold(event);

  bool _fold(SyncEngineEvent event) {
    final beforeKind = kind;
    final beforePhase = phase;
    final beforeProgress = _progress;

    activity.observe(event);

    switch (event) {
      case SyncStarted():
        _resuming = false;
        _everStarted = true;
        _connecting = true;
        _connected = false;
        _blocker = SyncBlocker.none;
      case SyncConnecting():
        _connecting = true;
        _connected = false;
      case SyncConnected():
        _connected = true;
        _connecting = false;
        // A live connection clears a transient error, and only that one: auth
        // and subscription are fixed elsewhere or not at all.
        if (_blocker == SyncBlocker.error) {
          _blocker = SyncBlocker.none;
          _errorAt = null;
        }
      case SyncDisconnected():
        _connected = false;
        _connecting = false;
        _phase = SyncPhase.none;
        _progress = null;
      case SyncStopped():
        _everStarted = false;
        _connected = false;
        _connecting = false;
        _resuming = false;
        _phase = SyncPhase.none;
        _progress = null;
        _blocker = SyncBlocker.none;
      case SyncPending(:final hasPending):
        _hasPending = hasPending;
      case SyncPushing():
        _phase = SyncPhase.pushing;
        _progress = null;
      case SyncPulling():
        _phase = SyncPhase.pulling;
        _progress = null;
      case SyncFilePushed():
        _phase = SyncPhase.pushing;
      case SyncFilePulled():
        _phase = SyncPhase.pulling;
      case SyncStartupBlobUploadProgress(:final completed, :final total):
        _phase = SyncPhase.uploading;
        _progress = (completed: completed, total: total);
      case SyncStartupBlobUploadDone():
        _phase = SyncPhase.none;
        _progress = null;
      case SyncBlobDownloadProgress(:final completed, :final total):
        _phase = SyncPhase.downloading;
        _progress = (completed: completed, total: total);
      case SyncBlobDownloadDone():
        _phase = SyncPhase.none;
        _progress = null;
      case SyncRepairStarted(:final totalFiles):
        _phase = SyncPhase.repairing;
        _progress = (completed: 0, total: totalFiles);
      case SyncRepairProgress(:final completed, :final total):
        _phase = SyncPhase.repairing;
        _progress = (completed: completed, total: total);
      case SyncRepairDone():
        _phase = SyncPhase.none;
        _progress = null;
      case SessionExpired():
        _blocker = SyncBlocker.auth;
      case SubscriptionRequired():
        _blocker = SyncBlocker.sub;
      case SyncServerRejected(:final code)
          when code.startsWith('auth.') || code.startsWith('app_policy.'):
        _blocker = SyncBlocker.sub;
      case SyncError():
        _blocker = SyncBlocker.error;
        _errorAt = _now();
      default:
        break;
    }

    return kind != beforeKind ||
        phase != beforePhase ||
        _progress != beforeProgress;
  }
}

/// The visual identity of a status — the one thing the panel and the dot are
/// obliged to agree on down to the pixel.
///
/// A separate axis from [SyncStatusKind] because two of these are not statuses
/// at all: `repairing` is a phase the user must not mistake for ordinary sync,
/// and `pending` is `ready` with unsent work. Folding them in here is what
/// lets one table answer for both surfaces.
enum SyncTone {
  stopped,
  paused,
  blocked,
  connecting,
  offline,
  syncing,
  repairing,
  pending,
  ready,
  error,
  authExpired,
  subExpired,
}

/// The tone a status paints in. The ONLY place this is decided.
///
/// It used to be decided twice — a `switch` in the dot and a block of CSS in
/// the panel — and they had drifted three ways: connecting was
/// `rgb(200,180,90)` in one and `rgb(180,180,180)` in the other, paused was
/// 150 grey against 128, and a repair showed purple in the dot and ordinary
/// sync blue in the panel. Nobody changed those on purpose; two tables are
/// simply not a thing that stays equal.
SyncTone toneFor(
  SyncStatusKind kind,
  SyncPhase phase, {
  required bool hasPending,
}) => switch (kind) {
  SyncStatusKind.syncing =>
    phase == SyncPhase.repairing ? SyncTone.repairing : SyncTone.syncing,
  SyncStatusKind.ready => hasPending ? SyncTone.pending : SyncTone.ready,
  SyncStatusKind.pending => SyncTone.pending,
  SyncStatusKind.stopped => SyncTone.stopped,
  SyncStatusKind.paused => SyncTone.paused,
  SyncStatusKind.blocked => SyncTone.blocked,
  SyncStatusKind.connecting => SyncTone.connecting,
  SyncStatusKind.offline => SyncTone.offline,
  SyncStatusKind.error => SyncTone.error,
  SyncStatusKind.authExpired => SyncTone.authExpired,
  SyncStatusKind.subExpired => SyncTone.subExpired,
};

/// The colour of a tone. One table, read by the dot directly and by the
/// panel through the stylesheet it generates from it.
const Map<SyncTone, String> syncToneColor = {
  SyncTone.stopped: 'rgb(128, 128, 128)',
  SyncTone.paused: 'rgb(128, 128, 128)',
  // Something the user can act on, so it is as loud as an expired session
  // rather than as quiet as "stopped".
  SyncTone.blocked: 'rgb(240, 150, 48)',
  SyncTone.connecting: 'rgb(180, 180, 180)',
  SyncTone.offline: 'rgb(230, 110, 50)',
  SyncTone.syncing: 'rgb(48, 128, 240)',
  // Purple, distinct from ordinary sync: a repair rewrites files, and
  // mistaking it for a pull is the one confusion here with consequences.
  SyncTone.repairing: 'rgb(160, 96, 220)',
  // Amber: local edits the engine has not pushed yet. Distinct from the
  // orange of auth/sub, because waiting is all this one needs.
  SyncTone.pending: 'rgb(220, 180, 60)',
  SyncTone.ready: 'rgb(48, 168, 96)',
  SyncTone.error: 'rgb(220, 56, 56)',
  SyncTone.authExpired: 'rgb(240, 150, 48)',
  SyncTone.subExpired: 'rgb(240, 150, 48)',
};

/// The CSS class the panel carries for a tone.
///
/// Classes rather than inline styles, deliberately: the panel documents that
/// themes and snippets can override any of its colours, and an inline style
/// would quietly take that away. The declarations are GENERATED from
/// [syncToneColor] so the two cannot drift while the override stays possible.
String syncToneClass(SyncTone tone) => 'is-${tone.name.toLowerCase()}';

/// The `--rh-status` declarations, built from the one table.
String syncToneCss(String selector) => [
  for (final e in syncToneColor.entries)
    '$selector.${syncToneClass(e.key)} { --rh-status: ${e.value}; }',
].join('\n');
