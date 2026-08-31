import 'package:rhyolite_client_obsidian/src/engine/connection_recovery.dart';
import 'package:test/test.dart';

void main() {
  group('planConnectionRecovery', () {
    test('an engine that is still emitting is not torn down', () {
      // The case that cost a user an hour: the probe lost a race against the
      // startup pass's own CPU work, and the remedy threw the pass away.
      expect(
        planConnectionRecovery(sinceLastEvent: const Duration(seconds: 2)),
        ConnectionRecovery.waitItIsAlive,
      );
    });

    test('a busy engine is left alone even when it has gone quiet', () {
      // The startup scan walks the whole vault without emitting anything else
      // — a minute of silence on a large one. Reading that as death is what
      // destroyed a pass mid-scan and made the next attempt redo the minute.
      expect(
        planConnectionRecovery(
          sinceLastEvent: const Duration(minutes: 1),
          busy: true,
        ),
        ConnectionRecovery.waitItIsAlive,
      );
    });

    test('but not forever — a wedged engine is still restarted', () {
      // The other side of "fail toward stuck-busy": an engine that is stuck
      // stays busy, and deferring to that forever trades one stuck state for
      // another.
      expect(
        planConnectionRecovery(
          sinceLastEvent: const Duration(minutes: 30),
          busy: true,
          alreadyNudged: true,
        ),
        ConnectionRecovery.restart,
      );
    });

    test('a silent engine is re-armed before it is restarted', () {
      // Silence plus an unanswered probe is what a dead transport looks like —
      // and also what a swapped socket looks like, which the cheap repair
      // fixes without costing the pass anything. So the cheap one goes first.
      expect(
        planConnectionRecovery(sinceLastEvent: const Duration(minutes: 5)),
        ConnectionRecovery.nudge,
      );
    });

    test('a second refusal after re-arming earns the restart', () {
      expect(
        planConnectionRecovery(
          sinceLastEvent: const Duration(minutes: 5),
          alreadyNudged: true,
        ),
        ConnectionRecovery.restart,
      );
    });

    test('re-arming does not override being alive', () {
      // The order matters: alive wins over everything, so a second probe
      // failing on a working engine still must not restart it.
      expect(
        planConnectionRecovery(
          sinceLastEvent: const Duration(seconds: 2),
          alreadyNudged: true,
        ),
        ConnectionRecovery.waitItIsAlive,
      );
    });

    test('never having emitted counts as silent', () {
      // An engine that has said nothing since it was built has not proved
      // anything about itself, so the probe is all there is to go on.
      expect(
        planConnectionRecovery(sinceLastEvent: const Duration(days: 1)),
        ConnectionRecovery.nudge,
      );
    });

    test('the boundary belongs to alive', () {
      // Ties go to not destroying work — the asymmetry the whole decision
      // rests on. A wrong restart costs the pass; a wrong wait costs the few
      // seconds until the self-heal ladder comes back.
      expect(
        planConnectionRecovery(
          sinceLastEvent: const Duration(seconds: 20),
          aliveWithin: const Duration(seconds: 20),
        ),
        ConnectionRecovery.waitItIsAlive,
      );
    });
  });

  group('probeTimeout', () {
    test('an idle engine answers quickly or not at all', () {
      expect(probeTimeout(busy: false), const Duration(seconds: 5));
    });

    test('a busy engine gets room to answer', () {
      // The probe queues behind the work it is probing, so five seconds of a
      // startup pass's backlog is not evidence about the socket.
      expect(probeTimeout(busy: true), greaterThan(const Duration(seconds: 5)));
    });
  });

  // -------------------------------------------------------------------------
  // The whole ladder, walked as a sequence rather than rung by rung.
  //
  // Each rung is asserted above in isolation; what these check is that they
  // compose into the behaviour the rework was for — that the expensive remedy
  // is unreachable while the engine is doing anything, and reachable when it
  // truly is not.
  // -------------------------------------------------------------------------
  group('the ladder end to end', () {
    /// Walks the real decision sequence: probe fails, plan, maybe re-arm,
    /// probe again, plan again. Returns every verdict in order.
    List<ConnectionRecovery> walk({
      required Duration quiet,
      required bool busy,
      required bool reArmWorks,
    }) {
      final steps = <ConnectionRecovery>[];
      var first = planConnectionRecovery(sinceLastEvent: quiet, busy: busy);
      steps.add(first);
      if (first != ConnectionRecovery.nudge) return steps;
      if (reArmWorks) return steps; // second probe passed; no further verdict
      steps.add(
        planConnectionRecovery(
          sinceLastEvent: quiet,
          busy: busy,
          alreadyNudged: true,
        ),
      );
      return steps;
    }

    test('an uploading engine is never touched', () {
      // Progress events keep arriving, so the ladder stops at the first rung
      // however the probe behaves.
      expect(
        walk(quiet: const Duration(seconds: 1), busy: true, reArmWorks: false),
        [ConnectionRecovery.waitItIsAlive],
      );
    });

    test('a scanning engine is never touched either', () {
      // The scan emits its heartbeat now, but even a gap between beats is
      // covered by busy — this is the case that used to cost an hour.
      expect(
        walk(quiet: const Duration(minutes: 2), busy: true, reArmWorks: false),
        [ConnectionRecovery.waitItIsAlive],
      );
    });

    test('a swapped socket is repaired without a restart', () {
      // Idle and unreachable, but re-arming answers — the notify stream had
      // gone silent under a replaced transport. No restart in the sequence.
      final steps =
          walk(quiet: const Duration(minutes: 2), busy: false, reArmWorks: true);
      expect(steps, [ConnectionRecovery.nudge]);
      expect(steps, isNot(contains(ConnectionRecovery.restart)));
    });

    test('a genuinely dead transport still gets restarted', () {
      // The case the health check exists for. It is reachable — just last.
      expect(
        walk(quiet: const Duration(minutes: 2), busy: false, reArmWorks: false),
        [ConnectionRecovery.nudge, ConnectionRecovery.restart],
      );
    });

    test('a wedged engine is restarted despite claiming to be busy', () {
      // The escape hatch. Without it, "fail toward stuck-busy" would become a
      // way to never recover at all.
      expect(
        walk(quiet: const Duration(minutes: 30), busy: true, reArmWorks: false),
        [ConnectionRecovery.nudge, ConnectionRecovery.restart],
      );
    });

    test('a restart is unreachable while the engine is busy and recent', () {
      // The property the whole rework is for, stated once directly: across
      // every combination where the engine is doing something, the expensive
      // remedy never appears.
      for (final quiet in [
        Duration.zero,
        const Duration(seconds: 19),
        const Duration(seconds: 21),
        const Duration(minutes: 4),
      ]) {
        expect(
          walk(quiet: quiet, busy: true, reArmWorks: false),
          isNot(contains(ConnectionRecovery.restart)),
          reason: 'busy engine, quiet for $quiet',
        );
      }
    });
  });
}
