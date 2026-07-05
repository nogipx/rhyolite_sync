// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'admin_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class AdminContractNames {
  const AdminContractNames._();
  static const service = 'RhyoliteAdmin';
  static String instance(String suffix) => '$service\_$suffix';
  static const listUsers = 'listUsers';
  static const getUser = 'getUser';
  static const grantSubscription = 'grantSubscription';
  static const revokeSubscription = 'revokeSubscription';
  static const changeUserRole = 'changeUserRole';
}

class AdminContractCodecs {
  const AdminContractCodecs._();
  static const codecChangeUserRoleRequest =
      RpcCodec<ChangeUserRoleRequest>.withDecoder(
        ChangeUserRoleRequest.fromJson,
      );
  static const codecChangeUserRoleResponse =
      RpcCodec<ChangeUserRoleResponse>.withDecoder(
        ChangeUserRoleResponse.fromJson,
      );
  static const codecGetUserRequest = RpcCodec<GetUserRequest>.withDecoder(
    GetUserRequest.fromJson,
  );
  static const codecGetUserResponse = RpcCodec<GetUserResponse>.withDecoder(
    GetUserResponse.fromJson,
  );
  static const codecGrantSubscriptionRequest =
      RpcCodec<GrantSubscriptionRequest>.withDecoder(
        GrantSubscriptionRequest.fromJson,
      );
  static const codecGrantSubscriptionResponse =
      RpcCodec<GrantSubscriptionResponse>.withDecoder(
        GrantSubscriptionResponse.fromJson,
      );
  static const codecListUsersRequest = RpcCodec<ListUsersRequest>.withDecoder(
    ListUsersRequest.fromJson,
  );
  static const codecListUsersResponse = RpcCodec<ListUsersResponse>.withDecoder(
    ListUsersResponse.fromJson,
  );
  static const codecRevokeSubscriptionRequest =
      RpcCodec<RevokeSubscriptionRequest>.withDecoder(
        RevokeSubscriptionRequest.fromJson,
      );
  static const codecRevokeSubscriptionResponse =
      RpcCodec<RevokeSubscriptionResponse>.withDecoder(
        RevokeSubscriptionResponse.fromJson,
      );
}

class AdminContractCaller extends RpcCallerContract implements IAdminContract {
  AdminContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? AdminContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<ListUsersResponse> listUsers(
    ListUsersRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ListUsersRequest, ListUsersResponse>(
      methodName: AdminContractNames.listUsers,
      requestCodec: AdminContractCodecs.codecListUsersRequest,
      responseCodec: AdminContractCodecs.codecListUsersResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<GetUserResponse> getUser(
    GetUserRequest request, {
    RpcContext? context,
  }) {
    return callUnary<GetUserRequest, GetUserResponse>(
      methodName: AdminContractNames.getUser,
      requestCodec: AdminContractCodecs.codecGetUserRequest,
      responseCodec: AdminContractCodecs.codecGetUserResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<GrantSubscriptionResponse> grantSubscription(
    GrantSubscriptionRequest request, {
    RpcContext? context,
  }) {
    return callUnary<GrantSubscriptionRequest, GrantSubscriptionResponse>(
      methodName: AdminContractNames.grantSubscription,
      requestCodec: AdminContractCodecs.codecGrantSubscriptionRequest,
      responseCodec: AdminContractCodecs.codecGrantSubscriptionResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<RevokeSubscriptionResponse> revokeSubscription(
    RevokeSubscriptionRequest request, {
    RpcContext? context,
  }) {
    return callUnary<RevokeSubscriptionRequest, RevokeSubscriptionResponse>(
      methodName: AdminContractNames.revokeSubscription,
      requestCodec: AdminContractCodecs.codecRevokeSubscriptionRequest,
      responseCodec: AdminContractCodecs.codecRevokeSubscriptionResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<ChangeUserRoleResponse> changeUserRole(
    ChangeUserRoleRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ChangeUserRoleRequest, ChangeUserRoleResponse>(
      methodName: AdminContractNames.changeUserRole,
      requestCodec: AdminContractCodecs.codecChangeUserRoleRequest,
      responseCodec: AdminContractCodecs.codecChangeUserRoleResponse,
      request: request,
      context: context,
    );
  }
}

abstract class AdminContractResponder extends RpcResponderContract
    implements IAdminContract {
  AdminContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? AdminContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<ListUsersRequest, ListUsersResponse>(
      methodName: AdminContractNames.listUsers,
      handler: listUsers,
      requestCodec: AdminContractCodecs.codecListUsersRequest,
      responseCodec: AdminContractCodecs.codecListUsersResponse,
    );
    addUnaryMethod<GetUserRequest, GetUserResponse>(
      methodName: AdminContractNames.getUser,
      handler: getUser,
      requestCodec: AdminContractCodecs.codecGetUserRequest,
      responseCodec: AdminContractCodecs.codecGetUserResponse,
    );
    addUnaryMethod<GrantSubscriptionRequest, GrantSubscriptionResponse>(
      methodName: AdminContractNames.grantSubscription,
      handler: grantSubscription,
      requestCodec: AdminContractCodecs.codecGrantSubscriptionRequest,
      responseCodec: AdminContractCodecs.codecGrantSubscriptionResponse,
    );
    addUnaryMethod<RevokeSubscriptionRequest, RevokeSubscriptionResponse>(
      methodName: AdminContractNames.revokeSubscription,
      handler: revokeSubscription,
      requestCodec: AdminContractCodecs.codecRevokeSubscriptionRequest,
      responseCodec: AdminContractCodecs.codecRevokeSubscriptionResponse,
    );
    addUnaryMethod<ChangeUserRoleRequest, ChangeUserRoleResponse>(
      methodName: AdminContractNames.changeUserRole,
      handler: changeUserRole,
      requestCodec: AdminContractCodecs.codecChangeUserRoleRequest,
      responseCodec: AdminContractCodecs.codecChangeUserRoleResponse,
    );
  }
}
