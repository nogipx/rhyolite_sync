// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'vault_contract.g.dart';

// --- DTOs ---

class VaultDto implements IRpcSerializable {
  const VaultDto({
    required this.vaultId,
    required this.vaultName,
    this.verificationToken,
    this.encryptedMeta,
  });

  final String vaultId;
  final String vaultName;

  /// Null if E2EE has not been set up for this vault yet.
  final String? verificationToken;

  /// Opaque E2E-encrypted blob for client-side metadata
  /// (e.g. external blob storage config). Server stores but never reads it.
  final String? encryptedMeta;

  factory VaultDto.fromJson(Map<String, dynamic> json) => VaultDto(
    vaultId: json['vault_id'] as String,
    vaultName: json['vault_name'] as String,
    verificationToken: json['verification_token'] as String?,
    encryptedMeta: json['encrypted_meta'] as String?,
  );

  @override
  Map<String, dynamic> toJson() => {
    'vault_id': vaultId,
    'vault_name': vaultName,
    if (verificationToken != null) 'verification_token': verificationToken,
    if (encryptedMeta != null) 'encrypted_meta': encryptedMeta,
  };
}

class ListVaultsRequest implements IRpcSerializable {
  const ListVaultsRequest();

  factory ListVaultsRequest.fromJson(Map<String, dynamic> _) =>
      const ListVaultsRequest();

  @override
  Map<String, dynamic> toJson() => const {};
}

class ListVaultsResponse implements IRpcSerializable {
  const ListVaultsResponse({required this.vaults});

  final List<VaultDto> vaults;

  factory ListVaultsResponse.fromJson(Map<String, dynamic> json) =>
      ListVaultsResponse(
        vaults: (json['vaults'] as List)
            .cast<Map<String, dynamic>>()
            .map(VaultDto.fromJson)
            .toList(),
      );

  @override
  Map<String, dynamic> toJson() => {
    'vaults': vaults.map((v) => v.toJson()).toList(),
  };
}

class CreateVaultRequest implements IRpcSerializable {
  const CreateVaultRequest({required this.vaultId, required this.vaultName});

  final String vaultId;
  final String vaultName;

  factory CreateVaultRequest.fromJson(Map<String, dynamic> json) =>
      CreateVaultRequest(
        vaultId: json['vault_id'] as String,
        vaultName: json['vault_name'] as String,
      );

  @override
  Map<String, dynamic> toJson() => {
    'vault_id': vaultId,
    'vault_name': vaultName,
  };
}

class CreateVaultResponse implements IRpcSerializable {
  const CreateVaultResponse();

  factory CreateVaultResponse.fromJson(Map<String, dynamic> _) =>
      const CreateVaultResponse();

  @override
  Map<String, dynamic> toJson() => const {};
}

class UpdateVerificationTokenRequest implements IRpcSerializable {
  const UpdateVerificationTokenRequest({
    required this.vaultId,
    required this.verificationToken,
  });

  final String vaultId;
  final String verificationToken;

  factory UpdateVerificationTokenRequest.fromJson(Map<String, dynamic> json) =>
      UpdateVerificationTokenRequest(
        vaultId: json['vault_id'] as String,
        verificationToken: json['verification_token'] as String,
      );

  @override
  Map<String, dynamic> toJson() => {
    'vault_id': vaultId,
    'verification_token': verificationToken,
  };
}

class UpdateVerificationTokenResponse implements IRpcSerializable {
  const UpdateVerificationTokenResponse();

  factory UpdateVerificationTokenResponse.fromJson(Map<String, dynamic> _) =>
      const UpdateVerificationTokenResponse();

  @override
  Map<String, dynamic> toJson() => const {};
}

class UpdateVaultMetaRequest implements IRpcSerializable {
  const UpdateVaultMetaRequest({
    required this.vaultId,
    required this.encryptedMeta,
  });

  final String vaultId;

  /// Base64-encoded E2E-encrypted payload. Empty string clears the field.
  final String encryptedMeta;

  factory UpdateVaultMetaRequest.fromJson(Map<String, dynamic> json) =>
      UpdateVaultMetaRequest(
        vaultId: json['vault_id'] as String,
        encryptedMeta: json['encrypted_meta'] as String,
      );

  @override
  Map<String, dynamic> toJson() => {
        'vault_id': vaultId,
        'encrypted_meta': encryptedMeta,
      };
}

class UpdateVaultMetaResponse implements IRpcSerializable {
  const UpdateVaultMetaResponse();

  factory UpdateVaultMetaResponse.fromJson(Map<String, dynamic> _) =>
      const UpdateVaultMetaResponse();

  @override
  Map<String, dynamic> toJson() => const {};
}

class DeleteVaultRequest implements IRpcSerializable {
  const DeleteVaultRequest({required this.vaultId});

  final String vaultId;

  factory DeleteVaultRequest.fromJson(Map<String, dynamic> json) =>
      DeleteVaultRequest(vaultId: json['vault_id'] as String);

  @override
  Map<String, dynamic> toJson() => {'vault_id': vaultId};
}

class DeleteVaultResponse implements IRpcSerializable {
  const DeleteVaultResponse();

  factory DeleteVaultResponse.fromJson(Map<String, dynamic> _) =>
      const DeleteVaultResponse();

  @override
  Map<String, dynamic> toJson() => const {};
}

// --- Contract ---

/// Vault management contract — JWT required.
@RpcService(name: 'RhyoliteVault', transferMode: RpcDataTransferMode.codec)
abstract class IVaultContract {
  @RpcMethod.unary(name: 'listVaults')
  Future<ListVaultsResponse> listVaults(
    ListVaultsRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'createVault')
  Future<CreateVaultResponse> createVault(
    CreateVaultRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'updateVerificationToken')
  Future<UpdateVerificationTokenResponse> updateVerificationToken(
    UpdateVerificationTokenRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'updateVaultMeta')
  Future<UpdateVaultMetaResponse> updateVaultMeta(
    UpdateVaultMetaRequest request, {
    RpcContext? context,
  });

  /// Removes the vault registration from the account. Called last in the
  /// delete flow, after the vault's data (states, blobs, history) has been
  /// wiped from the sync server and any external blob storage — while the
  /// registration exists the vault is still considered live.
  @RpcMethod.unary(name: 'deleteVault')
  Future<DeleteVaultResponse> deleteVault(
    DeleteVaultRequest request, {
    RpcContext? context,
  });
}
