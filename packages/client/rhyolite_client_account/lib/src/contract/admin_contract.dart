import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'admin_contract.g.dart';

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

/// One user row as seen by an admin. Includes role + active subscription
/// metadata that the public auth contract doesn't expose.
class AdminUserRow implements IRpcSerializable {
  const AdminUserRow({
    required this.userId,
    required this.email,
    required this.role,
    required this.emailVerified,
    required this.createdAtMs,
    this.activePlanId,
    this.activeSubEndsAtMs,
  });

  final String userId;
  final String email;
  final String role;
  final bool emailVerified;
  final int createdAtMs;

  /// Plan id of the currently active subscription, or null if no
  /// active subscription.
  final String? activePlanId;

  /// `current_period_end` of the active subscription (Unix seconds × 1000).
  final int? activeSubEndsAtMs;

  factory AdminUserRow.fromJson(Map<String, dynamic> json) => AdminUserRow(
        userId: json['userId'] as String,
        email: json['email'] as String,
        role: json['role'] as String,
        emailVerified: json['emailVerified'] as bool,
        createdAtMs: (json['createdAtMs'] as num).toInt(),
        activePlanId: json['activePlanId'] as String?,
        activeSubEndsAtMs: (json['activeSubEndsAtMs'] as num?)?.toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'userId': userId,
        'email': email,
        'role': role,
        'emailVerified': emailVerified,
        'createdAtMs': createdAtMs,
        if (activePlanId != null) 'activePlanId': activePlanId,
        if (activeSubEndsAtMs != null) 'activeSubEndsAtMs': activeSubEndsAtMs,
      };
}

class ListUsersRequest implements IRpcSerializable {
  const ListUsersRequest({this.emailQuery, this.limit = 50, this.offset = 0});

  /// Substring search on the email field (case-insensitive on the
  /// server). Null returns all users.
  final String? emailQuery;
  final int limit;
  final int offset;

  factory ListUsersRequest.fromJson(Map<String, dynamic> json) =>
      ListUsersRequest(
        emailQuery: json['emailQuery'] as String?,
        limit: (json['limit'] as num?)?.toInt() ?? 50,
        offset: (json['offset'] as num?)?.toInt() ?? 0,
      );

  @override
  Map<String, dynamic> toJson() => {
        if (emailQuery != null) 'emailQuery': emailQuery,
        'limit': limit,
        'offset': offset,
      };
}

class ListUsersResponse implements IRpcSerializable {
  const ListUsersResponse({required this.users, required this.totalCount});

  final List<AdminUserRow> users;
  final int totalCount;

  factory ListUsersResponse.fromJson(Map<String, dynamic> json) =>
      ListUsersResponse(
        users: (json['users'] as List)
            .map((e) => AdminUserRow.fromJson(
                  (e as Map).cast<String, dynamic>(),
                ))
            .toList(),
        totalCount: (json['totalCount'] as num).toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'users': users.map((u) => u.toJson()).toList(),
        'totalCount': totalCount,
      };
}

class GetUserRequest implements IRpcSerializable {
  const GetUserRequest({this.userId, this.email})
      : assert(userId != null || email != null,
            'Either userId or email must be provided');

  final String? userId;
  final String? email;

  factory GetUserRequest.fromJson(Map<String, dynamic> json) => GetUserRequest(
        userId: json['userId'] as String?,
        email: json['email'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        if (userId != null) 'userId': userId,
        if (email != null) 'email': email,
      };
}

class AdminSubscription implements IRpcSerializable {
  const AdminSubscription({
    required this.subscriptionId,
    required this.planId,
    required this.status,
    required this.currentPeriodEndMs,
    this.source,
  });

  final String subscriptionId;
  final String planId;
  final String status;
  final int currentPeriodEndMs;
  final String? source;

  factory AdminSubscription.fromJson(Map<String, dynamic> json) =>
      AdminSubscription(
        subscriptionId: json['subscriptionId'] as String,
        planId: json['planId'] as String,
        status: json['status'] as String,
        currentPeriodEndMs: (json['currentPeriodEndMs'] as num).toInt(),
        source: json['source'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'subscriptionId': subscriptionId,
        'planId': planId,
        'status': status,
        'currentPeriodEndMs': currentPeriodEndMs,
        if (source != null) 'source': source,
      };
}

class GetUserResponse implements IRpcSerializable {
  const GetUserResponse({
    required this.user,
    required this.subscriptions,
    required this.vaultCount,
  });

  final AdminUserRow user;
  final List<AdminSubscription> subscriptions;
  final int vaultCount;

