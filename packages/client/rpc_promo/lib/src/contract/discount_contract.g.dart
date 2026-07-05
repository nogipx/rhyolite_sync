// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'discount_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class DiscountContractNames {
  const DiscountContractNames._();
  static const service = 'Discount';
  static String instance(String suffix) => '$service\_$suffix';
  static const preview = 'preview';
}

class DiscountContractCodecs {
  const DiscountContractCodecs._();
  static const codecPreviewDiscountRequest =
      RpcCodec<PreviewDiscountRequest>.withDecoder(
        PreviewDiscountRequest.fromJson,
      );
  static const codecPreviewDiscountResponse =
      RpcCodec<PreviewDiscountResponse>.withDecoder(
        PreviewDiscountResponse.fromJson,
      );
}

class DiscountContractCaller extends RpcCallerContract
    implements IDiscountContract {
  DiscountContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? DiscountContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<PreviewDiscountResponse> preview(
    PreviewDiscountRequest request, {
    RpcContext? context,
  }) {
    return callUnary<PreviewDiscountRequest, PreviewDiscountResponse>(
      methodName: DiscountContractNames.preview,
      requestCodec: DiscountContractCodecs.codecPreviewDiscountRequest,
      responseCodec: DiscountContractCodecs.codecPreviewDiscountResponse,
      request: request,
      context: context,
    );
  }
}

abstract class DiscountContractResponder extends RpcResponderContract
    implements IDiscountContract {
  DiscountContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? DiscountContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<PreviewDiscountRequest, PreviewDiscountResponse>(
      methodName: DiscountContractNames.preview,
      handler: preview,
      requestCodec: DiscountContractCodecs.codecPreviewDiscountRequest,
      responseCodec: DiscountContractCodecs.codecPreviewDiscountResponse,
    );
  }
}

// ignore_for_file: type=lint, unused_element

class AdminDiscountContractNames {
  const AdminDiscountContractNames._();
  static const service = 'AdminDiscount';
  static String instance(String suffix) => '$service\_$suffix';
  static const createDiscountCode = 'createDiscountCode';
  static const createDiscountBatch = 'createDiscountBatch';
  static const listDiscountCodes = 'listDiscountCodes';
  static const deactivateDiscountCode = 'deactivateDiscountCode';
}

class AdminDiscountContractCodecs {
  const AdminDiscountContractCodecs._();
  static const codecCreateDiscountBatchRequest =
      RpcCodec<CreateDiscountBatchRequest>.withDecoder(
        CreateDiscountBatchRequest.fromJson,
      );
  static const codecCreateDiscountBatchResponse =
      RpcCodec<CreateDiscountBatchResponse>.withDecoder(
        CreateDiscountBatchResponse.fromJson,
      );
  static const codecCreateDiscountCodeRequest =
      RpcCodec<CreateDiscountCodeRequest>.withDecoder(
        CreateDiscountCodeRequest.fromJson,
      );
  static const codecCreateDiscountCodeResponse =
      RpcCodec<CreateDiscountCodeResponse>.withDecoder(
        CreateDiscountCodeResponse.fromJson,
      );
  static const codecDeactivateDiscountCodeRequest =
      RpcCodec<DeactivateDiscountCodeRequest>.withDecoder(
        DeactivateDiscountCodeRequest.fromJson,
      );
  static const codecDeactivateDiscountCodeResponse =
      RpcCodec<DeactivateDiscountCodeResponse>.withDecoder(
        DeactivateDiscountCodeResponse.fromJson,
      );
  static const codecListDiscountCodesRequest =
      RpcCodec<ListDiscountCodesRequest>.withDecoder(
        ListDiscountCodesRequest.fromJson,
      );
  static const codecListDiscountCodesResponse =
      RpcCodec<ListDiscountCodesResponse>.withDecoder(
        ListDiscountCodesResponse.fromJson,
      );
}

class AdminDiscountContractCaller extends RpcCallerContract
    implements IAdminDiscountContract {
  AdminDiscountContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? AdminDiscountContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<CreateDiscountCodeResponse> createDiscountCode(
    CreateDiscountCodeRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CreateDiscountCodeRequest, CreateDiscountCodeResponse>(
      methodName: AdminDiscountContractNames.createDiscountCode,
      requestCodec: AdminDiscountContractCodecs.codecCreateDiscountCodeRequest,
      responseCodec:
          AdminDiscountContractCodecs.codecCreateDiscountCodeResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<CreateDiscountBatchResponse> createDiscountBatch(
    CreateDiscountBatchRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CreateDiscountBatchRequest, CreateDiscountBatchResponse>(
      methodName: AdminDiscountContractNames.createDiscountBatch,
      requestCodec: AdminDiscountContractCodecs.codecCreateDiscountBatchRequest,
      responseCodec:
          AdminDiscountContractCodecs.codecCreateDiscountBatchResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<ListDiscountCodesResponse> listDiscountCodes(
    ListDiscountCodesRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ListDiscountCodesRequest, ListDiscountCodesResponse>(
      methodName: AdminDiscountContractNames.listDiscountCodes,
      requestCodec: AdminDiscountContractCodecs.codecListDiscountCodesRequest,
      responseCodec: AdminDiscountContractCodecs.codecListDiscountCodesResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<DeactivateDiscountCodeResponse> deactivateDiscountCode(
    DeactivateDiscountCodeRequest request, {
    RpcContext? context,
  }) {
    return callUnary<
      DeactivateDiscountCodeRequest,
      DeactivateDiscountCodeResponse
    >(
      methodName: AdminDiscountContractNames.deactivateDiscountCode,
      requestCodec:
          AdminDiscountContractCodecs.codecDeactivateDiscountCodeRequest,
      responseCodec:
          AdminDiscountContractCodecs.codecDeactivateDiscountCodeResponse,
      request: request,
      context: context,
    );
  }
}

abstract class AdminDiscountContractResponder extends RpcResponderContract
    implements IAdminDiscountContract {
  AdminDiscountContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? AdminDiscountContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<CreateDiscountCodeRequest, CreateDiscountCodeResponse>(
      methodName: AdminDiscountContractNames.createDiscountCode,
      handler: createDiscountCode,
      requestCodec: AdminDiscountContractCodecs.codecCreateDiscountCodeRequest,
      responseCodec:
          AdminDiscountContractCodecs.codecCreateDiscountCodeResponse,
    );
    addUnaryMethod<CreateDiscountBatchRequest, CreateDiscountBatchResponse>(
      methodName: AdminDiscountContractNames.createDiscountBatch,
      handler: createDiscountBatch,
      requestCodec: AdminDiscountContractCodecs.codecCreateDiscountBatchRequest,
      responseCodec:
          AdminDiscountContractCodecs.codecCreateDiscountBatchResponse,
    );
    addUnaryMethod<ListDiscountCodesRequest, ListDiscountCodesResponse>(
      methodName: AdminDiscountContractNames.listDiscountCodes,
      handler: listDiscountCodes,
      requestCodec: AdminDiscountContractCodecs.codecListDiscountCodesRequest,
      responseCodec: AdminDiscountContractCodecs.codecListDiscountCodesResponse,
    );
    addUnaryMethod<
      DeactivateDiscountCodeRequest,
      DeactivateDiscountCodeResponse
    >(
      methodName: AdminDiscountContractNames.deactivateDiscountCode,
      handler: deactivateDiscountCode,
      requestCodec:
          AdminDiscountContractCodecs.codecDeactivateDiscountCodeRequest,
      responseCodec:
          AdminDiscountContractCodecs.codecDeactivateDiscountCodeResponse,
    );
  }
}
