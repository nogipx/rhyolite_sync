import 'package:rhyolite_sync/rhyolite_sync.dart';

import '../client/rpc_account_client.dart';

/// Backward-compatible alias: the canonical interface now lives in
/// `package:rhyolite_sync` as [ITokenProvider]. Existing callers keep
/// working because `IBearerTokenProvider` IS-A [ITokenProvider].
abstract interface class IBearerTokenProvider implements ITokenProvider {}

/// Delegates to [RpcAccountClient.ensureValidToken], which refreshes
/// the access token automatically when it is expired.
class RpcAccountClientTokenProvider implements IBearerTokenProvider {
  RpcAccountClientTokenProvider(this._client);

  final RpcAccountClient _client;

  @override
  Future<String> getToken() => _client.ensureValidToken();
}
