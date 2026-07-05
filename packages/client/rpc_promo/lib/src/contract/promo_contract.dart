import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'promo_contract.g.dart';

// ---------------------------------------------------------------------------
// Public — user-facing redeem
// ---------------------------------------------------------------------------

class RedeemPromoRequest implements IRpcSerializable {
  const RedeemPromoRequest({required this.code});

  /// The code as the user typed it. Server normalizes case-
  /// insensitively before lookup.
  final String code;

  factory RedeemPromoRequest.fromJson(Map<String, dynamic> json) =>
      RedeemPromoRequest(code: json['code'] as String);

  @override
  Map<String, dynamic> toJson() => {'code': code};
}

class RedeemPromoResponse implements IRpcSerializable {
  const RedeemPromoResponse({
    required this.planId,
    required this.periodGrantedDays,
    this.validUntil,
  });

  /// PlanId granted — clients look up capabilities via their
  /// project-specific plan catalogue.
  final String planId;

  /// Snapshot of the code's `subscriptionDays` at redeem time.
  final int periodGrantedDays;

  /// Unix timestamp (seconds) when the granted benefit ends. Reflects
  /// the full end after the project's binding stacked it on top of any
  /// pre-existing grant.
  final int? validUntil;

  factory RedeemPromoResponse.fromJson(Map<String, dynamic> json) =>
      RedeemPromoResponse(
        planId: json['plan_id'] as String,
        periodGrantedDays: (json['period_granted_days'] as num).toInt(),
        validUntil: (json['valid_until'] as num?)?.toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'plan_id': planId,
        'period_granted_days': periodGrantedDays,
        if (validUntil != null) 'valid_until': validUntil,
      };
}

// ---------------------------------------------------------------------------
// Admin — code lifecycle (gating left to caller's interceptors)
// ---------------------------------------------------------------------------

class CreatePromoCodeRequest implements IRpcSerializable {
  const CreatePromoCodeRequest({
    required this.planId,
    required this.subscriptionDays,
    this.code,
    this.maxRedemptions,
    this.expiresAtMs,
    this.campaign,
    this.description,
  });

  final String planId;
  final int subscriptionDays;

  /// Custom code string ("HABR-LAUNCH"). Null = generate random.
  final String? code;

  /// Null = unlimited.
  final int? maxRedemptions;

  /// Unix milliseconds when the code stops accepting redeems.
  final int? expiresAtMs;

  final String? campaign;
  final String? description;

  factory CreatePromoCodeRequest.fromJson(Map<String, dynamic> json) =>
      CreatePromoCodeRequest(
        planId: json['plan_id'] as String,
        subscriptionDays: (json['subscription_days'] as num).toInt(),
        code: json['code'] as String?,
        maxRedemptions: (json['max_redemptions'] as num?)?.toInt(),
        expiresAtMs: (json['expires_at_ms'] as num?)?.toInt(),
        campaign: json['campaign'] as String?,
        description: json['description'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'plan_id': planId,
        'subscription_days': subscriptionDays,
        if (code != null) 'code': code,
        if (maxRedemptions != null) 'max_redemptions': maxRedemptions,
        if (expiresAtMs != null) 'expires_at_ms': expiresAtMs,
        if (campaign != null) 'campaign': campaign,
        if (description != null) 'description': description,
      };
}

class PromoCodeRow implements IRpcSerializable {
  const PromoCodeRow({
    required this.code,
    required this.planId,
    required this.subscriptionDays,
    required this.redemptionCount,
    required this.createdAtMs,
    required this.isActive,
    this.maxRedemptions,
    this.expiresAtMs,
    this.campaign,
    this.description,
  });

  final String code;
  final String planId;
  final int subscriptionDays;
  final int? maxRedemptions;
  final int redemptionCount;
  final int? expiresAtMs;
  final String? campaign;
  final String? description;
  final int createdAtMs;
  final bool isActive;

  factory PromoCodeRow.fromJson(Map<String, dynamic> json) => PromoCodeRow(
        code: json['code'] as String,
        planId: json['plan_id'] as String,
        subscriptionDays: (json['subscription_days'] as num).toInt(),
        maxRedemptions: (json['max_redemptions'] as num?)?.toInt(),
        redemptionCount: (json['redemption_count'] as num).toInt(),
        expiresAtMs: (json['expires_at_ms'] as num?)?.toInt(),
        campaign: json['campaign'] as String?,
        description: json['description'] as String?,
        createdAtMs: (json['created_at_ms'] as num).toInt(),
        isActive: json['is_active'] as bool,
      );

  @override
  Map<String, dynamic> toJson() => {
        'code': code,
        'plan_id': planId,
        'subscription_days': subscriptionDays,
        if (maxRedemptions != null) 'max_redemptions': maxRedemptions,
        'redemption_count': redemptionCount,
        if (expiresAtMs != null) 'expires_at_ms': expiresAtMs,
        if (campaign != null) 'campaign': campaign,
        if (description != null) 'description': description,
        'created_at_ms': createdAtMs,
        'is_active': isActive,
      };
}

class CreatePromoCodeResponse implements IRpcSerializable {
  const CreatePromoCodeResponse({required this.code});

