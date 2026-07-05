// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'vault_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class VaultContractNames {
  const VaultContractNames._();
  static const service = 'RhyoliteVault';
  static String instance(String suffix) => '$service\_$suffix';
  static const listVaults = 'listVaults';
  static const createVault = 'createVault';
  static const updateVerificationToken = 'updateVerificationToken';
  static const updateVaultMeta = 'updateVaultMeta';
}

class VaultContractCodecs {
  const VaultContractCodecs._();
  static const codecCreateVaultRequest =
      RpcCodec<CreateVaultRequest>.withDecoder(CreateVaultRequest.fromJson);
  static const codecCreateVaultResponse =
      RpcCodec<CreateVaultResponse>.withDecoder(CreateVaultResponse.fromJson);
  static const codecListVaultsRequest = RpcCodec<ListVaultsRequest>.withDecoder(
    ListVaultsRequest.fromJson,
  );
  static const codecListVaultsResponse =
      RpcCodec<ListVaultsResponse>.withDecoder(ListVaultsResponse.fromJson);
  static const codecUpdateVaultMetaRequest =
      RpcCodec<UpdateVaultMetaRequest>.withDecoder(
        UpdateVaultMetaRequest.fromJson,
      );
  static const codecUpdateVaultMetaResponse =
      RpcCodec<UpdateVaultMetaResponse>.withDecoder(
        UpdateVaultMetaResponse.fromJson,
      );
  static const codecUpdateVerificationTokenRequest =
      RpcCodec<UpdateVerificationTokenRequest>.withDecoder(
        UpdateVerificationTokenRequest.fromJson,
      );
  static const codecUpdateVerificationTokenResponse =
      RpcCodec<UpdateVerificationTokenResponse>.withDecoder(
        UpdateVerificationTokenResponse.fromJson,
      );
}

class VaultContractCaller extends RpcCallerContract implements IVaultContract {
  VaultContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? VaultContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<ListVaultsResponse> listVaults(
    ListVaultsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ListVaultsRequest, ListVaultsResponse>(
      methodName: VaultContractNames.listVaults,
      requestCodec: VaultContractCodecs.codecListVaultsRequest,
      responseCodec: VaultContractCodecs.codecListVaultsResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<CreateVaultResponse> createVault(
    CreateVaultRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CreateVaultRequest, CreateVaultResponse>(
      methodName: VaultContractNames.createVault,
      requestCodec: VaultContractCodecs.codecCreateVaultRequest,
      responseCodec: VaultContractCodecs.codecCreateVaultResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<UpdateVerificationTokenResponse> updateVerificationToken(
    UpdateVerificationTokenRequest request, {
    RpcContext? context,
  }) {
    return callUnary<
      UpdateVerificationTokenRequest,
      UpdateVerificationTokenResponse
    >(
      methodName: VaultContractNames.updateVerificationToken,
      requestCodec: VaultContractCodecs.codecUpdateVerificationTokenRequest,
      responseCodec: VaultContractCodecs.codecUpdateVerificationTokenResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<UpdateVaultMetaResponse> updateVaultMeta(
    UpdateVaultMetaRequest request, {
    RpcContext? context,
  }) {
    return callUnary<UpdateVaultMetaRequest, UpdateVaultMetaResponse>(
      methodName: VaultContractNames.updateVaultMeta,
      requestCodec: VaultContractCodecs.codecUpdateVaultMetaRequest,
      responseCodec: VaultContractCodecs.codecUpdateVaultMetaResponse,
      request: request,
      context: context,
    );
  }
}

abstract class VaultContractResponder extends RpcResponderContract
    implements IVaultContract {
  VaultContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? VaultContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<ListVaultsRequest, ListVaultsResponse>(
      methodName: VaultContractNames.listVaults,
      handler: listVaults,
      requestCodec: VaultContractCodecs.codecListVaultsRequest,
      responseCodec: VaultContractCodecs.codecListVaultsResponse,
    );
    addUnaryMethod<CreateVaultRequest, CreateVaultResponse>(
      methodName: VaultContractNames.createVault,
      handler: createVault,
      requestCodec: VaultContractCodecs.codecCreateVaultRequest,
      responseCodec: VaultContractCodecs.codecCreateVaultResponse,
    );
    addUnaryMethod<
      UpdateVerificationTokenRequest,
      UpdateVerificationTokenResponse
    >(
      methodName: VaultContractNames.updateVerificationToken,
      handler: updateVerificationToken,
      requestCodec: VaultContractCodecs.codecUpdateVerificationTokenRequest,
      responseCodec: VaultContractCodecs.codecUpdateVerificationTokenResponse,
    );
    addUnaryMethod<UpdateVaultMetaRequest, UpdateVaultMetaResponse>(
      methodName: VaultContractNames.updateVaultMeta,
      handler: updateVaultMeta,
      requestCodec: VaultContractCodecs.codecUpdateVaultMetaRequest,
      responseCodec: VaultContractCodecs.codecUpdateVaultMetaResponse,
    );
  }
}
