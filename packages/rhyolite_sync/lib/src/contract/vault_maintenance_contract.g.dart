// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'vault_maintenance_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class VaultMaintenanceContractNames {
  const VaultMaintenanceContractNames._();
  static const service = 'RhyoliteVaultMaintenance';
  static String instance(String suffix) => '$service\_$suffix';
  static const sweepOrphanBlobs = 'sweepOrphanBlobs';
  static const sweepStableTombstones = 'sweepStableTombstones';
}

class VaultMaintenanceContractCodecs {
  const VaultMaintenanceContractCodecs._();
  static const codecSweepOrphanBlobsRequest =
      RpcCodec<SweepOrphanBlobsRequest>.withDecoder(
        SweepOrphanBlobsRequest.fromJson,
      );
  static const codecSweepOrphanBlobsResponse =
      RpcCodec<SweepOrphanBlobsResponse>.withDecoder(
        SweepOrphanBlobsResponse.fromJson,
      );
  static const codecSweepStableTombstonesRequest =
      RpcCodec<SweepStableTombstonesRequest>.withDecoder(
        SweepStableTombstonesRequest.fromJson,
      );
  static const codecSweepStableTombstonesResponse =
      RpcCodec<SweepStableTombstonesResponse>.withDecoder(
        SweepStableTombstonesResponse.fromJson,
      );
}

class VaultMaintenanceContractCaller extends RpcCallerContract
    implements IVaultMaintenanceContract {
  VaultMaintenanceContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? VaultMaintenanceContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<SweepOrphanBlobsResponse> sweepOrphanBlobs(
    SweepOrphanBlobsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<SweepOrphanBlobsRequest, SweepOrphanBlobsResponse>(
      methodName: VaultMaintenanceContractNames.sweepOrphanBlobs,
      requestCodec: VaultMaintenanceContractCodecs.codecSweepOrphanBlobsRequest,
      responseCodec:
          VaultMaintenanceContractCodecs.codecSweepOrphanBlobsResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<SweepStableTombstonesResponse> sweepStableTombstones(
    SweepStableTombstonesRequest request, {
    RpcContext? context,
  }) {
    return callUnary<
      SweepStableTombstonesRequest,
      SweepStableTombstonesResponse
    >(
      methodName: VaultMaintenanceContractNames.sweepStableTombstones,
      requestCodec:
          VaultMaintenanceContractCodecs.codecSweepStableTombstonesRequest,
      responseCodec:
          VaultMaintenanceContractCodecs.codecSweepStableTombstonesResponse,
      request: request,
      context: context,
    );
  }
}

abstract class VaultMaintenanceContractResponder extends RpcResponderContract
    implements IVaultMaintenanceContract {
  VaultMaintenanceContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? VaultMaintenanceContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<SweepOrphanBlobsRequest, SweepOrphanBlobsResponse>(
      methodName: VaultMaintenanceContractNames.sweepOrphanBlobs,
      handler: sweepOrphanBlobs,
      requestCodec: VaultMaintenanceContractCodecs.codecSweepOrphanBlobsRequest,
      responseCodec:
          VaultMaintenanceContractCodecs.codecSweepOrphanBlobsResponse,
    );
    addUnaryMethod<SweepStableTombstonesRequest, SweepStableTombstonesResponse>(
      methodName: VaultMaintenanceContractNames.sweepStableTombstones,
      handler: sweepStableTombstones,
      requestCodec:
          VaultMaintenanceContractCodecs.codecSweepStableTombstonesRequest,
      responseCodec:
          VaultMaintenanceContractCodecs.codecSweepStableTombstonesResponse,
    );
  }
}
