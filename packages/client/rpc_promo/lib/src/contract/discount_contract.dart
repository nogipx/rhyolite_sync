import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'discount_contract.g.dart';

// ---------------------------------------------------------------------------
// Public — preview discount price
// ---------------------------------------------------------------------------

class PreviewDiscountRequest implements IRpcSerializable {
  const PreviewDiscountRequest({
    required this.code,
    required this.planId,
    required this.originalKopecks,
  });

  /// The code as the user typed it. Server normalizes case-
  /// insensitively before lookup.
  final String code;

  /// Plan the buyer intends to purchase. Validated against the code's
  /// `applicablePlanIds`.
  final String planId;

  /// Order amount before discount, in kopecks. Validated against the
  /// code's `minOrderKopecks` and used to compute the application.
  final int originalKopecks;

  factory PreviewDiscountRequest.fromJson(Map<String, dynamic> json) =>
      PreviewDiscountRequest(
        code: json['code'] as String,
        planId: json['plan_id'] as String,
        originalKopecks: (json['original_kopecks'] as num).toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'code': code,
        'plan_id': planId,
        'original_kopecks': originalKopecks,
      };
}

class PreviewDiscountResponse implements IRpcSerializable {
  const PreviewDiscountResponse({
    this.application,
    this.errorReason,
  });

  /// Present when the code is valid for this user/plan/amount. Null on
  /// validation failure.
  final DiscountApplicationDto? application;

  /// Machine-readable reason when [application] is null. One of:
  /// `not_found`, `code_inactive`, `code_not_started`, `code_expired`,
  /// `code_exhausted`, `wrong_plan`, `wrong_user`, `order_too_small`,
  /// `user_limit_reached`.
  final String? errorReason;

  factory PreviewDiscountResponse.fromJson(Map<String, dynamic> json) =>
      PreviewDiscountResponse(
        application: json['application'] == null
            ? null
            : DiscountApplicationDto.fromJson(
                (json['application'] as Map).cast<String, dynamic>(),
              ),
        errorReason: json['error_reason'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        if (application != null) 'application': application!.toJson(),
        if (errorReason != null) 'error_reason': errorReason,
      };
}

class DiscountApplicationDto implements IRpcSerializable {
  const DiscountApplicationDto({
    required this.code,
    required this.originalKopecks,
    required this.discountKopecks,
    required this.finalKopecks,
  });

  final String code;
  final int originalKopecks;
  final int discountKopecks;
  final int finalKopecks;

  factory DiscountApplicationDto.fromJson(Map<String, dynamic> json) =>
      DiscountApplicationDto(
        code: json['code'] as String,
        originalKopecks: (json['original_kopecks'] as num).toInt(),
        discountKopecks: (json['discount_kopecks'] as num).toInt(),
        finalKopecks: (json['final_kopecks'] as num).toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'code': code,
        'original_kopecks': originalKopecks,
        'discount_kopecks': discountKopecks,
        'final_kopecks': finalKopecks,
      };
}

// ---------------------------------------------------------------------------
// Admin — code lifecycle (gating left to caller's interceptors)
// ---------------------------------------------------------------------------

class CreateDiscountCodeRequest implements IRpcSerializable {
  const CreateDiscountCodeRequest({
    this.code,
    this.discountPercent,
    this.discountKopecks,
    this.maxDiscountKopecks,
    this.minOrderKopecks,
    this.applicablePlanIds,
    this.restrictedToUserId,
    this.maxRedemptions,
    this.maxRedemptionsPerUser,
    this.startsAtMs,
    this.expiresAtMs,
    this.campaign,
    this.description,
  });

  /// Custom code string ("BLACK-FRIDAY"). Null = generate random.
  final String? code;

  /// Percent off in (0, 100]. Exactly one of [discountPercent] /
  /// [discountKopecks] must be set.
  final int? discountPercent;

  /// Fixed kopecks off. Exactly one of [discountPercent] /
  /// [discountKopecks] must be set.
  final int? discountKopecks;

  /// Cap on percent discount. Only meaningful with [discountPercent].
  final int? maxDiscountKopecks;

  /// Minimum order amount to allow the code, in kopecks.
  final int? minOrderKopecks;

  /// Null = applies to any plan; non-null = restricted to listed plans.
  final List<String>? applicablePlanIds;

