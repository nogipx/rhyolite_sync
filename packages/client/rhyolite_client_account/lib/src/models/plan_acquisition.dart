/// How a user obtains a [Plan]. Sealed because the set of acquisition
/// kinds is closed by design — adding a new way to acquire a plan is
/// a deliberate architectural decision (new payment flow, new
/// referral mechanism, etc.), not an everyday product change.
sealed class PlanAcquisition {
  const PlanAcquisition();

  static const String _kindPaid = 'paid';
  static const String _kindTrial = 'trial';

  String get kind;

  Map<String, dynamic> toJson() => {'kind': kind};

  factory PlanAcquisition.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String;
    switch (kind) {
      case _kindPaid:
        return const PaidAcquisition();
      case _kindTrial:
        return const TrialAcquisition();
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

