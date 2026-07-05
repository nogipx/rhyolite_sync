/// A redeemable promo code — the entity admin generates and shares.
///
/// Lives in the `promo_codes` collection (flat — not vault-scoped, because
/// codes belong to the service and any user can redeem). Identity in the
/// data layer is `code_normalized` (lowercase form); the original
/// [code] is preserved for display.
///
/// Capabilities (managed-storage / vault count / etc.) come from the
/// referenced [planId] — promo codes do NOT redefine capabilities, only
/// the *duration* and *limits* of access. This keeps the plan catalogue
/// as the single source of truth for what's possible at each tier.
class PromoCode {
  const PromoCode({
    required this.code,
    required this.planId,
    required this.subscriptionDays,
    required this.redemptionCount,
    required this.createdBy,
    required this.createdAt,
    required this.isActive,
    this.maxRedemptions,
    this.expiresAt,
    this.campaign,
    this.description,
  });

  /// The exact string the user types in. Preserved case-sensitive for
  /// display ("HABR-rxXM"); compared case-insensitively at redeem time
  /// via the `code_normalized` payload key.
  final String code;

  /// PlanId from the server's plan catalogue. Determines what the
  /// redeemer gets to do (managed storage / external storage / file
  /// size cap / etc.) — promo code only chooses WHICH plan, never
  /// modifies it.
  final String planId;

  /// How many days the granted subscription is valid for. Independent
  /// of the plan's natural `periodDays` so a single plan can be given
  /// out in 3-day, 30-day, or 365-day flavours by different campaigns.
  final int subscriptionDays;

  /// Null = unlimited redemptions until [expiresAt] / deactivation.
  /// Otherwise the code stops accepting redeems once
  /// [redemptionCount] reaches this value.
  final int? maxRedemptions;

  /// How many times the code has been successfully redeemed so far.
  /// Incremented atomically with the redemption row insert.
  final int redemptionCount;

  /// Unix timestamp (seconds) past which the code is invalid regardless
  /// of remaining redemptions. Null = never expires.
  final int? expiresAt;

  /// Free-form tag used to group codes for reporting ("habr-2026-06",
  /// "tg-subscribers"). Indexed in the repository for `list({campaign:})`
  /// queries.
  final String? campaign;

  /// Free-form note for the admin ("Habr launch giveaway").
  final String? description;

  /// `users.id` of the admin who generated the code. Useful for audit.
  final String createdBy;

  /// Unix timestamp (seconds) when the code was generated.
  final int createdAt;

  /// Soft-disable flag. Set to false to retire a code without losing
  /// the redemption history attached to it.
  final bool isActive;

  PromoCode copyWith({
    int? redemptionCount,
    bool? isActive,
  }) => PromoCode(
        code: code,
        planId: planId,
        subscriptionDays: subscriptionDays,
        maxRedemptions: maxRedemptions,
        redemptionCount: redemptionCount ?? this.redemptionCount,
        expiresAt: expiresAt,
        campaign: campaign,
        description: description,
        createdBy: createdBy,
        createdAt: createdAt,
        isActive: isActive ?? this.isActive,
      );

  /// True when the code is in a redeemable state right now. Caller
  /// should still check per-user dedup separately via the repository.
  bool isRedeemableAt(int nowSeconds) {
    if (!isActive) return false;
    if (expiresAt != null && nowSeconds >= expiresAt!) return false;
    if (maxRedemptions != null && redemptionCount >= maxRedemptions!) {
      return false;
    }
    return true;
  }

  Map<String, dynamic> toPayload() => {
        'code': code,
        'code_normalized': code.toLowerCase(),
        'plan_id': planId,
        'subscription_days': subscriptionDays,
        if (maxRedemptions != null) 'max_redemptions': maxRedemptions,
        'redemption_count': redemptionCount,
        if (expiresAt != null) 'expires_at': expiresAt,
        if (campaign != null) 'campaign': campaign,
        if (description != null) 'description': description,
        'created_by': createdBy,
        'created_at': createdAt,
        'is_active': isActive,
      };

  factory PromoCode.fromPayload(Map<String, Object?> payload) => PromoCode(
        code: payload['code'] as String,
        planId: payload['plan_id'] as String,
        subscriptionDays: (payload['subscription_days'] as num).toInt(),
        maxRedemptions: (payload['max_redemptions'] as num?)?.toInt(),
        redemptionCount: (payload['redemption_count'] as num).toInt(),
        expiresAt: (payload['expires_at'] as num?)?.toInt(),
        campaign: payload['campaign'] as String?,
        description: payload['description'] as String?,
        createdBy: payload['created_by'] as String,
        createdAt: (payload['created_at'] as num).toInt(),
        isActive: payload['is_active'] as bool? ?? true,
      );
}
