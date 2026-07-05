/// A redeemable discount code — admin generates and shares, user types
/// in at checkout to lower the payment amount.
///
/// Lives in the `discount_codes` collection (flat — not vault-scoped).
/// Identity in the data layer is `code_normalized` (lower-case form);
/// the original [code] is preserved for display.
///
/// Discount semantics (xor):
///   * [discountPercent] — percentage off, in (0, 100].
///   * [discountKopecks] — fixed amount off, in kopecks. Final amount is
///     clamped to 0 — codes never make Selfwork charge a negative.
///
/// Hard caps and gating:
///   * [maxDiscountKopecks] — caps a percent discount ("20%, no more
///     than 500 ₽"). Ignored for fixed-amount codes.
///   * [minOrderKopecks] — minimum order amount the code applies to.
///   * [applicablePlanIds] — null = any plan; otherwise the code only
///     works for the listed plans.
///   * [restrictedToUserId] — null = anyone; otherwise only this user
///     can apply the code. Use this for personal/VIP codes instead of
///     `maxRedemptions = 1`.
///   * [startsAt] / [expiresAt] — Unix-seconds activation window.
///
/// Counters:
///   * [maxRedemptions] — global soft cap. Enforced best-effort; in a
///     narrow concurrent-payment race a code may go +1 past the cap.
///     The system always honours a successful payment regardless of the
///     counter, by design (money in → service out).
///   * [maxRedemptionsPerUser] — per-user dedup count. Default 1.
///   * [redemptionCount] — incremented atomically on each successful
///     payment via the audit-row insert.
class DiscountCode {
  const DiscountCode({
    required this.code,
    required this.redemptionCount,
    required this.createdBy,
    required this.createdAt,
    required this.isActive,
    required this.maxRedemptionsPerUser,
    this.discountPercent,
    this.discountKopecks,
    this.maxDiscountKopecks,
    this.minOrderKopecks,
    this.applicablePlanIds,
    this.restrictedToUserId,
    this.maxRedemptions,
    this.startsAt,
    this.expiresAt,
    this.campaign,
    this.description,
  });

  /// The exact string the user types in. Preserved case-sensitive for
  /// display ("BLACK-FRIDAY"); compared case-insensitively at lookup
  /// time via the `code_normalized` payload key.
  final String code;

  /// Percent off in (0, 100]. Mutually exclusive with [discountKopecks].
  final int? discountPercent;

  /// Fixed kopecks off. Mutually exclusive with [discountPercent]. Clamped
  /// to the order total at apply time — never produces a negative price.
  final int? discountKopecks;

  /// Cap on percent discount in kopecks. Only meaningful when
  /// [discountPercent] is set. Null = no cap.
  final int? maxDiscountKopecks;

  /// Minimum order amount (in kopecks) for the code to apply. Null = no
  /// minimum.
  final int? minOrderKopecks;

  /// Null = code applies to any plan. Non-null = code applies only when
  /// the buyer's planId is in this list.
  final List<String>? applicablePlanIds;

  /// Null = anyone can redeem. Non-null = only the matching userId can
  /// redeem. Used for personal codes (one influencer, one corp client).
  final String? restrictedToUserId;

  /// Null = unlimited redemptions until [expiresAt] / deactivation.
  /// Soft cap — see class docs.
  final int? maxRedemptions;

  /// How many times a single user can redeem this code across separate
  /// payments. Default 1.
  final int maxRedemptionsPerUser;

  /// How many successful payments have applied this code.
  final int redemptionCount;

  /// Unix-seconds activation start. Null = active immediately.
  final int? startsAt;

  /// Unix-seconds expiry. Null = never expires.
  final int? expiresAt;

  /// Free-form campaign tag for reporting ("black-friday-2026").
  final String? campaign;

  /// Free-form admin note.
  final String? description;

  /// `users.id` of the admin who generated the code.
  final String createdBy;

  /// Unix-seconds creation timestamp.
  final int createdAt;

  /// Soft-disable flag. Set to false to retire without losing audit
  /// history.
  final bool isActive;

  DiscountCode copyWith({
    int? redemptionCount,
    bool? isActive,
  }) =>
      DiscountCode(
        code: code,
        discountPercent: discountPercent,
        discountKopecks: discountKopecks,
        maxDiscountKopecks: maxDiscountKopecks,
        minOrderKopecks: minOrderKopecks,
        applicablePlanIds: applicablePlanIds,
        restrictedToUserId: restrictedToUserId,
        maxRedemptions: maxRedemptions,
        maxRedemptionsPerUser: maxRedemptionsPerUser,
        redemptionCount: redemptionCount ?? this.redemptionCount,
        startsAt: startsAt,
        expiresAt: expiresAt,
        campaign: campaign,
        description: description,
        createdBy: createdBy,
        createdAt: createdAt,
        isActive: isActive ?? this.isActive,
      );

  Map<String, dynamic> toPayload() => {
        'code': code,
        'code_normalized': code.toLowerCase(),
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
        if (startsAt != null) 'starts_at': startsAt,
        if (expiresAt != null) 'expires_at': expiresAt,
        if (campaign != null) 'campaign': campaign,
        if (description != null) 'description': description,
        'created_by': createdBy,
        'created_at': createdAt,
        'is_active': isActive,
      };

  factory DiscountCode.fromPayload(Map<String, Object?> payload) => DiscountCode(
        code: payload['code'] as String,
        discountPercent: (payload['discount_percent'] as num?)?.toInt(),
        discountKopecks: (payload['discount_kopecks'] as num?)?.toInt(),
        maxDiscountKopecks:
            (payload['max_discount_kopecks'] as num?)?.toInt(),
        minOrderKopecks: (payload['min_order_kopecks'] as num?)?.toInt(),
        applicablePlanIds: (payload['applicable_plan_ids'] as List?)
            ?.cast<String>(),
        restrictedToUserId: payload['restricted_to_user_id'] as String?,
        maxRedemptions: (payload['max_redemptions'] as num?)?.toInt(),
        maxRedemptionsPerUser:
            (payload['max_redemptions_per_user'] as num?)?.toInt() ?? 1,
        redemptionCount: (payload['redemption_count'] as num).toInt(),
        startsAt: (payload['starts_at'] as num?)?.toInt(),
        expiresAt: (payload['expires_at'] as num?)?.toInt(),
        campaign: payload['campaign'] as String?,
        description: payload['description'] as String?,
        createdBy: payload['created_by'] as String,
        createdAt: (payload['created_at'] as num).toInt(),
        isActive: payload['is_active'] as bool? ?? true,
      );
}
