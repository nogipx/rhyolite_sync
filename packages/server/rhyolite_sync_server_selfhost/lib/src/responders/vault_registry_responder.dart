import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Self-host vault registry + encrypted meta, backed by the sync database.
///
/// Two collections (auto-created on first write, like every other collection):
/// - `_vaults`      — one record per vault: {vaultId, vaultName, verificationToken?}
/// - `_vault_meta`  — one record per vault: {encryptedMeta} (external-blob config)
///
/// Single-tenant: there is one principal, so vaults are not scoped by user.
/// This is the local replacement for what the account service provides in the
/// managed edition.
class LocalVaultRegistryResponder extends VaultRegistryContractResponder {
  LocalVaultRegistryResponder({required IDataClient client}) : _client = client;

  final IDataClient _client;

  static const _vaultsCollection = '_vaults';
  static const _metaCollection = '_vault_meta';

  @override
  Future<ListVaultsResponse> listVaults(
    ListVaultsRequest request, {
    RpcContext? context,
  }) async {
    final resp = await _client.list(collection: _vaultsCollection);
    final vaults = resp.records
        .map(
          (r) => VaultRegistryEntry(
            vaultId: r.payload['vaultId'] as String? ?? r.id,
            vaultName: r.payload['vaultName'] as String? ?? '',
            verificationToken: r.payload['verificationToken'] as String?,
          ),
        )
        .toList();
    return ListVaultsResponse(vaults: vaults);
  }

  @override
  Future<VaultRegistryEntry> createVault(
    CreateVaultRequest request, {
    RpcContext? context,
  }) async {
    final existing =
        await _client.get(collection: _vaultsCollection, id: request.vaultId);
    // Idempotent: registering an existing vault returns the stored entry.
    if (existing != null) {
      return VaultRegistryEntry(
        vaultId: request.vaultId,
        vaultName: existing.payload['vaultName'] as String? ?? request.vaultName,
        verificationToken: existing.payload['verificationToken'] as String?,
      );
    }
    await _client.create(
      collection: _vaultsCollection,
      id: request.vaultId,
      payload: {
        'vaultId': request.vaultId,
        'vaultName': request.vaultName,
        if (request.verificationToken != null)
          'verificationToken': request.verificationToken,
      },
    );
    return VaultRegistryEntry(
      vaultId: request.vaultId,
      vaultName: request.vaultName,
      verificationToken: request.verificationToken,
    );
  }

  @override
  Future<VaultAck> updateVerificationToken(
    UpdateVaultTokenRequest request, {
    RpcContext? context,
  }) async {
    final existing =
        await _client.get(collection: _vaultsCollection, id: request.vaultId);
    if (existing == null) {
      await _client.create(
        collection: _vaultsCollection,
        id: request.vaultId,
        payload: {
          'vaultId': request.vaultId,
          'vaultName': '',
          'verificationToken': request.verificationToken,
        },
      );
    } else {
      final payload = Map<String, dynamic>.from(existing.payload)
        ..['verificationToken'] = request.verificationToken;
      await _client.update(
        collection: _vaultsCollection,
        id: request.vaultId,
        expectedVersion: existing.version,
        payload: payload,
      );
    }
    return const VaultAck();
  }

  @override
  Future<VaultMetaResponse> getVaultMeta(
    VaultMetaRequest request, {
    RpcContext? context,
  }) async {
    final rec =
        await _client.get(collection: _metaCollection, id: request.vaultId);
    return VaultMetaResponse(
      encryptedMeta: rec?.payload['encryptedMeta'] as String?,
    );
  }

  @override
  Future<VaultAck> setVaultMeta(
    SetVaultMetaRequest request, {
    RpcContext? context,
  }) async {
    final existing =
        await _client.get(collection: _metaCollection, id: request.vaultId);
    final payload = {'encryptedMeta': request.encryptedMeta};
    if (existing == null) {
      await _client.create(
        collection: _metaCollection,
        id: request.vaultId,
        payload: payload,
      );
    } else {
      await _client.update(
        collection: _metaCollection,
        id: request.vaultId,
        expectedVersion: existing.version,
        payload: payload,
      );
    }
    return const VaultAck();
  }

  @override
  Future<VaultAck> deleteVault(
    DeleteVaultRequest request, {
    RpcContext? context,
  }) async {
    // Idempotent — a missing entry is treated as already-deleted. The vault's
    // sync data (states, blobs, history) is wiped separately via wipeVault.
    await _client.delete(collection: _vaultsCollection, id: request.vaultId);
    await _client.delete(collection: _metaCollection, id: request.vaultId);
    return const VaultAck();
  }
}