  /// Personal-code lock — only this user can apply the code.
  final String? restrictedToUserId;

  /// Global soft cap on redemptions. Null = unlimited.
  final int? maxRedemptions;

  /// Per-user redemption count. Defaults to 1 server-side when null.
  final int? maxRedemptionsPerUser;

  /// Unix-ms activation start. Null = active immediately.
  final int? startsAtMs;

  /// Unix-ms expiry. Null = never expires.
  final int? expiresAtMs;

  final String? campaign;
  final String? description;

  factory CreateDiscountCodeRequest.fromJson(Map<String, dynamic> json) =>
      CreateDiscountCodeRequest(
        code: json['code'] as String?,
        discountPercent: (json['discount_percent'] as num?)?.toInt(),
        discountKopecks: (json['discount_kopecks'] as num?)?.toInt(),
        maxDiscountKopecks:
            (json['max_discount_kopecks'] as num?)?.toInt(),
        minOrderKopecks: (json['min_order_kopecks'] as num?)?.toInt(),
        applicablePlanIds:
            (json['applicable_plan_ids'] as List?)?.cast<String>(),
        restrictedToUserId: json['restricted_to_user_id'] as String?,
        maxRedemptions: (json['max_redemptions'] as num?)?.toInt(),
        maxRedemptionsPerUser:
            (json['max_redemptions_per_user'] as num?)?.toInt(),
        startsAtMs: (json['starts_at_ms'] as num?)?.toInt(),
        expiresAtMs: (json['expires_at_ms'] as num?)?.toInt(),
        campaign: json['campaign'] as String?,
        description: json['description'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        if (code != null) 'code': code,
        if (discountPercent != null) 'discount_percent': discountPercent,
        if (discountKopecks != null) 'discount_kopecks': discountKopecks,
        if (maxDiscountKopecks != null)
          'max_discount_kopecks': maxDiscountKopecks,
        if (minOrderKopecks != null) 'min_order_kopecks': minOrderKopecks,
        if (applicablePlanIds != null)
          'applicable_plan_ids': applicablePlanIds,
        if (restrictedToUserId != null)
          'restricted_to_user_id': restrictedToUserId,
        if (maxRedemptions != null) 'max_redemptions': maxRedemptions,
        if (maxRedemptionsPerUser != null)
          'max_redemptions_per_user': maxRedemptionsPerUser,
        if (startsAtMs != null) 'starts_at_ms': startsAtMs,
        if (expiresAtMs != null) 'expires_at_ms': expiresAtMs,
        if (campaign != null) 'campaign': campaign,
        if (description != null) 'description': description,
      };
}

class DiscountCodeRow implements IRpcSerializable {
  const DiscountCodeRow({
    required this.code,
    required this.redemptionCount,
    required this.maxRedemptionsPerUser,
    required this.createdAtMs,
    required this.isActive,
    this.discountPercent,
    this.discountKopecks,
    this.maxDiscountKopecks,
    this.minOrderKopecks,
    this.applicablePlanIds,
    this.restrictedToUserId,
    this.maxRedemptions,
    this.startsAtMs,
    this.expiresAtMs,
    this.campaign,
    this.description,
  });

  final String code;
  final int? discountPercent;
  final int? discountKopecks;
  final int? maxDiscountKopecks;
  final int? minOrderKopecks;
  final List<String>? applicablePlanIds;
  final String? restrictedToUserId;
  final int? maxRedemptions;
  final int maxRedemptionsPerUser;
  final int redemptionCount;
  final int? startsAtMs;
  final int? expiresAtMs;
  final String? campaign;
  final String? description;
  final int createdAtMs;
  final bool isActive;

  factory DiscountCodeRow.fromJson(Map<String, dynamic> json) => DiscountCodeRow(
        code: json['code'] as String,
        discountPercent: (json['discount_percent'] as num?)?.toInt(),
        discountKopecks: (json['discount_kopecks'] as num?)?.toInt(),
        maxDiscountKopecks: (json['max_discount_kopecks'] as num?)?.toInt(),
        minOrderKopecks: (json['min_order_kopecks'] as num?)?.toInt(),
        applicablePlanIds:
            (json['applicable_plan_ids'] as List?)?.cast<String>(),
        restrictedToUserId: json['restricted_to_user_id'] as String?,
        maxRedemptions: (json['max_redemptions'] as num?)?.toInt(),
        maxRedemptionsPerUser:
            (json['max_redemptions_per_user'] as num).toInt(),
        redemptionCount: (json['redemption_count'] as num).toInt(),
        startsAtMs: (json['starts_at_ms'] as num?)?.toInt(),
        expiresAtMs: (json['expires_at_ms'] as num?)?.toInt(),
        campaign: json['campaign'] as String?,
        description: json['description'] as String?,
        createdAtMs: (json['created_at_ms'] as num).toInt(),
        isActive: json['is_active'] as bool,
      );

