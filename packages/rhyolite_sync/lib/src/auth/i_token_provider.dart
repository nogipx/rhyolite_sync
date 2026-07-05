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
