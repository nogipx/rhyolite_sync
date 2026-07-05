/// Append-only audit row — one per successful payment that applied a
/// discount code.
///
/// Stored in the `discount_redemptions` collection. Per-user dedup is
/// enforced by counting rows where `(code_normalized, user_id)` match,
/// against [DiscountCode.maxRedemptionsPerUser].
///
/// Snapshots the actual amounts at consume time so audit can answer
/// "what did this user get?" even if the code is edited or deactivated
/// afterwards.
class DiscountRedemption {
  const DiscountRedemption({
    required this.code,
    required this.userId,
    required this.orderId,
    required this.planId,
    required this.originalKopecks,
    required this.discountKopecks,
    required this.finalKopecks,
    required this.redeemedAt,
  });

  /// Original code string as it was at consume time (case preserved).
  /// Lookup uses `code_normalized` payload key.
  final String code;

  /// `users.id` of the buyer.
  final String userId;

  /// Project-specific order identifier (Selfwork order_id for Rhyolite).
  /// Lets audit join with the project's payment table.
  final String orderId;

  /// Plan the discount was applied to.
  final String planId;

  /// Order total before the discount, in kopecks.
  final int originalKopecks;

  /// Kopecks subtracted from [originalKopecks].
  final int discountKopecks;

  /// What the user actually paid, in kopecks (`= originalKopecks - discountKopecks`).
  final int finalKopecks;

  /// Unix-seconds timestamp of when the redemption was recorded (on
  /// payment success, not on preview/createPayment).
  final int redeemedAt;

  Map<String, dynamic> toPayload() => {
        'code': code,
        'code_normalized': code.toLowerCase(),
        'user_id': userId,
        'order_id': orderId,
        'plan_id': planId,
        'original_kopecks': originalKopecks,
        'discount_kopecks': discountKopecks,
        'final_kopecks': finalKopecks,
        'redeemed_at': redeemedAt,
      };

  factory DiscountRedemption.fromPayload(Map<String, Object?> payload) =>
      DiscountRedemption(
        code: payload['code'] as String,
        userId: payload['user_id'] as String,
        orderId: payload['order_id'] as String,
        planId: payload['plan_id'] as String,
        originalKopecks: (payload['original_kopecks'] as num).toInt(),
        discountKopecks: (payload['discount_kopecks'] as num).toInt(),
        finalKopecks: (payload['final_kopecks'] as num).toInt(),
        redeemedAt: (payload['redeemed_at'] as num).toInt(),
      );
}
