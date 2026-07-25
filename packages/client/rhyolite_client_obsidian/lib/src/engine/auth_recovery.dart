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

/// Whether the persisted session should be discarded once recovery has
/// failed.
///
/// Only evidence that the session is dead counts: a refresh we attempted and
/// lost, or a token the server actually refused. `auth.token_missing` on its
/// own is not evidence — it says we never attached a token, which tells us
/// nothing about the stored session, and may well be racing a sign-in that
/// just stored a good one.
bool shouldClearStoredSession({
  required bool tokenMissing,
  required bool refreshRefused,
}) => refreshRefused || !tokenMissing;
