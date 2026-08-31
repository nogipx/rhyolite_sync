import 'package:rhyolite_client_account/rhyolite_client_account.dart';

/// How the plugin should answer an `auth.*` rejection from the engine.
///
/// Pure decision logic, kept out of the event handler so the table can be
/// tested. It encodes one hard-won distinction: an auth rejection does NOT
/// imply the session is dead. The server answers both "your token is dead"
/// and "you sent no token" with `unauthenticated`, and treating the second
/// as the first is what produced a loop where re-authenticating was
/// immediately followed by another "session expired" — the handler kept
/// deleting the session the user had just obtained.
enum AuthRecovery {
  /// The session we hold is good; nothing was attached to the connection.
  /// Rebind the shared token provider and restart so the socket carries it.
  rebind,

  /// We hold a session the server refused. Try to refresh it.
  refresh,

  /// Nothing left to try without the user: prompt for sign-in.
  prompt,
}

/// Chooses the recovery step.
///
/// - [tokenMissing]: the rejection was `auth.token_missing` (no token
///   reached the server) rather than a refused token.
/// - [sessionLive]: a non-expired session exists in memory.
/// - [sessionPresent]: some session exists to attempt a refresh with.
/// - [providerBound]: the engine's token provider currently has a session
///   bound. False means the failure is explained by our own state.
/// - [rebindBudgetLeft]: bounded so a rebind that doesn't help can't restart
///   the engine on every cooldown.
AuthRecovery planAuthRecovery({
  required bool tokenMissing,
  required bool sessionLive,
  required bool sessionPresent,
  required bool providerBound,
  required bool rebindBudgetLeft,
}) {
  if (sessionLive && (tokenMissing || !providerBound) && rebindBudgetLeft) {
    return AuthRecovery.rebind;
  }
  if (sessionPresent) return AuthRecovery.refresh;
  return AuthRecovery.prompt;
}

/// What the recovery handler's refresh attempt (if any) established.
enum RefreshOutcome {
  /// No refresh was attempted — there was nothing to refresh with.
  notAttempted,

  /// The server refused the refresh token itself. Evidence the session is
  /// dead.
  refused,

  /// The attempt failed without a verdict: a network error, a timeout, or a
  /// refusal explained by our own retry having already spent the single-use
  /// token. NOT evidence.
  inconclusive,
}

/// Classifies what a failed refresh proved. Anything we cannot read as a
/// clean server refusal is [RefreshOutcome.inconclusive] — the conservative
/// side, because the only action gated on this is destructive.
RefreshOutcome classifyRefreshFailure(Object error) =>
    error is RefreshFailedException && error.sessionIsDead
    ? RefreshOutcome.refused
    : RefreshOutcome.inconclusive;

/// Whether the persisted session should be discarded once recovery has
/// failed.
///
/// Only evidence that the session is dead counts: a refresh the server
/// actually refused, or a token the server actually refused.
/// `auth.token_missing` on its own is not evidence — it says we never
/// attached a token, which tells us nothing about the stored session, and may
/// well be racing a sign-in that just stored a good one. Neither is a refresh
/// that failed without an answer: refresh tokens are single-use, so a lost
/// response burns the token and the *next* attempt reports `unauthenticated`
/// for a session that was never dead. Deleting on that turned one dropped
/// connection into a forced re-login.
bool shouldClearStoredSession({
  required bool tokenMissing,
  required RefreshOutcome refresh,
}) {
  if (refresh == RefreshOutcome.inconclusive) return false;
  return refresh == RefreshOutcome.refused || !tokenMissing;
}

/// Whether a server rejection code is one a token refresh could fix.
///
/// The `auth.` prefix covers two unrelated conditions. Authentication — an
/// expired or missing token — is exactly what a refresh repairs.
/// Authorization is not: `auth.permission_denied` means this account does not
/// own the vault, and a freshly minted token carries precisely the same
/// permissions as the one that was refused.
///
/// Refreshing anyway restarts the engine, fails identically, and restarts
/// again. A user's first sync spent minutes in that loop before this
/// distinction existed, alternating a refresh with the same refusal.
bool rejectionWarrantsRefresh(String code) =>
    code.startsWith('auth.') && code != 'auth.permission_denied';
