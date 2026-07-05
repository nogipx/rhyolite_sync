import 'package:rhyolite_sync/rhyolite_sync.dart';

/// A vault as shown to the user in the picker.
class VaultInfo {
  const VaultInfo({
    required this.vaultId,
    required this.vaultName,
    this.verificationToken,
  });

  final String vaultId;
  final String vaultName;

  /// Opaque E2EE verification token, or null if a passphrase hasn't been set.
  final String? verificationToken;
}

/// Source of the user's vaults + their encrypted meta.
///
/// This is the seam between editions: the managed plugin binds it to the
/// account service, the self-host plugin binds it to the sync server's own
/// vault registry (see [SelfHostVaultDirectory]). The plugin UI (picker,
/// E2EE setup) talks only to this interface.
abstract interface class IVaultDirectory {
  Future<List<VaultInfo>> listVaults();

  Future<void> createVault({
    required String vaultId,
    required String vaultName,
  });

  Future<void> updateVerificationToken({
    required String vaultId,
    required String verificationToken,
  });

  /// Backing store for the engine's external-blob config.
  IVaultMetaStorage get metaStorage;
}

/// Self-host [IVaultDirectory]: talks to the sync server's `RhyoliteVaultRegistry`
/// service. No account service involved.
class SelfHostVaultDirectory implements IVaultDirectory {
  SelfHostVaultDirectory(this._caller);

  final VaultRegistryContractCaller _caller;

  @override
  Future<List<VaultInfo>> listVaults() async {
    final resp = await _caller.listVaults(const ListVaultsRequest());
    return resp.vaults
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
  }) async {
    await _caller.createVault(
      CreateVaultRequest(vaultId: vaultId, vaultName: vaultName),
    );
  }

  @override
  Future<void> updateVerificationToken({
    required String vaultId,
    required String verificationToken,
  }) async {
    await _caller.updateVerificationToken(
      UpdateVaultTokenRequest(
        vaultId: vaultId,
        verificationToken: verificationToken,
      ),
    );
  }

  @override
  IVaultMetaStorage get metaStorage => SelfHostVaultMetaStorage(_caller);
}

/// [IVaultMetaStorage] backed by the sync server's vault registry
/// (`get/setVaultMeta`). The stored blob is opaque ciphertext — the server
/// never reads it.
class SelfHostVaultMetaStorage implements IVaultMetaStorage {
  SelfHostVaultMetaStorage(this._caller);

  final VaultRegistryContractCaller _caller;

  @override
  Future<String?> getEncryptedMeta(String vaultId) async {
    final resp = await _caller.getVaultMeta(VaultMetaRequest(vaultId: vaultId));
    return resp.encryptedMeta;
  }

  @override
  Future<void> setEncryptedMeta(String vaultId, String encryptedMeta) async {
    await _caller.setVaultMeta(
      SetVaultMetaRequest(vaultId: vaultId, encryptedMeta: encryptedMeta),
    );
  }
}
