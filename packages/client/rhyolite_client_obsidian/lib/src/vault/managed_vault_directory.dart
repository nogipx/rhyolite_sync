import 'package:rhyolite_client_account/rhyolite_client_account.dart'
    hide VaultInfo;
import 'package:rhyolite_sync/rhyolite_sync.dart' show IVaultMetaStorage;

import 'vault_directory.dart';

/// Managed [IVaultDirectory]: the user's vaults come from the account service.
/// Kept in its own file so the interface + self-host impl stay free of the
/// (closed) account dependency.
class ManagedVaultDirectory implements IVaultDirectory {
  ManagedVaultDirectory(this._client);

  final RpcAccountClient _client;

  @override
  Future<List<VaultInfo>> listVaults() async {
    final vaults = await _client.listVaults();
    return vaults
        .map(
          (v) => VaultInfo(
            vaultId: v.vaultId,
            vaultName: v.vaultName,
            verificationToken: v.verificationToken,
          ),
        )
        .toList();
  }

  @override
  Future<void> createVault({
    required String vaultId,
    required String vaultName,
  }) =>
      _client.createVault(vaultId: vaultId, vaultName: vaultName);

  @override
  Future<void> updateVerificationToken({
    required String vaultId,
    required String verificationToken,
  }) =>
      _client.updateVerificationToken(
        vaultId: vaultId,
        verificationToken: verificationToken,
      );

  @override
  Future<void> deleteVault({required String vaultId}) =>
      _client.deleteVault(vaultId: vaultId);

  @override
  IVaultMetaStorage get metaStorage => AccountVaultMetaStorage(_client);
}