  @override
  Map<String, dynamic> toJson() => {
        'code': code,
        if (discountPercent != null) 'discount_percent': discountPercent,
        if (discountKopecks != null) 'discount_kopecks': discountKopecks,
        if (maxDiscountKopecks != null)
          'max_discount_kopecks': maxDiscountKopecks,
        if (minOrderKopecks != null) 'min_order_kopecks': minOrderKopecks,
        if (applicablePlanIds != null)
          'applicable_plan_ids': applicablePlanIds,
        if (restrictedToUserId != null)
          'restricted_to_user_id': restrictedToUserId,
        if (maxRedemptions != null) 'max_redemptions': maxRedemptions,
        'max_redemptions_per_user': maxRedemptionsPerUser,
        'redemption_count': redemptionCount,
        if (startsAtMs != null) 'starts_at_ms': startsAtMs,
        if (expiresAtMs != null) 'expires_at_ms': expiresAtMs,
        if (campaign != null) 'campaign': campaign,
        if (description != null) 'description': description,
        'created_at_ms': createdAtMs,
        'is_active': isActive,
      };
}

class CreateDiscountCodeResponse implements IRpcSerializable {
  const CreateDiscountCodeResponse({required this.code});

  final DiscountCodeRow code;

  factory CreateDiscountCodeResponse.fromJson(Map<String, dynamic> json) =>
      CreateDiscountCodeResponse(
        code: DiscountCodeRow.fromJson(
          (json['code'] as Map).cast<String, dynamic>(),
        ),
      );

  @override
  Map<String, dynamic> toJson() => {'code': code.toJson()};
}

class CreateDiscountBatchRequest implements IRpcSerializable {
  const CreateDiscountBatchRequest({
    required this.count,
    this.discountPercent,
    this.discountKopecks,
    this.maxDiscountKopecks,
    this.minOrderKopecks,
    this.applicablePlanIds,
    this.maxRedemptionsPerUser,
    this.prefix,
    this.startsAtMs,
    this.expiresAtMs,
    this.campaign,
    this.description,
  });

  final int count;
  final int? discountPercent;
  final int? discountKopecks;
  final int? maxDiscountKopecks;
  final int? minOrderKopecks;
  final List<String>? applicablePlanIds;
  final int? maxRedemptionsPerUser;
  final String? prefix;
  final int? startsAtMs;
  final int? expiresAtMs;
  final String? campaign;
  final String? description;

  factory CreateDiscountBatchRequest.fromJson(Map<String, dynamic> json) =>
      CreateDiscountBatchRequest(
        count: (json['count'] as num).toInt(),
        discountPercent: (json['discount_percent'] as num?)?.toInt(),
        discountKopecks: (json['discount_kopecks'] as num?)?.toInt(),
        maxDiscountKopecks: (json['max_discount_kopecks'] as num?)?.toInt(),
        minOrderKopecks: (json['min_order_kopecks'] as num?)?.toInt(),
        applicablePlanIds:
            (json['applicable_plan_ids'] as List?)?.cast<String>(),
        maxRedemptionsPerUser:
            (json['max_redemptions_per_user'] as num?)?.toInt(),
        prefix: json['prefix'] as String?,
        startsAtMs: (json['starts_at_ms'] as num?)?.toInt(),
        expiresAtMs: (json['expires_at_ms'] as num?)?.toInt(),
        campaign: json['campaign'] as String?,
        description: json['description'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'count': count,
        if (discountPercent != null) 'discount_percent': discountPercent,
        if (discountKopecks != null) 'discount_kopecks': discountKopecks,
        if (maxDiscountKopecks != null)
          'max_discount_kopecks': maxDiscountKopecks,
        if (minOrderKopecks != null) 'min_order_kopecks': minOrderKopecks,
        if (applicablePlanIds != null)
          'applicable_plan_ids': applicablePlanIds,
        if (maxRedemptionsPerUser != null)
          'max_redemptions_per_user': maxRedemptionsPerUser,
        if (prefix != null) 'prefix': prefix,
        if (startsAtMs != null) 'starts_at_ms': startsAtMs,
        if (expiresAtMs != null) 'expires_at_ms': expiresAtMs,
        if (campaign != null) 'campaign': campaign,
        if (description != null) 'description': description,
      };
}

class CreateDiscountBatchResponse implements IRpcSerializable {
  const CreateDiscountBatchResponse({required this.codes});

