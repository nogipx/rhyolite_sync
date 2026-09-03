import 'package:rhyolite_sync/src/sync_v3/notify_coordinator.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The coordinator asks WHICH connection to subscribe on, every time.
//
// It used to be told once, at construction. That made its self-healing useful
// only while the connection it was built on stayed alive: after a transport
// swap every retry re-attached to the dead one and failed the same way, at a
// capped thirty-second interval, indefinitely. Notify was gone and the only
// trace was a log line repeating `transport not connected — resubscribing`.
//
// Recovery then required something OUTSIDE to notice and construct a whole new
// coordinator. In one real session nothing did for nine minutes, and it only
// ended because an unrelated reconnect happened to fire the hook that rebuilds
// it.
// ---------------------------------------------------------------------------

void main() {
  test('the endpoint is resolved again on every attempt, not captured',
      () async {
    var resolutions = 0;
    // Null models the ordinary gap between a drop and a reconnect, and it is
    // the only answer that reliably drives a retry: a live-but-unanswered
    // transport neither errors nor completes, so the subscription simply hangs
    // and nothing is retried at all — the case this class explicitly leaves to
    // the caller.
    //
    // What is asserted is the contract that was missing: the coordinator ASKS
    // again. Capturing the answer is what made every retry re-attach to a dead
    // connection, and asking is what lets a returning one be found.
    final coordinator = NotifyCoordinator(
      resolveEndpoint: () {
        resolutions++;
        return null;
      },
      topic: 'vault:test',
      onNotify: (_) {},
    )..start();
    addTearDown(coordinator.stop);

    expect(resolutions, 1, reason: 'start() subscribes immediately');

    // Past the first backoff (1s), inside the second.
    await Future<void>.delayed(const Duration(milliseconds: 1400));

    expect(
      resolutions,
      greaterThan(1),
      reason: 'a retry must ask again — otherwise it can only ever re-attach '
          'to the connection that was already dead',
    );
  });

  test('an absent connection is a wait, not an error worth reporting',
      () async {
    // Between a drop and a reconnect there is nothing to report and nothing to
    // act on. Warning once per backoff turns a normal gap into a log nobody
    // can read — which is exactly what buried the real failure.
    final warnings = <String>[];
    final coordinator = NotifyCoordinator(
      resolveEndpoint: () => null,
      topic: 'vault:test',
      onNotify: (_) {},
      onWarning: warnings.add,
    )..start();
    addTearDown(coordinator.stop);

    await Future<void>.delayed(const Duration(milliseconds: 1400));

    expect(warnings, isEmpty);
  });

  test('stop() ends the retries', () async {
    var resolutions = 0;
    final coordinator = NotifyCoordinator(
      resolveEndpoint: () {
        resolutions++;
        return null;
      },
      topic: 'vault:test',
      onNotify: (_) {},
    )..start();

    await coordinator.stop();
    final afterStop = resolutions;
    await Future<void>.delayed(const Duration(milliseconds: 1400));

    expect(
      resolutions,
      afterStop,
      reason: 'a stopped coordinator that kept a timer alive would hold the '
          'connection it was stopped to release',
    );
  });
}
