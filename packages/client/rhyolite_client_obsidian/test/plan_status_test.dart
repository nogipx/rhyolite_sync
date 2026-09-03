import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:rhyolite_client_obsidian/src/engine/plan_status.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 28, 12);

  PlanSnapshot active({DateTime? end}) => PlanSnapshot(
    status: SubscriptionStatus.active,
    periodEnd: end,
    plan: 'rhyolite-pro-monthly',
    capabilities: PlanCapabilities.free,
  );

  const free = PlanSnapshot(
    status: SubscriptionStatus.none,
    capabilities: PlanCapabilities.free,
  );

  PlanNotice notice({PlanSnapshot? remembered, PlanSnapshot? current}) =>
      planNotice(remembered: remembered, current: current, now: now);

  group('nothing to say', () {
    test('a plan with time left is quiet', () {
      expect(
        notice(current: active(end: now.add(const Duration(days: 20)))),
        PlanNotice.quiet,
      );
    });

    test('the free tier is a tier, not a lapse', () {
      // Standing free tier: someone who never subscribed has nothing to renew,
      // and telling them their plan ended would be a lie as well as a nag.
      expect(notice(current: free), PlanNotice.quiet);
      expect(notice(remembered: free, current: free), PlanNotice.quiet);
    });

    test('a plan with no end date never expires', () {
      expect(notice(current: active()), PlanNotice.quiet);
    });

    test('nothing known at all stays quiet', () {
      expect(notice(), PlanNotice.quiet);
    });
  });

  group('ending soon', () {
    test('inside the window', () {
      final end = now.add(const Duration(days: 3));
      expect(
        notice(current: active(end: end)),
        PlanNotice(PlanAlert.endingSoon, end),
      );
    });

    test('the window edge is included', () {
      final end = now.add(kPlanEndingSoonWindow);
      expect(
        notice(current: active(end: end)),
        PlanNotice(PlanAlert.endingSoon, end),
      );
    });

    test('just outside it is quiet', () {
      final end = now.add(kPlanEndingSoonWindow + const Duration(minutes: 1));
      expect(notice(current: active(end: end)), PlanNotice.quiet);
    });
  });

  group('ended', () {
    test('the server saying none after an active snapshot IS the lapse', () {
      // The account service reports a lapsed subscription exactly as it reports
      // a user who never paid. This comparison is the only thing that can tell
      // them apart, and it needs no server change to work.
      final end = now.subtract(const Duration(days: 2));
      expect(
        notice(
          remembered: active(end: end),
          current: free,
        ),
        PlanNotice(PlanAlert.ended, end),
      );
    });

    test('an explicit expired status is taken at its word', () {
      final end = now.subtract(const Duration(days: 1));
      final expired = PlanSnapshot(
        status: SubscriptionStatus.expired,
        periodEnd: end,
      );
      expect(notice(current: expired), PlanNotice(PlanAlert.ended, end));
    });

    test('an active snapshot whose date has passed has ended', () {
      // The offline case: the lookup failed, so `current` is null and the
      // remembered snapshot still says active. A period ends on its date
      // whether or not we could reach the server.
      final end = now.subtract(const Duration(hours: 1));
      expect(
        notice(remembered: active(end: end)),
        PlanNotice(PlanAlert.ended, end),
      );
    });

    test('a cancelled plan that had no end date still reports ended', () {
      expect(
        notice(remembered: active(), current: free),
        const PlanNotice(PlanAlert.ended, null),
      );
    });

    test('a failed lookup never turns an active plan into a lapse', () {
      // `current` null means "we could not ask", which must never be read as
      // "the server said none" — that is the whole bug class this avoids.
      expect(
        notice(remembered: active(end: now.add(const Duration(days: 30)))),
        PlanNotice.quiet,
      );
    });

    test('a fresh install after a lapse cannot tell, and stays quiet', () {
      // No remembered snapshot, so `none` is indistinguishable from never
      // having paid. The quota refusal covers this case instead of guessing.
      expect(notice(current: free), PlanNotice.quiet);
    });
  });

  group('resolvePlan — writing down a lapse the server cannot report', () {
    final ended = now.subtract(const Duration(days: 3));
    final freshNone = SubscriptionDto(
      status: SubscriptionStatus.none,
      capabilities: PlanCapabilities.free,
    );

    test('an active plan going to none is recorded as expired', () {
      final out = resolvePlan(
        prior: active(end: ended),
        fresh: freshNone,
      );

      expect(out.status, SubscriptionStatus.expired);
      expect(out.periodEnd, ended);
    });

    test('the recorded lapse survives the next none answer', () {
      // Without this the knowledge that detected the lapse is overwritten by
      // it, and the alert shows for exactly one session.
      final first = resolvePlan(
        prior: active(end: ended),
        fresh: freshNone,
      );
      final second = resolvePlan(prior: first, fresh: freshNone);

      expect(second.status, SubscriptionStatus.expired);
      expect(second.periodEnd, ended);
    });

    test('free capabilities are taken from the fresh answer, not carried', () {
      // The plan really is the free tier now. Keeping the paid capabilities
      // would have this client believe in limits the server will refuse.
      final paid = PlanSnapshot(
        status: SubscriptionStatus.active,
        periodEnd: ended,
        capabilities: const PlanCapabilities(
          canUseManagedStorage: true,
          canUseExternalStorage: true,
          managedStorageQuotaBytes: 1 << 30,
        ),
      );
      final out = resolvePlan(prior: paid, fresh: freshNone);

      expect(out.capabilities, PlanCapabilities.free);
    });

    test('a user who never subscribed stays none', () {
      expect(
        resolvePlan(prior: null, fresh: freshNone).status,
        SubscriptionStatus.none,
      );
      expect(
        resolvePlan(prior: free, fresh: freshNone).status,
        SubscriptionStatus.none,
      );
    });

    test('renewing clears the lapse outright', () {
      final renewed = now.add(const Duration(days: 30));
      final out = resolvePlan(
        prior: PlanSnapshot(
          status: SubscriptionStatus.expired,
          periodEnd: ended,
        ),
        fresh: SubscriptionDto(
          status: SubscriptionStatus.active,
          currentPeriodEnd: renewed.millisecondsSinceEpoch ~/ 1000,
        ),
      );

      expect(out.status, SubscriptionStatus.active);
      expect(
        planNotice(remembered: null, current: out, now: now),
        PlanNotice.quiet,
      );
    });
  });

  group('snapshot round-trip', () {
    test('survives json with every field', () {
      final snap = PlanSnapshot(
        status: SubscriptionStatus.active,
        periodEnd: DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000),
        plan: 'rhyolite-pro-monthly',
        capabilities: PlanCapabilities.free,
      );
      expect(PlanSnapshot.fromJson(snap.toJson()), snap);
    });

    test('survives json with only a status', () {
      const snap = PlanSnapshot(status: SubscriptionStatus.none);
      expect(PlanSnapshot.fromJson(snap.toJson()), snap);
    });

    test('garbage decodes to null rather than throwing', () {
      expect(PlanSnapshot.fromJson(null), isNull);
      expect(PlanSnapshot.fromJson('nope'), isNull);
      expect(PlanSnapshot.fromJson({'status': 'invented'}), isNull);
      expect(PlanSnapshot.fromJson(<String, Object?>{}), isNull);
    });
  });
}