  final PromoCodeRow code;

  factory CreatePromoCodeResponse.fromJson(Map<String, dynamic> json) =>
      CreatePromoCodeResponse(
        code: PromoCodeRow.fromJson(
          (json['code'] as Map).cast<String, dynamic>(),
        ),
      );

  @override
  Map<String, dynamic> toJson() => {'code': code.toJson()};
}

class CreatePromoBatchRequest implements IRpcSerializable {
  const CreatePromoBatchRequest({
    required this.planId,
    required this.subscriptionDays,
    required this.count,
    this.prefix,
    this.expiresAtMs,
    this.campaign,
    this.description,
  });

  final String planId;
  final int subscriptionDays;
  final int count;
  final String? prefix;
  final int? expiresAtMs;
  final String? campaign;
  final String? description;

  factory CreatePromoBatchRequest.fromJson(Map<String, dynamic> json) =>
      CreatePromoBatchRequest(
        planId: json['plan_id'] as String,
        subscriptionDays: (json['subscription_days'] as num).toInt(),
        count: (json['count'] as num).toInt(),
        prefix: json['prefix'] as String?,
        expiresAtMs: (json['expires_at_ms'] as num?)?.toInt(),
        campaign: json['campaign'] as String?,
        description: json['description'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'plan_id': planId,
        'subscription_days': subscriptionDays,
        'count': count,
        if (prefix != null) 'prefix': prefix,
        if (expiresAtMs != null) 'expires_at_ms': expiresAtMs,
        if (campaign != null) 'campaign': campaign,
        if (description != null) 'description': description,
      };
}

class CreatePromoBatchResponse implements IRpcSerializable {
  const CreatePromoBatchResponse({required this.codes});

  final List<String> codes;

  factory CreatePromoBatchResponse.fromJson(Map<String, dynamic> json) =>
      CreatePromoBatchResponse(
        codes: (json['codes'] as List).cast<String>(),
      );

  @override
  Map<String, dynamic> toJson() => {'codes': codes};
}

class ListPromoCodesRequest implements IRpcSerializable {
  const ListPromoCodesRequest({
    this.campaign,
    this.activeOnly,
    this.limit = 100,
  });

  final String? campaign;
  final bool? activeOnly;
  final int limit;

  factory ListPromoCodesRequest.fromJson(Map<String, dynamic> json) =>
      ListPromoCodesRequest(
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

class ListPromoCodesResponse implements IRpcSerializable {
  const ListPromoCodesResponse({required this.codes});

  final List<PromoCodeRow> codes;

  factory ListPromoCodesResponse.fromJson(Map<String, dynamic> json) =>
      ListPromoCodesResponse(
        codes: (json['codes'] as List)
            .cast<Map>()
            .map((m) => PromoCodeRow.fromJson(m.cast<String, dynamic>()))
            .toList(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'codes': codes.map((c) => c.toJson()).toList(),
      };
}

class DeactivatePromoCodeRequest implements IRpcSerializable {
  const DeactivatePromoCodeRequest({required this.code});

  final String code;

  factory DeactivatePromoCodeRequest.fromJson(Map<String, dynamic> json) =>
      DeactivatePromoCodeRequest(code: json['code'] as String);

  @override
  Map<String, dynamic> toJson() => {'code': code};
}

class DeactivatePromoCodeResponse implements IRpcSerializable {
  const DeactivatePromoCodeResponse();

  factory DeactivatePromoCodeResponse.fromJson(Map<String, dynamic> _) =>
      const DeactivatePromoCodeResponse();

  @override
  Map<String, dynamic> toJson() => const {};
}

// ---------------------------------------------------------------------------
// Contracts
// ---------------------------------------------------------------------------

/// Public promo surface — authenticated user redeems a code.
@RpcService(name: 'Promo', transferMode: RpcDataTransferMode.codec)
abstract class IPromoContract {
  @RpcMethod.unary(name: 'redeem')
  Future<RedeemPromoResponse> redeem(
    RedeemPromoRequest request, {
    RpcContext? context,
  });
}

/// Admin promo surface — code lifecycle. Authorization (admin role
/// check) is left to the caller's interceptor chain.
@RpcService(name: 'AdminPromo', transferMode: RpcDataTransferMode.codec)
abstract class IAdminPromoContract {
  @RpcMethod.unary(name: 'createPromoCode')
  Future<CreatePromoCodeResponse> createPromoCode(
    CreatePromoCodeRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'createPromoBatch')
  Future<CreatePromoBatchResponse> createPromoBatch(
    CreatePromoBatchRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'listPromoCodes')
  Future<ListPromoCodesResponse> listPromoCodes(
    ListPromoCodesRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'deactivatePromoCode')
  Future<DeactivatePromoCodeResponse> deactivatePromoCode(
    DeactivatePromoCodeRequest request, {
    RpcContext? context,
  });
}
