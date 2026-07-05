import 'plan_acquisition.dart';
import 'plan_capabilities.dart';

/// A single subscription plan — bundles billing details, capabilities
/// and how the user obtains it. The single source of truth for
/// everything tariff-related: one constant `_plans` list in
/// `rhyolite_account_server/bin/server.dart` drives the public
/// products catalog, trial auto-grant, promo redemption, and the
/// daemon-side enforcement gates.
class Plan {
  const Plan({
    required this.planId,
    required this.name,
    required this.description,
    required this.amountKopecks,
    required this.periodDays,
    required this.caps,
    required this.acquisition,
  });

  /// Stable identifier persisted in the `subscriptions.plan` column.
  /// Once a plan id is shipped to production it MUST NOT be renamed —
  /// active subscriptions reference it. Deprecated plans should stay
  /// in the registry until their last active subscription expires.
  final String planId;

  /// Display name shown in the purchase modal and receipts.
  final String name;

  /// Short marketing description (one or two sentences). Surfaces in
  /// the purchase modal beneath the price.
  final String description;

  /// Price in kopecks. Zero for trial and most promo plans.
  final int amountKopecks;

  /// Billing period length in days. Used by the webhook to set
  /// `current_period_end = now + periodDays` on the subscription row.
  final int periodDays;

  /// What the plan unlocks. Daemon interceptors and the account
  /// server's vault-creation gate consult these fields directly —
  /// they never branch on plan id.
  final PlanCapabilities caps;

  /// How a user obtains this plan: standard payment, automatic
  /// trial grant, or promo redemption.
  final PlanAcquisition acquisition;

  factory Plan.fromJson(Map<String, dynamic> json) => Plan(
        planId: json['planId'] as String,
        name: json['name'] as String,
        description: json['description'] as String,
        amountKopecks: (json['amountKopecks'] as num).toInt(),
        periodDays: (json['periodDays'] as num).toInt(),
        caps: PlanCapabilities.fromJson(
          (json['caps'] as Map).cast<String, dynamic>(),
        ),
        acquisition: PlanAcquisition.fromJson(
          (json['acquisition'] as Map).cast<String, dynamic>(),
        ),
      );

  Map<String, dynamic> toJson() => {
        'planId': planId,
        'name': name,
        'description': description,
        'amountKopecks': amountKopecks,
        'periodDays': periodDays,
        'caps': caps.toJson(),
        'acquisition': acquisition.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is Plan &&
      planId == other.planId &&
      name == other.name &&
      description == other.description &&
      amountKopecks == other.amountKopecks &&
      periodDays == other.periodDays &&
      caps == other.caps &&
      acquisition == other.acquisition;

  @override
  int get hashCode => Object.hash(
        planId,
        name,
        description,
        amountKopecks,
        periodDays,
        caps,
        acquisition,
      );

  @override
  String toString() => 'Plan($planId, ${amountKopecks ~/ 100}₽/'
      '${periodDays}d, ${acquisition.kind})';
}
