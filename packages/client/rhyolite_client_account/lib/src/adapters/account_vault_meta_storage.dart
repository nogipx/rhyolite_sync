import 'package:rhyolite_sync/rhyolite_sync.dart';

import '../client/rpc_account_client.dart';

/// Backs [IVaultMetaStorage] with the Rhyolite account server.
///
/// The encrypted meta blob is stored opaque on the server side via the
/// account vault contract — the server never decrypts it.
class AccountVaultMetaStorage implements IVaultMetaStorage {
  AccountVaultMetaStorage(this._client);

  final RpcAccountClient _client;

  @override
  Future<String?> getEncryptedMeta(String vaultId) =>
      _client.getVaultMeta(vaultId: vaultId);

  @override
  Future<void> setEncryptedMeta(String vaultId, String encryptedMeta) =>
      _client.updateVaultMeta(
        vaultId: vaultId,
        encryptedMeta: encryptedMeta,
      );
}
