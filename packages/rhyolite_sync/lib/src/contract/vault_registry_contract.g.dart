// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'vault_registry_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class VaultRegistryContractNames {
  const VaultRegistryContractNames._();
  static const service = 'RhyoliteVaultRegistry';
  static String instance(String suffix) => '$service\_$suffix';
  static const listVaults = 'listVaults';
  static const createVault = 'createVault';
  static const updateVerificationToken = 'updateVerificationToken';
  static const getVaultMeta = 'getVaultMeta';
  static const setVaultMeta = 'setVaultMeta';
  static const deleteVault = 'deleteVault';
}

class VaultRegistryContractCodecs {
  const VaultRegistryContractCodecs._();
  static const codecCreateVaultRequest =
      RpcCodec<CreateVaultRequest>.withDecoder(CreateVaultRequest.fromJson);
  static const codecDeleteVaultRequest =
      RpcCodec<DeleteVaultRequest>.withDecoder(DeleteVaultRequest.fromJson);
  static const codecListVaultsRequest = RpcCodec<ListVaultsRequest>.withDecoder(
    ListVaultsRequest.fromJson,
  );
  static const codecListVaultsResponse =
      RpcCodec<ListVaultsResponse>.withDecoder(ListVaultsResponse.fromJson);
  static const codecSetVaultMetaRequest =
      RpcCodec<SetVaultMetaRequest>.withDecoder(SetVaultMetaRequest.fromJson);
  static const codecUpdateVaultTokenRequest =
      RpcCodec<UpdateVaultTokenRequest>.withDecoder(
        UpdateVaultTokenRequest.fromJson,
      );
  static const codecVaultAck = RpcCodec<VaultAck>.withDecoder(
    VaultAck.fromJson,
  );
  static const codecVaultMetaRequest = RpcCodec<VaultMetaRequest>.withDecoder(
    VaultMetaRequest.fromJson,
  );
  static const codecVaultMetaResponse = RpcCodec<VaultMetaResponse>.withDecoder(
    VaultMetaResponse.fromJson,
  );
  static const codecVaultRegistryEntry =
      RpcCodec<VaultRegistryEntry>.withDecoder(VaultRegistryEntry.fromJson);
}

class VaultRegistryContractCaller extends RpcCallerContract
    implements IVaultRegistryContract {
  VaultRegistryContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? VaultRegistryContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<ListVaultsResponse> listVaults(
    ListVaultsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ListVaultsRequest, ListVaultsResponse>(
      methodName: VaultRegistryContractNames.listVaults,
      requestCodec: VaultRegistryContractCodecs.codecListVaultsRequest,
      responseCodec: VaultRegistryContractCodecs.codecListVaultsResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<VaultRegistryEntry> createVault(
    CreateVaultRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CreateVaultRequest, VaultRegistryEntry>(
      methodName: VaultRegistryContractNames.createVault,
      requestCodec: VaultRegistryContractCodecs.codecCreateVaultRequest,
      responseCodec: VaultRegistryContractCodecs.codecVaultRegistryEntry,
      request: request,
      context: context,
    );
  }

  @override
  Future<VaultAck> updateVerificationToken(
    UpdateVaultTokenRequest request, {
    RpcContext? context,
  }) {
    return callUnary<UpdateVaultTokenRequest, VaultAck>(
      methodName: VaultRegistryContractNames.updateVerificationToken,
      requestCodec: VaultRegistryContractCodecs.codecUpdateVaultTokenRequest,
      responseCodec: VaultRegistryContractCodecs.codecVaultAck,
      request: request,
      context: context,
    );
  }

  @override
  Future<VaultMetaResponse> getVaultMeta(
    VaultMetaRequest request, {
    RpcContext? context,
  }) {
    return callUnary<VaultMetaRequest, VaultMetaResponse>(
      methodName: VaultRegistryContractNames.getVaultMeta,
      requestCodec: VaultRegistryContractCodecs.codecVaultMetaRequest,
      responseCodec: VaultRegistryContractCodecs.codecVaultMetaResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<VaultAck> setVaultMeta(
    SetVaultMetaRequest request, {
    RpcContext? context,
  }) {
    return callUnary<SetVaultMetaRequest, VaultAck>(
      methodName: VaultRegistryContractNames.setVaultMeta,
      requestCodec: VaultRegistryContractCodecs.codecSetVaultMetaRequest,
      responseCodec: VaultRegistryContractCodecs.codecVaultAck,
      request: request,
      context: context,
    );
  }

  @override
  Future<VaultAck> deleteVault(
    DeleteVaultRequest request, {
    RpcContext? context,
  }) {
    return callUnary<DeleteVaultRequest, VaultAck>(
      methodName: VaultRegistryContractNames.deleteVault,
      requestCodec: VaultRegistryContractCodecs.codecDeleteVaultRequest,
      responseCodec: VaultRegistryContractCodecs.codecVaultAck,
      request: request,
      context: context,
    );
  }
}

abstract class VaultRegistryContractResponder extends RpcResponderContract
    implements IVaultRegistryContract {
  VaultRegistryContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? VaultRegistryContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<ListVaultsRequest, ListVaultsResponse>(
      methodName: VaultRegistryContractNames.listVaults,
      handler: listVaults,
      requestCodec: VaultRegistryContractCodecs.codecListVaultsRequest,
      responseCodec: VaultRegistryContractCodecs.codecListVaultsResponse,
    );
    addUnaryMethod<CreateVaultRequest, VaultRegistryEntry>(
      methodName: VaultRegistryContractNames.createVault,
      handler: createVault,
      requestCodec: VaultRegistryContractCodecs.codecCreateVaultRequest,
      responseCodec: VaultRegistryContractCodecs.codecVaultRegistryEntry,
    );
    addUnaryMethod<UpdateVaultTokenRequest, VaultAck>(
      methodName: VaultRegistryContractNames.updateVerificationToken,
      handler: updateVerificationToken,
      requestCodec: VaultRegistryContractCodecs.codecUpdateVaultTokenRequest,
      responseCodec: VaultRegistryContractCodecs.codecVaultAck,
    );
    addUnaryMethod<VaultMetaRequest, VaultMetaResponse>(
      methodName: VaultRegistryContractNames.getVaultMeta,
      handler: getVaultMeta,
      requestCodec: VaultRegistryContractCodecs.codecVaultMetaRequest,
      responseCodec: VaultRegistryContractCodecs.codecVaultMetaResponse,
    );
    addUnaryMethod<SetVaultMetaRequest, VaultAck>(
      methodName: VaultRegistryContractNames.setVaultMeta,
      handler: setVaultMeta,
      requestCodec: VaultRegistryContractCodecs.codecSetVaultMetaRequest,
      responseCodec: VaultRegistryContractCodecs.codecVaultAck,
    );
    addUnaryMethod<DeleteVaultRequest, VaultAck>(
      methodName: VaultRegistryContractNames.deleteVault,
      handler: deleteVault,
      requestCodec: VaultRegistryContractCodecs.codecDeleteVaultRequest,
      responseCodec: VaultRegistryContractCodecs.codecVaultAck,
    );
  }
}
