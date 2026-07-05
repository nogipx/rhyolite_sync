// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'vault_registry_contract.g.dart';

// --- DTOs ---

/// A vault as known to the sync server's own registry. In the self-host
/// edition this replaces the account service's vault list: the vault<->owner
/// mapping and E2EE verification token live in the sync database itself.
class VaultRegistryEntry implements IRpcSerializable {
  const VaultRegistryEntry({
    required this.vaultId,
    required this.vaultName,
    this.verificationToken,
  });

  final String vaultId;
  final String vaultName;

  /// Opaque E2EE verification token (set once a passphrase is established).
  final String? verificationToken;

  factory VaultRegistryEntry.fromJson(Map<String, dynamic> json) =>
      VaultRegistryEntry(
        vaultId: json['vaultId'] as String,
        vaultName: json['vaultName'] as String? ?? '',
        verificationToken: json['verificationToken'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'vaultId': vaultId,
        'vaultName': vaultName,
        if (verificationToken != null) 'verificationToken': verificationToken,
      };
}

class ListVaultsRequest implements IRpcSerializable {
  const ListVaultsRequest();

  factory ListVaultsRequest.fromJson(Map<String, dynamic> json) =>
      const ListVaultsRequest();

  @override
  Map<String, dynamic> toJson() => const {};
}

class ListVaultsResponse implements IRpcSerializable {
  const ListVaultsResponse({required this.vaults});

  final List<VaultRegistryEntry> vaults;

  factory ListVaultsResponse.fromJson(Map<String, dynamic> json) =>
      ListVaultsResponse(
        vaults: ((json['vaults'] as List?) ?? const [])
            .map((e) => VaultRegistryEntry.fromJson(
                  Map<String, dynamic>.from(e as Map),
                ))
            .toList(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'vaults': vaults.map((v) => v.toJson()).toList(),
      };
}

class CreateVaultRequest implements IRpcSerializable {
  const CreateVaultRequest({
    required this.vaultId,
    required this.vaultName,
    this.verificationToken,
  });

  final String vaultId;
  final String vaultName;
  final String? verificationToken;

  factory CreateVaultRequest.fromJson(Map<String, dynamic> json) =>
      CreateVaultRequest(
        vaultId: json['vaultId'] as String,
        vaultName: json['vaultName'] as String? ?? '',
        verificationToken: json['verificationToken'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'vaultId': vaultId,
        'vaultName': vaultName,
        if (verificationToken != null) 'verificationToken': verificationToken,
      };
}

class UpdateVaultTokenRequest implements IRpcSerializable {
  const UpdateVaultTokenRequest({
    required this.vaultId,
    required this.verificationToken,
  });

  final String vaultId;
  final String verificationToken;

  factory UpdateVaultTokenRequest.fromJson(Map<String, dynamic> json) =>
      UpdateVaultTokenRequest(
        vaultId: json['vaultId'] as String,
        verificationToken: json['verificationToken'] as String,
      );

  @override
  Map<String, dynamic> toJson() => {
        'vaultId': vaultId,
        'verificationToken': verificationToken,
      };
}

class VaultMetaRequest implements IRpcSerializable {
  const VaultMetaRequest({required this.vaultId});

  final String vaultId;

  factory VaultMetaRequest.fromJson(Map<String, dynamic> json) =>
      VaultMetaRequest(vaultId: json['vaultId'] as String);

  @override
  Map<String, dynamic> toJson() => {'vaultId': vaultId};
}

class VaultMetaResponse implements IRpcSerializable {
  const VaultMetaResponse({this.encryptedMeta});

  /// Base64 opaque ciphertext of the external-blob config, or null if unset.
  final String? encryptedMeta;

  factory VaultMetaResponse.fromJson(Map<String, dynamic> json) =>
      VaultMetaResponse(encryptedMeta: json['encryptedMeta'] as String?);

  @override
  Map<String, dynamic> toJson() => {
        if (encryptedMeta != null) 'encryptedMeta': encryptedMeta,
      };
}

class SetVaultMetaRequest implements IRpcSerializable {
  const SetVaultMetaRequest({
    required this.vaultId,
    required this.encryptedMeta,
  });

  final String vaultId;
  final String encryptedMeta;

  factory SetVaultMetaRequest.fromJson(Map<String, dynamic> json) =>
      SetVaultMetaRequest(
        vaultId: json['vaultId'] as String,
        encryptedMeta: json['encryptedMeta'] as String,
      );

  @override
  Map<String, dynamic> toJson() => {
        'vaultId': vaultId,
        'encryptedMeta': encryptedMeta,
      };
}

class VaultAck implements IRpcSerializable {
  const VaultAck({this.ok = true});

  final bool ok;

  factory VaultAck.fromJson(Map<String, dynamic> json) =>
      VaultAck(ok: json['ok'] as bool? ?? true);

  @override
  Map<String, dynamic> toJson() => {'ok': ok};
}

// --- Contract ---

/// Self-host vault registry + encrypted meta storage, served by the sync
/// server directly (no account service). Managed deployments don't register a
/// responder for this — their vault list comes from the account service.
@RpcService(name: 'RhyoliteVaultRegistry', transferMode: RpcDataTransferMode.codec)
abstract class IVaultRegistryContract {
  @RpcMethod.unary(name: 'listVaults')
  Future<ListVaultsResponse> listVaults(
    ListVaultsRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'createVault')
  Future<VaultRegistryEntry> createVault(
    CreateVaultRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'updateVerificationToken')
  Future<VaultAck> updateVerificationToken(
    UpdateVaultTokenRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'getVaultMeta')
  Future<VaultMetaResponse> getVaultMeta(
    VaultMetaRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'setVaultMeta')
  Future<VaultAck> setVaultMeta(
    SetVaultMetaRequest request, {
    RpcContext? context,
  });
}
