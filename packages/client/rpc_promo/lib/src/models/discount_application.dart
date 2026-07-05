/// Result of applying a [DiscountCode] to an order amount.
///
/// Computed on the server (no persistence here) — returned to the client
/// for preview, and used by the project's payment flow to know what to
/// charge the user.
///
/// Invariant: `originalKopecks - discountKopecks == finalKopecks` and
/// `finalKopecks >= 0`. Fixed-amount discounts are clamped to the order
/// total; percent discounts are clamped by [DiscountCode.maxDiscountKopecks]
/// if set.
class DiscountApplication {
  const DiscountApplication({
    required this.code,
    required this.originalKopecks,
    required this.discountKopecks,
    required this.finalKopecks,
  });

  /// The code string as stored on the [DiscountCode] (case preserved).
  final String code;

  /// Order total before the discount.
  final int originalKopecks;

  /// Kopecks subtracted from [originalKopecks].
  final int discountKopecks;

  /// What the user pays — always `>= 0`.
  final int finalKopecks;
}
