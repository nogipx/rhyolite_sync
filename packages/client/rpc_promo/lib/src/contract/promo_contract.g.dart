// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'promo_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class PromoContractNames {
  const PromoContractNames._();
  static const service = 'Promo';
  static String instance(String suffix) => '$service\_$suffix';
  static const redeem = 'redeem';
}

class PromoContractCodecs {
  const PromoContractCodecs._();
  static const codecRedeemPromoRequest =
      RpcCodec<RedeemPromoRequest>.withDecoder(RedeemPromoRequest.fromJson);
  static const codecRedeemPromoResponse =
      RpcCodec<RedeemPromoResponse>.withDecoder(RedeemPromoResponse.fromJson);
}

class PromoContractCaller extends RpcCallerContract implements IPromoContract {
  PromoContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? PromoContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<RedeemPromoResponse> redeem(
    RedeemPromoRequest request, {
    RpcContext? context,
  }) {
    return callUnary<RedeemPromoRequest, RedeemPromoResponse>(
      methodName: PromoContractNames.redeem,
      requestCodec: PromoContractCodecs.codecRedeemPromoRequest,
      responseCodec: PromoContractCodecs.codecRedeemPromoResponse,
      request: request,
      context: context,
    );
  }
}

abstract class PromoContractResponder extends RpcResponderContract
    implements IPromoContract {
  PromoContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? PromoContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<RedeemPromoRequest, RedeemPromoResponse>(
      methodName: PromoContractNames.redeem,
      handler: redeem,
      requestCodec: PromoContractCodecs.codecRedeemPromoRequest,
      responseCodec: PromoContractCodecs.codecRedeemPromoResponse,
    );
  }
}

// ignore_for_file: type=lint, unused_element

class AdminPromoContractNames {
  const AdminPromoContractNames._();
  static const service = 'AdminPromo';
  static String instance(String suffix) => '$service\_$suffix';
  static const createPromoCode = 'createPromoCode';
  static const createPromoBatch = 'createPromoBatch';
  static const listPromoCodes = 'listPromoCodes';
  static const deactivatePromoCode = 'deactivatePromoCode';
}

class AdminPromoContractCodecs {
  const AdminPromoContractCodecs._();
  static const codecCreatePromoBatchRequest =
      RpcCodec<CreatePromoBatchRequest>.withDecoder(
        CreatePromoBatchRequest.fromJson,
      );
  static const codecCreatePromoBatchResponse =
      RpcCodec<CreatePromoBatchResponse>.withDecoder(
        CreatePromoBatchResponse.fromJson,
      );
  static const codecCreatePromoCodeRequest =
      RpcCodec<CreatePromoCodeRequest>.withDecoder(
        CreatePromoCodeRequest.fromJson,
      );
  static const codecCreatePromoCodeResponse =
      RpcCodec<CreatePromoCodeResponse>.withDecoder(
        CreatePromoCodeResponse.fromJson,
      );
  static const codecDeactivatePromoCodeRequest =
      RpcCodec<DeactivatePromoCodeRequest>.withDecoder(
        DeactivatePromoCodeRequest.fromJson,
      );
  static const codecDeactivatePromoCodeResponse =
      RpcCodec<DeactivatePromoCodeResponse>.withDecoder(
        DeactivatePromoCodeResponse.fromJson,
      );
  static const codecListPromoCodesRequest =
      RpcCodec<ListPromoCodesRequest>.withDecoder(
        ListPromoCodesRequest.fromJson,
      );
  static const codecListPromoCodesResponse =
      RpcCodec<ListPromoCodesResponse>.withDecoder(
        ListPromoCodesResponse.fromJson,
      );
}

class AdminPromoContractCaller extends RpcCallerContract
    implements IAdminPromoContract {
  AdminPromoContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? AdminPromoContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<CreatePromoCodeResponse> createPromoCode(
    CreatePromoCodeRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CreatePromoCodeRequest, CreatePromoCodeResponse>(
      methodName: AdminPromoContractNames.createPromoCode,
      requestCodec: AdminPromoContractCodecs.codecCreatePromoCodeRequest,
      responseCodec: AdminPromoContractCodecs.codecCreatePromoCodeResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<CreatePromoBatchResponse> createPromoBatch(
    CreatePromoBatchRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CreatePromoBatchRequest, CreatePromoBatchResponse>(
      methodName: AdminPromoContractNames.createPromoBatch,
      requestCodec: AdminPromoContractCodecs.codecCreatePromoBatchRequest,
      responseCodec: AdminPromoContractCodecs.codecCreatePromoBatchResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<ListPromoCodesResponse> listPromoCodes(
    ListPromoCodesRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ListPromoCodesRequest, ListPromoCodesResponse>(
      methodName: AdminPromoContractNames.listPromoCodes,
      requestCodec: AdminPromoContractCodecs.codecListPromoCodesRequest,
      responseCodec: AdminPromoContractCodecs.codecListPromoCodesResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<DeactivatePromoCodeResponse> deactivatePromoCode(
    DeactivatePromoCodeRequest request, {
    RpcContext? context,
  }) {
    return callUnary<DeactivatePromoCodeRequest, DeactivatePromoCodeResponse>(
      methodName: AdminPromoContractNames.deactivatePromoCode,
      requestCodec: AdminPromoContractCodecs.codecDeactivatePromoCodeRequest,
      responseCodec: AdminPromoContractCodecs.codecDeactivatePromoCodeResponse,
      request: request,
      context: context,
    );
  }
}

abstract class AdminPromoContractResponder extends RpcResponderContract
    implements IAdminPromoContract {
  AdminPromoContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? AdminPromoContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<CreatePromoCodeRequest, CreatePromoCodeResponse>(
      methodName: AdminPromoContractNames.createPromoCode,
      handler: createPromoCode,
      requestCodec: AdminPromoContractCodecs.codecCreatePromoCodeRequest,
      responseCodec: AdminPromoContractCodecs.codecCreatePromoCodeResponse,
    );
    addUnaryMethod<CreatePromoBatchRequest, CreatePromoBatchResponse>(
      methodName: AdminPromoContractNames.createPromoBatch,
      handler: createPromoBatch,
      requestCodec: AdminPromoContractCodecs.codecCreatePromoBatchRequest,
      responseCodec: AdminPromoContractCodecs.codecCreatePromoBatchResponse,
    );
    addUnaryMethod<ListPromoCodesRequest, ListPromoCodesResponse>(
      methodName: AdminPromoContractNames.listPromoCodes,
      handler: listPromoCodes,
      requestCodec: AdminPromoContractCodecs.codecListPromoCodesRequest,
      responseCodec: AdminPromoContractCodecs.codecListPromoCodesResponse,
    );
    addUnaryMethod<DeactivatePromoCodeRequest, DeactivatePromoCodeResponse>(
      methodName: AdminPromoContractNames.deactivatePromoCode,
      handler: deactivatePromoCode,
      requestCodec: AdminPromoContractCodecs.codecDeactivatePromoCodeRequest,
      responseCodec: AdminPromoContractCodecs.codecDeactivatePromoCodeResponse,
    );
  }
}