  factory GetUserResponse.fromJson(Map<String, dynamic> json) => GetUserResponse(
        user: AdminUserRow.fromJson(
          (json['user'] as Map).cast<String, dynamic>(),
        ),
        subscriptions: (json['subscriptions'] as List)
            .map((e) => AdminSubscription.fromJson(
                  (e as Map).cast<String, dynamic>(),
                ))
            .toList(),
        vaultCount: (json['vaultCount'] as num).toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'user': user.toJson(),
        'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
        'vaultCount': vaultCount,
      };
}

class GrantSubscriptionRequest implements IRpcSerializable {
  const GrantSubscriptionRequest({
    required this.userId,
    required this.planId,
    this.days,
    this.reason,
  });

  final String userId;
  final String planId;

  /// Override the plan's default periodDays. Null uses the plan's
  /// configured period.
  final int? days;

  /// Free-form note for audit (saved to `source` field).
  final String? reason;

  factory GrantSubscriptionRequest.fromJson(Map<String, dynamic> json) =>
      GrantSubscriptionRequest(
        userId: json['userId'] as String,
        planId: json['planId'] as String,
        days: (json['days'] as num?)?.toInt(),
        reason: json['reason'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'userId': userId,
        'planId': planId,
        if (days != null) 'days': days,
        if (reason != null) 'reason': reason,
      };
}

class GrantSubscriptionResponse implements IRpcSerializable {
  const GrantSubscriptionResponse({
    required this.subscriptionId,
    required this.currentPeriodEndMs,
  });

  final String subscriptionId;
  final int currentPeriodEndMs;

  factory GrantSubscriptionResponse.fromJson(Map<String, dynamic> json) =>
      GrantSubscriptionResponse(
        subscriptionId: json['subscriptionId'] as String,
        currentPeriodEndMs: (json['currentPeriodEndMs'] as num).toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'subscriptionId': subscriptionId,
        'currentPeriodEndMs': currentPeriodEndMs,
      };
}

class RevokeSubscriptionRequest implements IRpcSerializable {
  const RevokeSubscriptionRequest({required this.subscriptionId});

  final String subscriptionId;

  factory RevokeSubscriptionRequest.fromJson(Map<String, dynamic> json) =>
      RevokeSubscriptionRequest(
        subscriptionId: json['subscriptionId'] as String,
      );

  @override
  Map<String, dynamic> toJson() => {'subscriptionId': subscriptionId};
}

class RevokeSubscriptionResponse implements IRpcSerializable {
  const RevokeSubscriptionResponse({required this.revoked});

  final bool revoked;

  factory RevokeSubscriptionResponse.fromJson(Map<String, dynamic> json) =>
      RevokeSubscriptionResponse(revoked: json['revoked'] as bool);

  @override
  Map<String, dynamic> toJson() => {'revoked': revoked};
}

class ChangeUserRoleRequest implements IRpcSerializable {
  const ChangeUserRoleRequest({
    required this.targetUserId,
    required this.newRole,
  });

  final String targetUserId;
  final String newRole;

  factory ChangeUserRoleRequest.fromJson(Map<String, dynamic> json) =>
      ChangeUserRoleRequest(
        targetUserId: json['targetUserId'] as String,
        newRole: json['newRole'] as String,
      );

  @override
  Map<String, dynamic> toJson() => {
        'targetUserId': targetUserId,
        'newRole': newRole,
      };
}

class ChangeUserRoleResponse implements IRpcSerializable {
  const ChangeUserRoleResponse({required this.previousRole});

  final String previousRole;

  factory ChangeUserRoleResponse.fromJson(Map<String, dynamic> json) =>
      ChangeUserRoleResponse(previousRole: json['previousRole'] as String);

  @override
  Map<String, dynamic> toJson() => {'previousRole': previousRole};
}

// ---------------------------------------------------------------------------
// Contract
// ---------------------------------------------------------------------------

/// Admin-only RPC surface. Mounted on the same public HTTP endpoint
/// as the user-facing auth/vault/subscription contracts, gated by
/// [AdminRoleInterceptor] which checks `users.role == 'admin'`.
@RpcService(name: 'RhyoliteAdmin', transferMode: RpcDataTransferMode.codec)
abstract class IAdminContract {
  @RpcMethod.unary(name: 'listUsers')
  Future<ListUsersResponse> listUsers(
    ListUsersRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'getUser')
  Future<GetUserResponse> getUser(
    GetUserRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'grantSubscription')
  Future<GrantSubscriptionResponse> grantSubscription(
    GrantSubscriptionRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'revokeSubscription')
  Future<RevokeSubscriptionResponse> revokeSubscription(
    RevokeSubscriptionRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'changeUserRole')
  Future<ChangeUserRoleResponse> changeUserRole(
    ChangeUserRoleRequest request, {
    RpcContext? context,
  });
}
