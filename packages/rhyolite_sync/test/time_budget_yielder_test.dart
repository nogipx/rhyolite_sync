import 'dart:async';

import 'package:rhyolite_sync/src/sync_v3/time_budget_yielder.dart';
import 'package:test/test.dart';

/// Whether the call reached the EVENT LOOP, not merely the microtask queue.
///
/// `maybeYield` is `async`, so even its fast path hands back a future that
/// completes a microtask later — timing it, or watching when `then` runs,
/// cannot tell the two apart. A timer can: `Future.delayed(Duration.zero)`
/// is itself a timer scheduled after this one, so if the yield happened our
/// marker has fired by the time the call returns, and if it did not, only
/// microtasks drained and the marker is still pending.
Future<bool> _yielded(Future<void> Function() call) async {
  var marker = false;
  Timer.run(() => marker = true);
  await call();
  return marker;
}

void _burn(int ms) {
  final sw = Stopwatch()..start();
  while (sw.elapsedMilliseconds < ms) {
    // Spin: the point is to spend the budget without yielding.
  }
}

void main() {
  group('TimeBudgetYielder', () {
    test('does not yield before the budget is spent', () async {
      // The whole point: a loop over cheap items must not buy a clamped timer
      // per item, which is what a per-item yield does.
      final y = TimeBudgetYielder(budget: const Duration(seconds: 10));
      for (var i = 0; i < 100; i++) {
        expect(
          await _yielded(y.maybeYield),
          isFalse,
          reason: 'nothing here spent 10 s, so nothing should have yielded',
        );
      }
    });

    test('yields once the budget is spent, and rearms after', () async {
      final y = TimeBudgetYielder(budget: const Duration(milliseconds: 5));
      _burn(12);
      expect(
        await _yielded(y.maybeYield),
        isTrue,
        reason: '12 ms of work exceeds a 5 ms budget',
      );
      expect(
        await _yielded(y.maybeYield),
        isFalse,
        reason:
            'the budget must rearm at the yield, or every later '
            'iteration would yield forever',
      );
    });

    test('the budget measures work, not time spent yielding', () async {
      // Reset happens BEFORE the await. Were it after, the yield's own
      // duration would count against the next budget — so on a loaded event
      // loop the yielder would fire far more often than it was asked to.
      final y = TimeBudgetYielder(budget: const Duration(milliseconds: 5));
      _burn(8);
      expect(await _yielded(y.maybeYield), isTrue);
      expect(await _yielded(y.maybeYield), isFalse);
    });

    test('a zero budget yields every time', () async {
      final y = TimeBudgetYielder(budget: Duration.zero);
      expect(await _yielded(y.maybeYield), isTrue);
      expect(await _yielded(y.maybeYield), isTrue);
    });
  });
}
