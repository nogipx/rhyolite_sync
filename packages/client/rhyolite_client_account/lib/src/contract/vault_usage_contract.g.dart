// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'vault_usage_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class VaultUsageContractNames {
  const VaultUsageContractNames._();
  static const service = 'RhyoliteVaultUsage';
  static String instance(String suffix) => '$service\_$suffix';
  static const getVaultUsage = 'getVaultUsage';
}

class VaultUsageContractCodecs {
  const VaultUsageContractCodecs._();
  static const codecGetVaultUsageRequest =
      RpcCodec<GetVaultUsageRequest>.withDecoder(GetVaultUsageRequest.fromJson);
  static const codecGetVaultUsageResponse =
      RpcCodec<GetVaultUsageResponse>.withDecoder(
        GetVaultUsageResponse.fromJson,
      );
}

class VaultUsageContractCaller extends RpcCallerContract
    implements IVaultUsageContract {
  VaultUsageContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? VaultUsageContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<GetVaultUsageResponse> getVaultUsage(
    GetVaultUsageRequest request, {
    RpcContext? context,
  }) {
    return callUnary<GetVaultUsageRequest, GetVaultUsageResponse>(
      methodName: VaultUsageContractNames.getVaultUsage,
      requestCodec: VaultUsageContractCodecs.codecGetVaultUsageRequest,
      responseCodec: VaultUsageContractCodecs.codecGetVaultUsageResponse,
      request: request,
      context: context,
    );
  }
}

abstract class VaultUsageContractResponder extends RpcResponderContract
    implements IVaultUsageContract {
  VaultUsageContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? VaultUsageContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<GetVaultUsageRequest, GetVaultUsageResponse>(
      methodName: VaultUsageContractNames.getVaultUsage,
      handler: getVaultUsage,
      requestCodec: VaultUsageContractCodecs.codecGetVaultUsageRequest,
      responseCodec: VaultUsageContractCodecs.codecGetVaultUsageResponse,
    );
  }
}
