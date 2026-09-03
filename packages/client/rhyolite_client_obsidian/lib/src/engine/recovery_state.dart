import 'package:rhyolite_sync/rhyolite_sync.dart';

/// What the ladder must do after an event, beyond updating what it remembers.
enum RecoveryStep {
  /// Nothing. Most events land here.
  none,

  /// The connection is back: stop the recovery timer.
  connected,

  /// The connection is gone: arm the recovery timer.
  disconnected,
}

/// What the recovery ladder remembers between attempts.
///
/// Every field here was a top-level variable, updated from inside one long
/// event listener. Folding them into [observe] is the point: the rules are
/// about the SEQUENCE of events, and a rule about sequences that is spelled out
/// as seven separate assignments in a callback can only be checked by reading
/// it. This can be driven.
///
/// The ladder acts on two facts a probe cannot supply on its own — whether the
/// engine is busy, and how long it has been silent. An engine that is emitting
/// is alive whatever a ping says, and unlike a ping that costs no round trip
/// and cannot be starved by the very work it reports on.
class RecoveryState {
  /// Backoff, in seconds, by attempt. Capped rather than unbounded: past a
  /// minute the user is better served by the status dot than by another
  /// silent retry.
  static const backoffSeconds = [5, 10, 20, 40, 60];

  /// Attempts in a row that achieved nothing. The cap exists to stop pointless
  /// retrying against a server that is down.
  static const maxSelfHealAttempts = 10;

  /// Consecutive "rebind the live session and restart" recoveries. Bounded so a
  /// rebind that does not actually fix the rejection cannot restart the engine
  /// on every cooldown.
  static const maxAuthRebinds = 3;

  /// At most one refresh per this, and one in flight at a time. A burst of
  /// `auth.*` rejections — every pending RPC failing at once — must not spawn a
  /// refresh grind loop.
  static const authRefreshCooldown = Duration(seconds: 8);

  // --- What the engine last said --------------------------------------------

  /// Whether the engine says it is busy.
  ///
  /// It guarantees this: `SyncBusy(true)` is raised for the whole startup
  /// pipeline and released in a `finally`, and the invariant is to fail toward
  /// stuck-busy rather than stuck-idle. So "busy" is trustworthy as "work is
  /// happening" — which is precisely what a probe cannot tell from "socket is
  /// dead".
  bool engineBusy = false;

  /// When the engine last emitted ANY event.
  DateTime? lastEventAt;

  /// Whether the last connection event said connected.
  bool online = false;

  /// Set when the blob backend refused this device, cleared when a file
  /// reaches the server.
  ///
  /// Sticky on purpose. A 401 is not a passing condition: every later edit is
  /// dropped the same way, and the whole failure used to live in one log
  /// warning while the engine went on pulling and looking healthy. Cleared by
  /// a successful push because that is proof the storage takes our writes —
  /// including when the fix happened on the storage's side and nothing here
  /// was touched. Without that the panel would name a precondition the user
  /// had already met.
  bool storageRefused = false;

  // --- What the ladder has spent ---------------------------------------------

  int selfHealAttempt = 0;
  bool authRefreshInFlight = false;
  DateTime? lastAuthRefreshAt;
  int authRebindAttempts = 0;

  /// How long the engine has been silent.
  ///
  /// An engine that has never said anything counts as silent for a long time,
  /// not as having just spoken: the caller reads this as evidence of life, and
  /// "no evidence" must not read as "alive".
  static const neverSpoke = Duration(days: 1);

  Duration quietFor(DateTime now) {
    final last = lastEventAt;
    return last == null ? neverSpoke : now.difference(last);
  }

  /// Folds one engine event and says what the caller must do about it.
  RecoveryStep observe(SyncEngineEvent event, DateTime now) {
    lastEventAt = now;

    if (event is SyncStorageRefused) storageRefused = true;
    if (event is SyncFilePushed) storageRefused = false;
    if (event is SyncBusy) engineBusy = event.busy;

    if (event is SyncConnected) {
      online = true;
      selfHealAttempt = 0;
      // Authenticated traffic is flowing again — arm the rebind budget for the
      // next auth incident.
      authRebindAttempts = 0;
      return RecoveryStep.connected;
    }
    if (event is SyncDisconnected) {
      online = false;
      return RecoveryStep.disconnected;
    }
    if (event is SyncStartupBlobUploadProgress && event.completed > 0) {
      // An attempt that MOVED is not a wasted attempt.
      //
      // The cap was written when a startup that failed banked nothing, so every
      // attempt really was worth the same as the last. Now each pass persists
      // the groups it uploads, so a large first sync can legitimately need more
      // than ten passes and each leaves the next with less to do. Only the
      // counter is reset, never a pending timer: this pass may still fail, and
      // if it does the ladder should carry on — with a budget that reflects
      // progress rather than punishing it. "Ten attempts" now means ten in a
      // row that achieved nothing.
      selfHealAttempt = 0;
    }
    return RecoveryStep.none;
  }

  /// Whether the ladder has spent its budget without getting anywhere.
  bool get selfHealExhausted => selfHealAttempt >= maxSelfHealAttempts;

  /// How long to wait before the next attempt.
  Duration get selfHealDelay => Duration(
    seconds:
        backoffSeconds[selfHealAttempt.clamp(0, backoffSeconds.length - 1)],
  );

  /// Records an attempt starting. Returns its number, for the log.
  int beginSelfHealAttempt() => ++selfHealAttempt;

  /// Clears the backoff. The timer it drives belongs to the session.
  void resetSelfHeal() => selfHealAttempt = 0;

  /// True when a token refresh may start now: none in flight, and the cooldown
  /// has passed. Records the attempt.
  bool claimAuthRefresh(DateTime now) {
    final last = lastAuthRefreshAt;
    if (authRefreshInFlight ||
        (last != null && now.difference(last) < authRefreshCooldown)) {
      return false;
    }
    lastAuthRefreshAt = now;
    return true;
  }

  /// True while the rebind budget is not spent. Records the attempt.
  bool claimRebind() {
    if (authRebindAttempts >= maxAuthRebinds) return false;
    authRebindAttempts++;
    return true;
  }

  /// Whether a rebind would be allowed, without spending the budget. The
  /// recovery plan is decided before it is acted on.
  bool get rebindBudgetLeft => authRebindAttempts < maxAuthRebinds;
}
