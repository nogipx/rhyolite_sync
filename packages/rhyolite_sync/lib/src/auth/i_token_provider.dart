/// Source of a Bearer token for outgoing RPC requests.
///
/// The sync engine asks for a fresh token before every authenticated
/// call (via [BearerTokenInterceptor]). Implementations are free to
/// cache, refresh, or rotate as they see fit.
abstract interface class ITokenProvider {
  Future<String> getToken();
}

/// Returns a fixed token. Useful for tests or server-to-server calls
/// where the token is managed externally.
class StaticTokenProvider implements ITokenProvider {
  StaticTokenProvider(this._token);

  final String _token;

  @override
  Future<String> getToken() async => _token;
}

/// Raised by [MutableTokenProvider] when there is no session to take a
/// token from.
///
/// Failing here — locally, before the call leaves — is deliberate. A
/// request sent with no `Authorization` header comes back from the server
/// as a plain `unauthenticated`, which is indistinguishable from a
/// genuinely dead session: the host then "recovers" by discarding the
/// stored session, including one the user obtained seconds ago. This
/// exception keeps *we have no token* separate from *the server rejected
/// our token*; `ServerRejectionMapper` maps it to `auth.token_missing`.
class MissingAuthTokenException implements Exception {
  const MissingAuthTokenException([this.reason = 'provider is unbound']);

  final String reason;

  @override
  String toString() => 'unauthenticated: missing auth token ($reason)';
}

/// An [ITokenProvider] whose backing source can be swapped at runtime.
///
/// A connection captures its provider **once**, when the bearer
/// interceptor is installed at connect time. So a design that builds a
/// fresh provider per sign-in and writes it into the engine's config
/// cannot re-authenticate a live connection — the socket keeps whatever
/// provider (or none) it was opened with, and every later call goes out
/// unauthenticated until something happens to restart the engine.
///
/// Create one of these per host session, hand it to the config once, and
/// mutate [delegate] on sign-in / sign-out. Connections opened before the
/// sign-in then pick up the new session on their next call.
class MutableTokenProvider implements ITokenProvider {
  MutableTokenProvider([this.delegate]);

  /// Current source of tokens, or null when signed out.
  ITokenProvider? delegate;

  /// Whether a session is currently bound. A false here means every call
  /// on this provider fails locally with [MissingAuthTokenException].
  bool get isBound => delegate != null;

  // `async` so an unbound provider yields a FAILED FUTURE rather than
  // throwing synchronously out of a Future-returning call — callers that
  // only guard the future (`.catchError`) must not be bypassed.
  @override
  Future<String> getToken() async {
    final d = delegate;
    if (d == null) throw const MissingAuthTokenException();
    return d.getToken();
  }
}
