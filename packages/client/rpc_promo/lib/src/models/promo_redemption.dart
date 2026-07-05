/// Append-only audit row — one per successful promo redemption.
///
/// Stored in the `promo_redemptions` collection. Identity is the
/// composite `(code_normalized, user_id)`; the same user cannot
/// redeem the same code twice, enforced by repository lookup before
/// insert.
///
/// Snapshots the granted duration ([periodGrantedDays]) so audit can
/// answer "what did this user get?" even after the promo code is
/// edited or deactivated later.
class PromoRedemption {
  const PromoRedemption({
    required this.code,
    required this.userId,
    required this.redeemedAt,
    required this.periodGrantedDays,
    required this.grantedPlanId,
    this.validUntil,
    this.bindingEntityId,
  });

  /// Original code string as it was at redeem time (preserved case-
  /// sensitive for display). Lookup uses `code_normalized` payload key.
  final String code;

  /// `users.id` of the redeemer.
  final String userId;

  /// Unix timestamp (seconds) when redeem succeeded.
  final int redeemedAt;

  /// Snapshot of [PromoCode.subscriptionDays] at redeem time. Promo
  /// code may be edited / deactivated later — this row preserves what
  /// the user actually got.
  final int periodGrantedDays;

  /// Snapshot of [PromoCode.planId] at redeem time. Same rationale as
  /// [periodGrantedDays].
  final String grantedPlanId;

  /// Unix timestamp (seconds) when the granted access expires —
  /// populated from the binding's [RedeemOutcome.validUntil]. Null when
  /// the binding doesn't expose an expiry (e.g. one-shot grants).
  final int? validUntil;

  /// Project-specific id the binding returned — for Rhyolite this can
  /// stay null because subscriptions live in their own table indexed
  /// by user_id; for other consumers it might be a license id, a
  /// voucher row id, etc.
  final String? bindingEntityId;

  Map<String, dynamic> toPayload() => {
        'code': code,
        'code_normalized': code.toLowerCase(),
        'user_id': userId,
        'redeemed_at': redeemedAt,
        'period_granted_days': periodGrantedDays,
        'granted_plan_id': grantedPlanId,
        if (validUntil != null) 'valid_until': validUntil,
        if (bindingEntityId != null) 'binding_entity_id': bindingEntityId,
      };

  factory PromoRedemption.fromPayload(Map<String, Object?> payload) =>
      PromoRedemption(
        code: payload['code'] as String,
        userId: payload['user_id'] as String,
        redeemedAt: (payload['redeemed_at'] as num).toInt(),
        periodGrantedDays: (payload['period_granted_days'] as num).toInt(),
        grantedPlanId: payload['granted_plan_id'] as String,
        validUntil: (payload['valid_until'] as num?)?.toInt(),
        bindingEntityId: payload['binding_entity_id'] as String?,
      );
}
