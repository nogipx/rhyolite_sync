// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'subscription_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class SubscriptionContractNames {
  const SubscriptionContractNames._();
  static const service = 'RhyoliteSubscription';
  static String instance(String suffix) => '$service\_$suffix';
  static const getSubscription = 'getSubscription';
  static const listInvoices = 'listInvoices';
  static const listProducts = 'listProducts';
  static const createPayment = 'createPayment';
  static const restoreSubscription = 'restoreSubscription';
}

class SubscriptionContractCodecs {
  const SubscriptionContractCodecs._();
  static const codecCreatePaymentRequest =
      RpcCodec<CreatePaymentRequest>.withDecoder(CreatePaymentRequest.fromJson);
  static const codecCreatePaymentResponse =
      RpcCodec<CreatePaymentResponse>.withDecoder(
        CreatePaymentResponse.fromJson,
      );
  static const codecGetSubscriptionRequest =
      RpcCodec<GetSubscriptionRequest>.withDecoder(
        GetSubscriptionRequest.fromJson,
      );
  static const codecListInvoicesRequest =
      RpcCodec<ListInvoicesRequest>.withDecoder(ListInvoicesRequest.fromJson);
  static const codecListInvoicesResponse =
      RpcCodec<ListInvoicesResponse>.withDecoder(ListInvoicesResponse.fromJson);
  static const codecListProductsRequest =
      RpcCodec<ListProductsRequest>.withDecoder(ListProductsRequest.fromJson);
  static const codecListProductsResponse =
      RpcCodec<ListProductsResponse>.withDecoder(ListProductsResponse.fromJson);
  static const codecRestoreSubscriptionRequest =
      RpcCodec<RestoreSubscriptionRequest>.withDecoder(
        RestoreSubscriptionRequest.fromJson,
      );
  static const codecRestoreSubscriptionResponse =
      RpcCodec<RestoreSubscriptionResponse>.withDecoder(
        RestoreSubscriptionResponse.fromJson,
      );
  static const codecSubscriptionDto = RpcCodec<SubscriptionDto>.withDecoder(
    SubscriptionDto.fromJson,
  );
}

class SubscriptionContractCaller extends RpcCallerContract
    implements ISubscriptionContract {
  SubscriptionContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? SubscriptionContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<SubscriptionDto> getSubscription(
    GetSubscriptionRequest request, {
    RpcContext? context,
  }) {
    return callUnary<GetSubscriptionRequest, SubscriptionDto>(
      methodName: SubscriptionContractNames.getSubscription,
      requestCodec: SubscriptionContractCodecs.codecGetSubscriptionRequest,
      responseCodec: SubscriptionContractCodecs.codecSubscriptionDto,
      request: request,
      context: context,
    );
  }

  @override
  Future<ListInvoicesResponse> listInvoices(
    ListInvoicesRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ListInvoicesRequest, ListInvoicesResponse>(
      methodName: SubscriptionContractNames.listInvoices,
      requestCodec: SubscriptionContractCodecs.codecListInvoicesRequest,
      responseCodec: SubscriptionContractCodecs.codecListInvoicesResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<ListProductsResponse> listProducts(
    ListProductsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ListProductsRequest, ListProductsResponse>(
      methodName: SubscriptionContractNames.listProducts,
      requestCodec: SubscriptionContractCodecs.codecListProductsRequest,
      responseCodec: SubscriptionContractCodecs.codecListProductsResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<CreatePaymentResponse> createPayment(
    CreatePaymentRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CreatePaymentRequest, CreatePaymentResponse>(
      methodName: SubscriptionContractNames.createPayment,
      requestCodec: SubscriptionContractCodecs.codecCreatePaymentRequest,
      responseCodec: SubscriptionContractCodecs.codecCreatePaymentResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<RestoreSubscriptionResponse> restoreSubscription(
    RestoreSubscriptionRequest request, {
    RpcContext? context,
  }) {
    return callUnary<RestoreSubscriptionRequest, RestoreSubscriptionResponse>(
      methodName: SubscriptionContractNames.restoreSubscription,
      requestCodec: SubscriptionContractCodecs.codecRestoreSubscriptionRequest,
      responseCodec:
          SubscriptionContractCodecs.codecRestoreSubscriptionResponse,
      request: request,
      context: context,
    );
  }
}

abstract class SubscriptionContractResponder extends RpcResponderContract
    implements ISubscriptionContract {
  SubscriptionContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? SubscriptionContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<GetSubscriptionRequest, SubscriptionDto>(
      methodName: SubscriptionContractNames.getSubscription,
      handler: getSubscription,
      requestCodec: SubscriptionContractCodecs.codecGetSubscriptionRequest,
      responseCodec: SubscriptionContractCodecs.codecSubscriptionDto,
    );
    addUnaryMethod<ListInvoicesRequest, ListInvoicesResponse>(
      methodName: SubscriptionContractNames.listInvoices,
      handler: listInvoices,
      requestCodec: SubscriptionContractCodecs.codecListInvoicesRequest,
      responseCodec: SubscriptionContractCodecs.codecListInvoicesResponse,
    );
    addUnaryMethod<ListProductsRequest, ListProductsResponse>(
      methodName: SubscriptionContractNames.listProducts,
      handler: listProducts,
      requestCodec: SubscriptionContractCodecs.codecListProductsRequest,
      responseCodec: SubscriptionContractCodecs.codecListProductsResponse,
    );
    addUnaryMethod<CreatePaymentRequest, CreatePaymentResponse>(
      methodName: SubscriptionContractNames.createPayment,
      handler: createPayment,
      requestCodec: SubscriptionContractCodecs.codecCreatePaymentRequest,
      responseCodec: SubscriptionContractCodecs.codecCreatePaymentResponse,
    );
    addUnaryMethod<RestoreSubscriptionRequest, RestoreSubscriptionResponse>(
      methodName: SubscriptionContractNames.restoreSubscription,
      handler: restoreSubscription,
      requestCodec: SubscriptionContractCodecs.codecRestoreSubscriptionRequest,
      responseCodec:
          SubscriptionContractCodecs.codecRestoreSubscriptionResponse,
    );
  }
}
