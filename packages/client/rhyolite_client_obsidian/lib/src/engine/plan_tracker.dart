import 'package:rhyolite_client_account/rhyolite_client_account.dart';

import 'plan_status.dart';

/// The plan as one plugin load knows it.
///
/// `plan_status.dart` holds the decisions — what to keep given a fresh answer
/// ([resolvePlan]), and what to say given what is kept ([planNotice]). This
/// holds the three pieces of state those decisions need to be made in the right
/// order, and nothing else:
///
///  * [current] and [remembered] are separate because the account service
///    reports a lapsed subscription exactly as it reports someone who never
///    paid. The difference between the two IS the lapse, so the older side has
///    to survive being overwritten by the newer one.
///  * [notice] is derived, but held, because several places render it and they
///    must render the same thing.
///  * the announced period is held so a one-off notice is one-off. Keyed on the
///    date, so renewing re-arms it for the new period with no bookkeeping.
///
/// Deliberately callback-free. Earlier drafts took `onNotice`/`announce`
/// closures, which put the decision of what to show inside the thing that only
/// knows what changed — and made every one of these rules reachable only
/// through a live panel. [refresh] and [claimAnnouncement] answer instead, and
/// the caller acts.
class PlanTracker {
  PlanTracker({this.selfHost = false});

  /// Self-host has no account, no plan and nothing to renew. Set during boot,
  /// once the edition is known — which is after the cached plan is read, hence
  /// a field rather than a constructor argument.
  bool selfHost;

  /// The latest answer, or the cache before any answer arrives.
  PlanSnapshot? current;

  /// What the previous load ended on, kept for this whole load.
  PlanSnapshot? remembered;

  /// What every surface currently says about the plan.
  PlanNotice notice = PlanNotice.quiet;

  String? _announcedPeriod;

  /// Null when no answer has ever been obtained — which every consumer must
  /// read as "no answer", not as "nothing is allowed". The engine takes
  /// `maxFileSizeBytes` from here for the per-file size gate.
  PlanCapabilities? get capabilities => current?.capabilities;

  /// Seeds both sides from the cache written by the previous load.
  ///
  /// Both, not just [current]: the first successful lookup overwrites
  /// [current], and a lapse is only visible as the difference between the two.
  void seed(PlanSnapshot? cached) {
    current = cached;
    remembered = cached;
  }

  /// Takes the server's answer.
  ///
  /// Returns the snapshot to persist, or null when there was no answer or it
  /// changed nothing. Persisting matters more than it looks: the only way to
  /// get an answer is a network call made while a sync session starts, so it
  /// fails at exactly the times sessions are hardest to start, and the last
  /// real answer is right far more often than "nothing is allowed".
  PlanSnapshot? absorb(SubscriptionDto? dto) {
    if (dto == null) return null;
    final next = resolvePlan(prior: current ?? remembered, fresh: dto);
    if (current == next) return null;
    current = next;
    return next;
  }

  /// Recomputes [notice]. Returns it when it changed, null when it did not.
  ///
  /// Called after every lookup rather than on a timer: the answer only changes
  /// when the server's does, or when a date passes — and a date that passes
  /// mid-session is caught by the next session's lookup, which is soon enough
  /// for something measured in days.
  PlanNotice? refresh(DateTime now) {
    final next = selfHost
        ? PlanNotice.quiet
        : planNotice(remembered: remembered, current: current, now: now);
    if (next == notice) return null;
    notice = next;
    return next;
  }

  /// True the first time [notice] is claimed for its period, false after.
  ///
  /// The panel strip is what persists; an announcement exists because the panel
  /// may well be closed, and an alert nobody is looking at explains nothing.
  /// One per period, never per start.
  bool claimAnnouncement(PlanNotice notice) {
    final key = '${notice.alert.name}:${notice.date?.toIso8601String() ?? "-"}';
    if (_announcedPeriod == key) return false;
    _announcedPeriod = key;
    return true;
  }
}
