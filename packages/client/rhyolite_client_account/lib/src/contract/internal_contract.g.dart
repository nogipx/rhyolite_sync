// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'internal_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class InternalContractNames {
  const InternalContractNames._();
  static const service = 'RhyoliteInternal';
  static String instance(String suffix) => '$service\_$suffix';
  static const checkVaultOwnership = 'checkVaultOwnership';
  static const createVaultForUser = 'createVaultForUser';
  static const checkSubscription = 'checkSubscription';
  static const getPlan = 'getPlan';
  static const redeemPromo = 'redeemPromo';
}

class InternalContractCodecs {
  const InternalContractCodecs._();
  static const codecCheckSubscriptionRequest =
      RpcCodec<CheckSubscriptionRequest>.withDecoder(
        CheckSubscriptionRequest.fromJson,
      );
  static const codecCheckSubscriptionResponse =
      RpcCodec<CheckSubscriptionResponse>.withDecoder(
        CheckSubscriptionResponse.fromJson,
      );
  static const codecCheckVaultOwnershipRequest =
      RpcCodec<CheckVaultOwnershipRequest>.withDecoder(
        CheckVaultOwnershipRequest.fromJson,
      );
  static const codecCheckVaultOwnershipResponse =
      RpcCodec<CheckVaultOwnershipResponse>.withDecoder(
        CheckVaultOwnershipResponse.fromJson,
      );
  static const codecCreateVaultForUserRequest =
      RpcCodec<CreateVaultForUserRequest>.withDecoder(
        CreateVaultForUserRequest.fromJson,
      );
  static const codecCreateVaultForUserResponse =
      RpcCodec<CreateVaultForUserResponse>.withDecoder(
        CreateVaultForUserResponse.fromJson,
      );
  static const codecGetPlanRequest = RpcCodec<GetPlanRequest>.withDecoder(
    GetPlanRequest.fromJson,
  );
  static const codecGetPlanResponse = RpcCodec<GetPlanResponse>.withDecoder(
    GetPlanResponse.fromJson,
  );
  static const codecRedeemPromoRequest =
      RpcCodec<RedeemPromoRequest>.withDecoder(RedeemPromoRequest.fromJson);
  static const codecRedeemPromoResponse =
      RpcCodec<RedeemPromoResponse>.withDecoder(RedeemPromoResponse.fromJson);
}

class InternalContractCaller extends RpcCallerContract
    implements IInternalContract {
  InternalContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? InternalContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<CheckVaultOwnershipResponse> checkVaultOwnership(
    CheckVaultOwnershipRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CheckVaultOwnershipRequest, CheckVaultOwnershipResponse>(
      methodName: InternalContractNames.checkVaultOwnership,
      requestCodec: InternalContractCodecs.codecCheckVaultOwnershipRequest,
      responseCodec: InternalContractCodecs.codecCheckVaultOwnershipResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<CreateVaultForUserResponse> createVaultForUser(
    CreateVaultForUserRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CreateVaultForUserRequest, CreateVaultForUserResponse>(
      methodName: InternalContractNames.createVaultForUser,
      requestCodec: InternalContractCodecs.codecCreateVaultForUserRequest,
      responseCodec: InternalContractCodecs.codecCreateVaultForUserResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<CheckSubscriptionResponse> checkSubscription(
    CheckSubscriptionRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CheckSubscriptionRequest, CheckSubscriptionResponse>(
      methodName: InternalContractNames.checkSubscription,
      requestCodec: InternalContractCodecs.codecCheckSubscriptionRequest,
      responseCodec: InternalContractCodecs.codecCheckSubscriptionResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<GetPlanResponse> getPlan(
    GetPlanRequest request, {
    RpcContext? context,
  }) {
    return callUnary<GetPlanRequest, GetPlanResponse>(
      methodName: InternalContractNames.getPlan,
      requestCodec: InternalContractCodecs.codecGetPlanRequest,
      responseCodec: InternalContractCodecs.codecGetPlanResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<RedeemPromoResponse> redeemPromo(
    RedeemPromoRequest request, {
    RpcContext? context,
  }) {
    return callUnary<RedeemPromoRequest, RedeemPromoResponse>(
      methodName: InternalContractNames.redeemPromo,
      requestCodec: InternalContractCodecs.codecRedeemPromoRequest,
      responseCodec: InternalContractCodecs.codecRedeemPromoResponse,
      request: request,
      context: context,
    );
  }
}

abstract class InternalContractResponder extends RpcResponderContract
    implements IInternalContract {
  InternalContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? InternalContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<CheckVaultOwnershipRequest, CheckVaultOwnershipResponse>(
      methodName: InternalContractNames.checkVaultOwnership,
      handler: checkVaultOwnership,
      requestCodec: InternalContractCodecs.codecCheckVaultOwnershipRequest,
      responseCodec: InternalContractCodecs.codecCheckVaultOwnershipResponse,
    );
    addUnaryMethod<CreateVaultForUserRequest, CreateVaultForUserResponse>(
      methodName: InternalContractNames.createVaultForUser,
      handler: createVaultForUser,
      requestCodec: InternalContractCodecs.codecCreateVaultForUserRequest,
      responseCodec: InternalContractCodecs.codecCreateVaultForUserResponse,
    );
    addUnaryMethod<CheckSubscriptionRequest, CheckSubscriptionResponse>(
      methodName: InternalContractNames.checkSubscription,
      handler: checkSubscription,
      requestCodec: InternalContractCodecs.codecCheckSubscriptionRequest,
      responseCodec: InternalContractCodecs.codecCheckSubscriptionResponse,
    );
    addUnaryMethod<GetPlanRequest, GetPlanResponse>(
      methodName: InternalContractNames.getPlan,
      handler: getPlan,
      requestCodec: InternalContractCodecs.codecGetPlanRequest,
      responseCodec: InternalContractCodecs.codecGetPlanResponse,
    );
    addUnaryMethod<RedeemPromoRequest, RedeemPromoResponse>(
      methodName: InternalContractNames.redeemPromo,
      handler: redeemPromo,
      requestCodec: InternalContractCodecs.codecRedeemPromoRequest,
      responseCodec: InternalContractCodecs.codecRedeemPromoResponse,
    );
  }
}
