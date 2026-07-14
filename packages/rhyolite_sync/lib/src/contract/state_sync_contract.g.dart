// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'state_sync_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class StateSyncContractNames {
  const StateSyncContractNames._();
  static const service = 'RhyoliteStateSync';
  static String instance(String suffix) => '$service\_$suffix';
  static const getStates = 'getStates';
  static const putStates = 'putStates';
  static const wipeVault = 'wipeVault';
  static const purgeVault = 'purgeVault';
}

class StateSyncContractCodecs {
  const StateSyncContractCodecs._();
  static const codecStateGetRequest = RpcCodec<StateGetRequest>.withDecoder(
    StateGetRequest.fromJson,
  );
  static const codecStateGetResponse = RpcCodec<StateGetResponse>.withDecoder(
    StateGetResponse.fromJson,
  );
  static const codecStatePurgeRequest = RpcCodec<StatePurgeRequest>.withDecoder(
    StatePurgeRequest.fromJson,
  );
  static const codecStatePurgeResponse =
      RpcCodec<StatePurgeResponse>.withDecoder(StatePurgeResponse.fromJson);
  static const codecStatePutRequest = RpcCodec<StatePutRequest>.withDecoder(
    StatePutRequest.fromJson,
  );
  static const codecStatePutResponse = RpcCodec<StatePutResponse>.withDecoder(
    StatePutResponse.fromJson,
  );
  static const codecStateWipeRequest = RpcCodec<StateWipeRequest>.withDecoder(
    StateWipeRequest.fromJson,
  );
  static const codecStateWipeResponse = RpcCodec<StateWipeResponse>.withDecoder(
    StateWipeResponse.fromJson,
  );
}

class StateSyncContractCaller extends RpcCallerContract
    implements IStateSyncContract {
  StateSyncContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? StateSyncContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<StateGetResponse> getStates(
    StateGetRequest request, {
    RpcContext? context,
  }) {
    return callUnary<StateGetRequest, StateGetResponse>(
      methodName: StateSyncContractNames.getStates,
      requestCodec: StateSyncContractCodecs.codecStateGetRequest,
      responseCodec: StateSyncContractCodecs.codecStateGetResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<StatePutResponse> putStates(
    StatePutRequest request, {
    RpcContext? context,
  }) {
    return callUnary<StatePutRequest, StatePutResponse>(
      methodName: StateSyncContractNames.putStates,
      requestCodec: StateSyncContractCodecs.codecStatePutRequest,
      responseCodec: StateSyncContractCodecs.codecStatePutResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<StateWipeResponse> wipeVault(
    StateWipeRequest request, {
    RpcContext? context,
  }) {
    return callUnary<StateWipeRequest, StateWipeResponse>(
      methodName: StateSyncContractNames.wipeVault,
      requestCodec: StateSyncContractCodecs.codecStateWipeRequest,
      responseCodec: StateSyncContractCodecs.codecStateWipeResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<StatePurgeResponse> purgeVault(
    StatePurgeRequest request, {
    RpcContext? context,
  }) {
    return callUnary<StatePurgeRequest, StatePurgeResponse>(
      methodName: StateSyncContractNames.purgeVault,
      requestCodec: StateSyncContractCodecs.codecStatePurgeRequest,
      responseCodec: StateSyncContractCodecs.codecStatePurgeResponse,
      request: request,
      context: context,
    );
  }
}

abstract class StateSyncContractResponder extends RpcResponderContract
    implements IStateSyncContract {
  StateSyncContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? StateSyncContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<StateGetRequest, StateGetResponse>(
      methodName: StateSyncContractNames.getStates,
      handler: getStates,
      requestCodec: StateSyncContractCodecs.codecStateGetRequest,
      responseCodec: StateSyncContractCodecs.codecStateGetResponse,
    );
    addUnaryMethod<StatePutRequest, StatePutResponse>(
      methodName: StateSyncContractNames.putStates,
      handler: putStates,
      requestCodec: StateSyncContractCodecs.codecStatePutRequest,
      responseCodec: StateSyncContractCodecs.codecStatePutResponse,
    );
    addUnaryMethod<StateWipeRequest, StateWipeResponse>(
      methodName: StateSyncContractNames.wipeVault,
      handler: wipeVault,
      requestCodec: StateSyncContractCodecs.codecStateWipeRequest,
      responseCodec: StateSyncContractCodecs.codecStateWipeResponse,
    );
    addUnaryMethod<StatePurgeRequest, StatePurgeResponse>(
      methodName: StateSyncContractNames.purgeVault,
      handler: purgeVault,
      requestCodec: StateSyncContractCodecs.codecStatePurgeRequest,
      responseCodec: StateSyncContractCodecs.codecStatePurgeResponse,
    );
  }
}
