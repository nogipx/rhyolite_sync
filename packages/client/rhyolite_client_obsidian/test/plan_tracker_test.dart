@TestOn('vm')
library;

import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:rhyolite_client_obsidian/src/engine/plan_status.dart';
import 'package:rhyolite_client_obsidian/src/engine/plan_tracker.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The three rules that used to live in four top-level variables.
//
// `plan_status_test.dart` covers the decisions — what to keep, what to say.
// This covers the sequencing around them, which is where they can still go
// wrong: the remembered snapshot surviving the fresh one, self-host having no
// plan to talk about, and an announcement being once per period rather than
// once per start.
// ---------------------------------------------------------------------------

final _now = DateTime.utc(2026, 9, 1);
final _ended = DateTime.utc(2026, 8, 1);

SubscriptionDto _dto(SubscriptionStatus status, {DateTime? end}) =>
    SubscriptionDto(
      status: status,
      plan: 'rhyolite-pro-monthly',
      currentPeriodEnd: end == null ? null : end.millisecondsSinceEpoch ~/ 1000,
    );

void main() {
  test('the remembered plan survives the fresh one', () {
    final plans = PlanTracker()
      ..seed(
        PlanSnapshot(status: SubscriptionStatus.active, periodEnd: _ended),
      );

    // The account service answers a lapse and a never-subscribed identically.
    // Only the seeded side can tell them apart, so absorbing must not erase it.
    plans.absorb(_dto(SubscriptionStatus.none));

    expect(plans.current?.status, SubscriptionStatus.expired);
    expect(
      plans.remembered?.status,
      SubscriptionStatus.active,
      reason: 'overwritten, and the lapse becomes invisible from here on',
    );
    expect(plans.refresh(_now)?.alert, PlanAlert.ended);
  });

  test('absorbing nothing new returns nothing to persist', () {
    final plans = PlanTracker();
    final first = plans.absorb(_dto(SubscriptionStatus.active, end: _now));
    expect(first, isNotNull, reason: 'the first answer is always news');

    expect(
      plans.absorb(_dto(SubscriptionStatus.active, end: _now)),
      isNull,
      reason: 'a write per lookup, for an unchanged plan, on every start',
    );
    expect(plans.absorb(null), isNull, reason: 'a failed lookup is not news');
  });

  test('self-host has no plan to be quiet or loud about', () {
    final lapsed = PlanTracker()
      ..seed(
        PlanSnapshot(status: SubscriptionStatus.expired, periodEnd: _ended),
      );
    expect(lapsed.refresh(_now)?.alert, PlanAlert.ended);

    final selfHost = PlanTracker(selfHost: true)
      ..seed(
        PlanSnapshot(status: SubscriptionStatus.expired, periodEnd: _ended),
      );
    expect(
      selfHost.refresh(_now),
      isNull,
      reason:
          'quiet is already the current notice, so there is nothing to change '
          '— and nothing to announce to someone with no account',
    );
    expect(selfHost.notice, PlanNotice.quiet);
  });

  test('refresh only answers when the answer changed', () {
    final plans = PlanTracker()
      ..seed(
        PlanSnapshot(status: SubscriptionStatus.expired, periodEnd: _ended),
      );

    expect(plans.refresh(_now), isNotNull);
    expect(
      plans.refresh(_now),
      isNull,
      reason: 'every lookup would re-announce the same period',
    );
  });

  test('an announcement is once per period, and renewal re-arms it', () {
    final plans = PlanTracker();
    final august = PlanNotice(PlanAlert.ended, _ended);

    expect(plans.claimAnnouncement(august), isTrue);
    expect(plans.claimAnnouncement(august), isFalse);

    // Renewing moves the date. Keyed on the date itself, so the new period is
    // announceable with no bookkeeping of its own.
    expect(
      plans.claimAnnouncement(
        PlanNotice(PlanAlert.endingSoon, DateTime.utc(2026, 10, 1)),
      ),
      isTrue,
    );
  });
}