  final List<String> codes;

  factory CreateDiscountBatchResponse.fromJson(Map<String, dynamic> json) =>
      CreateDiscountBatchResponse(
        codes: (json['codes'] as List).cast<String>(),
      );

  @override
  Map<String, dynamic> toJson() => {'codes': codes};
}

class ListDiscountCodesRequest implements IRpcSerializable {
  const ListDiscountCodesRequest({
    this.campaign,
    this.activeOnly,
    this.limit = 100,
  });

  final String? campaign;
  final bool? activeOnly;
  final int limit;

  factory ListDiscountCodesRequest.fromJson(Map<String, dynamic> json) =>
      ListDiscountCodesRequest(
        campaign: json['campaign'] as String?,
        activeOnly: json['active_only'] as bool?,
        limit: (json['limit'] as num?)?.toInt() ?? 100,
      );

  @override
  Map<String, dynamic> toJson() => {
        if (campaign != null) 'campaign': campaign,
        if (activeOnly != null) 'active_only': activeOnly,
        'limit': limit,
      };
}

class ListDiscountCodesResponse implements IRpcSerializable {
  const ListDiscountCodesResponse({required this.codes});

  final List<DiscountCodeRow> codes;

  factory ListDiscountCodesResponse.fromJson(Map<String, dynamic> json) =>
      ListDiscountCodesResponse(
        codes: (json['codes'] as List)
            .cast<Map>()
            .map((m) => DiscountCodeRow.fromJson(m.cast<String, dynamic>()))
            .toList(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'codes': codes.map((c) => c.toJson()).toList(),
      };
}

class DeactivateDiscountCodeRequest implements IRpcSerializable {
  const DeactivateDiscountCodeRequest({required this.code});

  final String code;

  factory DeactivateDiscountCodeRequest.fromJson(Map<String, dynamic> json) =>
      DeactivateDiscountCodeRequest(code: json['code'] as String);

  @override
  Map<String, dynamic> toJson() => {'code': code};
}

class DeactivateDiscountCodeResponse implements IRpcSerializable {
  const DeactivateDiscountCodeResponse();

  factory DeactivateDiscountCodeResponse.fromJson(Map<String, dynamic> _) =>
      const DeactivateDiscountCodeResponse();

  @override
  Map<String, dynamic> toJson() => const {};
}

// ---------------------------------------------------------------------------
// Contracts
// ---------------------------------------------------------------------------

/// Public discount surface — authenticated user previews a code's effect
/// on their pending payment. The code is only "consumed" (counter
/// incremented, audit row written) when the project's payment flow
/// confirms a successful payment, not at preview time.
@RpcService(name: 'Discount', transferMode: RpcDataTransferMode.codec)
abstract class IDiscountContract {
  @RpcMethod.unary(name: 'preview')
  Future<PreviewDiscountResponse> preview(
    PreviewDiscountRequest request, {
    RpcContext? context,
  });
}

/// Admin discount surface — code lifecycle. Authorization (admin role
/// check) is left to the caller's interceptor chain.
@RpcService(name: 'AdminDiscount', transferMode: RpcDataTransferMode.codec)
abstract class IAdminDiscountContract {
  @RpcMethod.unary(name: 'createDiscountCode')
  Future<CreateDiscountCodeResponse> createDiscountCode(
    CreateDiscountCodeRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'createDiscountBatch')
  Future<CreateDiscountBatchResponse> createDiscountBatch(
    CreateDiscountBatchRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'listDiscountCodes')
  Future<ListDiscountCodesResponse> listDiscountCodes(
    ListDiscountCodesRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'deactivateDiscountCode')
  Future<DeactivateDiscountCodeResponse> deactivateDiscountCode(
    DeactivateDiscountCodeRequest request, {
    RpcContext? context,
  });
}
