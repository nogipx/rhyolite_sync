import 'package:rhyolite_client_account/rhyolite_client_account.dart';

/// What the account service last said about this user's plan, kept between
/// sessions in `data.json`.
///
/// Persisted because every consumer of it runs before the answer can arrive:
/// the per-file size gate and the plugin-code storage gate both read a plan
/// during boot, and the panel wants to render one immediately. A lookup that
/// times out — which is most likely exactly when a session is starting — then
/// falls back to the last real answer instead of to "nothing is allowed".
class PlanSnapshot {
  const PlanSnapshot({
    required this.status,
    this.periodEnd,
    this.plan,
    this.capabilities,
  });

  final SubscriptionStatus status;

  /// End of the paid period, or null when the plan does not expire.
  final DateTime? periodEnd;

  final String? plan;
  final PlanCapabilities? capabilities;

  bool get isActive => status == SubscriptionStatus.active;

  static PlanSnapshot of(SubscriptionDto dto) => PlanSnapshot(
    status: dto.status,
    periodEnd: dto.currentPeriodEnd == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(dto.currentPeriodEnd! * 1000),
    plan: dto.plan,
    capabilities: dto.capabilities,
  );

  Map<String, Object?> toJson() => {
    'status': status.name,
    if (periodEnd != null)
      'periodEnd': periodEnd!.millisecondsSinceEpoch ~/ 1000,
    if (plan != null) 'plan': plan,
    if (capabilities != null) 'capabilities': capabilities!.toJson(),
  };

  static PlanSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['status'];
    if (name is! String) return null;
    final status = SubscriptionStatus.values
        .where((s) => s.name == name)
        .firstOrNull;
    if (status == null) return null;
    final end = raw['periodEnd'];
    final caps = raw['capabilities'];
    return PlanSnapshot(
      status: status,
      periodEnd: end is num
          ? DateTime.fromMillisecondsSinceEpoch(end.toInt() * 1000)
          : null,
      plan: raw['plan'] is String ? raw['plan'] as String : null,
      capabilities: caps is Map
          ? PlanCapabilities.fromJson(Map<String, dynamic>.from(caps))
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlanSnapshot &&
      status == other.status &&
      periodEnd == other.periodEnd &&
      plan == other.plan &&
      capabilities == other.capabilities;

  @override
  int get hashCode => Object.hash(status, periodEnd, plan, capabilities);
}

/// The snapshot to keep, given what the server just said and what we knew.
///
/// Exists because the account service cannot report a lapse: it answers `none`
/// with free capabilities both for a subscription that ended and for a user who
/// never had one. Only the client holds the other half of that comparison, so
/// only the client can draw the conclusion — and having drawn it, it has to
/// write it down. Recording the raw `none` would make the lapse visible for one
/// session and invisible from the next, since the very knowledge that detected
/// it would have been overwritten.
///
/// Capabilities always come from [fresh]: the plan really is the free tier now,
/// and carrying the paid ones forward would let this client believe in limits
/// the server will refuse to honour.
PlanSnapshot resolvePlan({
  required PlanSnapshot? prior,
  required SubscriptionDto fresh,
}) {
  final next = PlanSnapshot.of(fresh);
  if (next.status != SubscriptionStatus.none) return next;

  // Carried through repeated `none` answers, not just the first: `prior` is
  // whatever this session last concluded, so an already-recorded lapse stays
  // recorded instead of decaying back into "never subscribed" on the second
  // lookup.
  final had =
      prior != null &&
      (prior.isActive || prior.status == SubscriptionStatus.expired);
  if (!had) return next;

  return PlanSnapshot(
    status: SubscriptionStatus.expired,
    periodEnd: prior.periodEnd,
    plan: prior.plan,
    capabilities: next.capabilities,
  );
}

/// Whether the user needs telling something about their plan.
enum PlanAlert {
  /// Nothing to say. Includes the standing free tier: it is a tier, not a
  /// lapsed trial, and nagging someone who never subscribed is wrong.
  none,

  /// A paid period ends shortly.
  endingSoon,

  /// A paid period has ended. Sync keeps running on free-tier limits, which is
  /// what makes this worth saying: uploads start being refused for quota, and
  /// without this the cause is invisible.
  ended,
}

/// [alert] plus the date it is about, or null when the plan carried no end.
class PlanNotice {
  const PlanNotice(this.alert, [this.date]);

  static const quiet = PlanNotice(PlanAlert.none);

  final PlanAlert alert;
  final DateTime? date;

  bool get isQuiet => alert == PlanAlert.none;

  @override
  bool operator ==(Object other) =>
      other is PlanNotice && alert == other.alert && date == other.date;

  @override
  int get hashCode => Object.hash(alert, date);

  @override
  String toString() => 'PlanNotice(${alert.name}, $date)';
}

/// Default lead time on "your plan ends soon".
const Duration kPlanEndingSoonWindow = Duration(days: 7);

/// `DD.MM.YYYY`. The one date format the plugin shows for a plan, shared so the
/// panel strip, the notice and the settings row cannot drift apart.
String formatPlanDay(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.'
    '${d.month.toString().padLeft(2, '0')}.${d.year}';

/// Decides what to tell the user about their plan.
///
/// [current] is what the server just said, or null when the lookup failed —
/// in which case [remembered] answers alone. That fallback is not a guess: a
/// period ends on its date whether or not we could reach the server, so a
/// remembered end date that has passed is a fact about the plan, not about
/// the network.
///
/// The account service reports a lapsed subscription as
/// [SubscriptionStatus.none] with free capabilities — the same answer it gives
/// someone who never paid. Only [remembered] can tell those apart, which is the
/// second reason to keep it: a snapshot that was active, against a server now
/// saying none, IS the lapse. Nothing server-side has to change for this.
PlanNotice planNotice({
  required PlanSnapshot? remembered,
  required PlanSnapshot? current,
  required DateTime now,
  Duration endingSoonWindow = kPlanEndingSoonWindow,
}) {
  final live = current ?? remembered;
  if (live == null) return PlanNotice.quiet;

  // The server said the period is over, or said nothing and the date we
  // remember has passed.
  if (live.status == SubscriptionStatus.expired) {
    return PlanNotice(PlanAlert.ended, live.periodEnd);
  }

  if (live.isActive) {
    final end = live.periodEnd;
    if (end == null) return PlanNotice.quiet; // a plan with no expiry
    if (!end.isAfter(now)) return PlanNotice(PlanAlert.ended, end);
    return end.difference(now) <= endingSoonWindow
        ? PlanNotice(PlanAlert.endingSoon, end)
        : PlanNotice.quiet;
  }

  // status == none. Distinguishing "lapsed" from "never subscribed" is the
  // whole job of the remembered snapshot: without a paid one behind us this is
  // the free tier, and the free tier is not an alert.
  final was = remembered;
  if (current != null && was != null && was.isActive) {
    return PlanNotice(PlanAlert.ended, was.periodEnd);
  }
  return PlanNotice.quiet;
}
