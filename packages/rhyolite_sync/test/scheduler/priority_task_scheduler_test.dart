import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:rhyolite_sync/src/scheduler/priority_task_scheduler.dart';
import 'package:test/test.dart';

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  group('PriorityTaskScheduler', () {
    test('runs a scheduled task', () async {
      final s = PriorityTaskScheduler();
      var ran = false;
      s.schedule(run: (_) async => ran = true);
      await s.whenIdle;
      expect(ran, isTrue);
    });

    test('higher priority runs first; ties break FIFO', () async {
      final s = PriorityTaskScheduler();
      final order = <String>[];
      final gate = Completer<void>();
      // Occupy the single slot so the next three queue up together.
      s.schedule(run: (_) async => gate.future);
      s.schedule(priority: 1, run: (_) async => order.add('a1'));
      s.schedule(priority: 10, run: (_) async => order.add('b10'));
      s.schedule(priority: 1, run: (_) async => order.add('a1-second'));
      gate.complete();
      await s.whenIdle;
      // b10 first (priority), then the two priority-1 in enqueue order.
      expect(order, ['b10', 'a1', 'a1-second']);
    });

    test('scheduling a pending key coalesces — only the latest closure runs',
        () async {
      final s = PriorityTaskScheduler();
      final ran = <String>[];
      final gate = Completer<void>();
      s.schedule(run: (_) async => gate.future); // hold the slot
      s.schedule(key: 'x', run: (_) async => ran.add('run1'));
      s.schedule(key: 'x', run: (_) async => ran.add('run2'));
      gate.complete();
      await s.whenIdle;
      expect(ran, ['run2']);
    });

    test('a key running does NOT coalesce — a fresh task runs after it',
        () async {
      final s = PriorityTaskScheduler();
      final ran = <String>[];
      final started = Completer<void>();
      final release = Completer<void>();
      s.schedule(key: 'x', run: (_) async {
        ran.add('first');
        started.complete();
        await release.future;
      });
      await started.future; // 'x' is now running
      s.schedule(key: 'x', run: (_) async => ran.add('second'));
      release.complete();
      await s.whenIdle;
      expect(ran, ['first', 'second']);
    });

    test('cancel drops a pending task', () async {
      final s = PriorityTaskScheduler();
      final ran = <String>[];
      final gate = Completer<void>();
      s.schedule(run: (_) async => gate.future);
      s.schedule(key: 'x', run: (_) async => ran.add('x'));
      s.cancel('x');
      gate.complete();
      await s.whenIdle;
      expect(ran, isEmpty);
    });

    test('cancel signals a running task via its token', () async {
      final s = PriorityTaskScheduler();
      final started = Completer<void>();
      var observed = false;
      s.schedule(key: 'x', run: (token) async {
        started.complete();
        await token.onCancel;
        observed = token.isCancelled;
      });
      await started.future;
      s.cancel('x');
      await s.whenIdle;
      expect(observed, isTrue);
    });

    test('min-priority gate pauses lower-priority work until cleared',
        () async {
      final s = PriorityTaskScheduler();
      final ran = <String>[];
      s.setMinPriority(10);
      s.schedule(priority: 0, run: (_) async => ran.add('low'));
      s.schedule(priority: 10, run: (_) async => ran.add('high'));
      await _pump();
      expect(ran, ['high'], reason: 'low is gated out');
      s.clearMinPriority();
      await s.whenIdle;
      expect(ran, ['high', 'low']);
    });

    test('debounce: delay holds a task and re-scheduling resets the quiet '
        'period; only the latest closure runs once', () {
      fakeAsync((async) {
        final s = PriorityTaskScheduler();
        final ran = <String>[];
        s.schedule(
          key: 'x',
          delay: const Duration(milliseconds: 100),
          run: (_) async => ran.add('v1'),
        );
        async.elapse(const Duration(milliseconds: 50));
        // Re-schedule before it fires → resets the 100ms quiet period.
        s.schedule(
          key: 'x',
          delay: const Duration(milliseconds: 100),
          run: (_) async => ran.add('v2'),
        );
        async.elapse(const Duration(milliseconds: 80));
        expect(ran, isEmpty, reason: 'quiet period restarted at 50ms');
        async.elapse(const Duration(milliseconds: 40)); // 120ms since reset
        async.flushMicrotasks();
        expect(ran, ['v2']);
      });
    });

    test('respects maxConcurrent', () async {
      final s = PriorityTaskScheduler(maxConcurrent: 2);
      var running = 0;
      var maxSeen = 0;
      final gates = [Completer<void>(), Completer<void>(), Completer<void>()];
      for (final g in gates) {
        s.schedule(run: (_) async {
          running++;
          maxSeen = max(maxSeen, running);
          await g.future;
          running--;
        });
      }
      await _pump();
      expect(maxSeen, 2, reason: 'only 2 run at once');
      for (final g in gates) {
        g.complete();
      }
      await s.whenIdle;
      expect(maxSeen, 2);
    });

    test('a throwing task is isolated: onError fires, others still run',
        () async {
      final errors = <Object>[];
      final s = PriorityTaskScheduler(onError: (e, _) => errors.add(e));
      final ran = <String>[];
      s.schedule(run: (_) async => throw StateError('boom'));
      s.schedule(run: (_) async => ran.add('after'));
      await s.whenIdle;
      expect(errors, hasLength(1));
      expect(ran, ['after']);
    });

    test('a higher-priority schedule preempts a running PREEMPTIBLE task',
        () async {
      final s = PriorityTaskScheduler();
      final events = <String>[];
      s.schedule(
        priority: 10,
        preemptible: true,
        run: (token) async {
          events.add('bg-start');
          await token.onCancel; // yields when preempted
          events.add('bg-yield');
        },
      );
      await _pump();
      expect(events, ['bg-start']);
      s.schedule(priority: 100, run: (_) async => events.add('hi'));
      await s.whenIdle;
      expect(events, ['bg-start', 'bg-yield', 'hi']);
    });

    test('a running NON-preemptible task is not preempted', () async {
      final s = PriorityTaskScheduler();
      final events = <String>[];
      final release = Completer<void>();
      s.schedule(
        priority: 10,
        run: (_) async {
          events.add('bg-start');
          await release.future;
          events.add('bg-done');
        },
      );
      await _pump();
      s.schedule(priority: 100, run: (_) async => events.add('hi'));
      await _pump();
      expect(events, ['bg-start'], reason: 'hi waits — bg not preemptible');
      release.complete();
      await s.whenIdle;
      expect(events, ['bg-start', 'bg-done', 'hi']);
    });

    test('whenIdle completes immediately when already idle', () async {
      final s = PriorityTaskScheduler();
      await s.whenIdle; // must not hang
      expect(s.isIdle, isTrue);
    });

    test('cancelGroup drops pending tasks of that group only', () async {
      final s = PriorityTaskScheduler();
      final ran = <String>[];
      // Hold the runner busy so the rest stay pending.
      final release = Completer<void>();
      s.schedule(priority: 100, run: (_) async => release.future);
      await _pump();
      s.schedule(group: 'a', run: (_) async => ran.add('a1'));
      s.schedule(group: 'a', run: (_) async => ran.add('a2'));
      s.schedule(group: 'b', run: (_) async => ran.add('b1'));
      s.cancelGroup('a');
      release.complete();
      await s.whenIdle;
      expect(ran, ['b1'], reason: 'group a dropped, group b survives');
    });

    test('cancelGroup signals a running task in that group', () async {
      final s = PriorityTaskScheduler();
      final events = <String>[];
      s.schedule(
        group: 'session',
        run: (token) async {
          events.add('start');
          await token.onCancel;
          events.add('cancelled');
        },
      );
      await _pump();
      expect(events, ['start']);
      s.cancelGroup('session');
      await s.whenIdle;
      expect(events, ['start', 'cancelled']);
    });

    test('cancelGroup leaves a running task of another group alone', () async {
      final s = PriorityTaskScheduler();
      final events = <String>[];
      final release = Completer<void>();
      s.schedule(
        group: 'keep',
        run: (token) async {
          events.add('start');
          await release.future;
          events.add('done');
        },
      );
      await _pump();
      s.cancelGroup('other');
      release.complete();
      await s.whenIdle;
      expect(events, ['start', 'done']);
    });

    test('coalescing onto a pending key updates its group', () async {
      final s = PriorityTaskScheduler();
      final ran = <String>[];
      final release = Completer<void>();
      s.schedule(priority: 100, run: (_) async => release.future);
      await _pump();
      s.schedule(key: 'k', group: 'old', run: (_) async => ran.add('old'));
      s.schedule(key: 'k', group: 'new', run: (_) async => ran.add('new'));
      s.cancelGroup('old'); // must NOT drop it — it's now in group 'new'
      release.complete();
      await s.whenIdle;
      expect(ran, ['new']);
    });
  });
}
