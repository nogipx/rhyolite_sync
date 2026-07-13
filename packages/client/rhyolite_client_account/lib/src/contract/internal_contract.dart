import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../models/plan.dart';

part 'internal_contract.g.dart';

// --- DTOs ---

class CheckVaultOwnershipRequest implements IRpcSerializable {
  const CheckVaultOwnershipRequest({
    required this.userId,
    required this.vaultId,
  });

  final String userId;
  final String vaultId;

  factory CheckVaultOwnershipRequest.fromJson(Map<String, dynamic> json) =>
      CheckVaultOwnershipRequest(
        userId: json['user_id'] as String,
        vaultId: json['vault_id'] as String,
      );

  @override
  Map<String, dynamic> toJson() => {'user_id': userId, 'vault_id': vaultId};
}

class CheckVaultOwnershipResponse implements IRpcSerializable {
  const CheckVaultOwnershipResponse({required this.owned});

  final bool owned;

  factory CheckVaultOwnershipResponse.fromJson(Map<String, dynamic> json) =>
      CheckVaultOwnershipResponse(owned: json['owned'] as bool);

  @override
  Map<String, dynamic> toJson() => {'owned': owned};
}

class CreateVaultForUserRequest implements IRpcSerializable {
  const CreateVaultForUserRequest({
    required this.userId,
    required this.vaultId,
  });

  final String userId;
  final String vaultId;

  factory CreateVaultForUserRequest.fromJson(Map<String, dynamic> json) =>
      CreateVaultForUserRequest(
        userId: json['user_id'] as String,
        vaultId: json['vault_id'] as String,
      );

  @override
  Map<String, dynamic> toJson() => {'user_id': userId, 'vault_id': vaultId};
}

class CreateVaultForUserResponse implements IRpcSerializable {
  const CreateVaultForUserResponse();

  factory CreateVaultForUserResponse.fromJson(Map<String, dynamic> _) =>
      const CreateVaultForUserResponse();

  @override
  Map<String, dynamic> toJson() => const {};
}

class CheckSubscriptionRequest implements IRpcSerializable {
  const CheckSubscriptionRequest({required this.userId});

  final String userId;

  factory CheckSubscriptionRequest.fromJson(Map<String, dynamic> json) =>
      CheckSubscriptionRequest(userId: json['user_id'] as String);

  @override
  Map<String, dynamic> toJson() => {'user_id': userId};
}

class CheckSubscriptionResponse implements IRpcSerializable {
  const CheckSubscriptionResponse({required this.active});

  final bool active;

  factory CheckSubscriptionResponse.fromJson(Map<String, dynamic> json) =>
      CheckSubscriptionResponse(active: json['active'] as bool);

  @override
  Map<String, dynamic> toJson() => {'active': active};
}

class GetPlanRequest implements IRpcSerializable {
  const GetPlanRequest({required this.userId});

  final String userId;

  factory GetPlanRequest.fromJson(Map<String, dynamic> json) =>
      GetPlanRequest(userId: json['user_id'] as String);

  @override
  Map<String, dynamic> toJson() => {'user_id': userId};
}

class GetPlanResponse implements IRpcSerializable {
  const GetPlanResponse({this.plan});

  /// Active plan, or `null` when the user has no active subscription.
  final Plan? plan;

  factory GetPlanResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['plan'];
    return GetPlanResponse(
      plan: raw == null
          ? null
          : Plan.fromJson((raw as Map).cast<String, dynamic>()),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        if (plan != null) 'plan': plan!.toJson(),
      };
}


// --- Contract ---

/// Internal server-to-server contract.
/// Bound to 127.0.0.1 — network isolation is the security boundary.
@RpcService(name: 'RhyoliteInternal', transferMode: RpcDataTransferMode.codec)
abstract class IInternalContract {
  @RpcMethod.unary(name: 'checkVaultOwnership')
  Future<CheckVaultOwnershipResponse> checkVaultOwnership(
    CheckVaultOwnershipRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'createVaultForUser')
  Future<CreateVaultForUserResponse> createVaultForUser(
    CreateVaultForUserRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'checkSubscription')
  Future<CheckSubscriptionResponse> checkSubscription(
    CheckSubscriptionRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'getPlan')
  Future<GetPlanResponse> getPlan(
    GetPlanRequest request, {
    RpcContext? context,
  });
}
