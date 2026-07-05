/// How a user obtains a [Plan]. Sealed because the set of acquisition
/// kinds is closed by design — adding a new way to acquire a plan is
/// a deliberate architectural decision (new payment flow, new
/// referral mechanism, etc.), not an everyday product change.
sealed class PlanAcquisition {
  const PlanAcquisition();

  static const String _kindPaid = 'paid';
  static const String _kindTrial = 'trial';
  static const String _kindPromo = 'promo';

  String get kind;

  Map<String, dynamic> toJson() => {'kind': kind};

  factory PlanAcquisition.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String;
    switch (kind) {
      case _kindPaid:
        return const PaidAcquisition();
      case _kindTrial:
        return const TrialAcquisition();
      case _kindPromo:
        return PromoAcquisition(
          requiredCode: json['requiredCode'] as String?,
          eligibleEmails: ((json['eligibleEmails'] as List?) ?? const [])
              .cast<String>()
              .toSet(),
        );
    }
    throw FormatException('Unknown PlanAcquisition kind: $kind');
  }
}

/// Purchased via the standard payment flow (selfwork product).
/// Exposed in the public products list and the in-plugin purchase
/// modal.
class PaidAcquisition extends PlanAcquisition {
  const PaidAcquisition();

  @override
  String get kind => PlanAcquisition._kindPaid;

  @override
  bool operator ==(Object other) => other is PaidAcquisition;

  @override
  int get hashCode => 0;
}

/// Auto-granted exactly once per user, typically on first signup. The
/// account server records a `trial_granted_at` flag on the user row
/// to prevent re-grant after a delete/restore cycle.
class TrialAcquisition extends PlanAcquisition {
  const TrialAcquisition();

  @override
  String get kind => PlanAcquisition._kindTrial;

  @override
  bool operator ==(Object other) => other is TrialAcquisition;

  @override
  int get hashCode => 1;
}

/// Granted via a redemption flow: user enters a code in the plugin or
/// matches one of the [eligibleEmails] on signup. Either gate is
/// sufficient — empty [eligibleEmails] with a [requiredCode] means
/// "anyone with the code", and an empty [requiredCode] with a
/// non-empty allowlist means "anyone on the list, no code needed".
class PromoAcquisition extends PlanAcquisition {
  const PromoAcquisition({
    this.requiredCode,
    this.eligibleEmails = const {},
  });

  /// Code the user has to enter to redeem. Case-insensitive
  /// comparison is the embedder's responsibility.
  final String? requiredCode;

  /// Allow-list of email addresses that may redeem without a code.
  final Set<String> eligibleEmails;

  @override
  String get kind => PlanAcquisition._kindPromo;

  @override
  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (requiredCode != null) 'requiredCode': requiredCode,
        if (eligibleEmails.isNotEmpty)
          'eligibleEmails': eligibleEmails.toList(),
      };

  @override
  bool operator ==(Object other) =>
      other is PromoAcquisition &&
      requiredCode == other.requiredCode &&
      _setEquals(eligibleEmails, other.eligibleEmails);

  @override
  int get hashCode =>
      Object.hash(requiredCode, Object.hashAllUnordered(eligibleEmails));
}

bool _setEquals<T>(Set<T> a, Set<T> b) {
  if (a.length != b.length) return false;
  return a.containsAll(b);
}
