import 'dart:async';

import 'package:rhyolite_sync/src/sync_v3/bounded_parallel.dart';
import 'package:test/test.dart';

void main() {
  test('runs every item and never exceeds the concurrency bound', () async {
    const total = 20;
    const concurrency = 4;
    var inFlight = 0;
    var maxInFlight = 0;
    final done = <int>[];

    await boundedParallel(
      List.generate(total, (i) => i),
      concurrency,
      (i) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        // Yield so multiple tasks are genuinely in flight at once.
        await Future<void>.delayed(const Duration(milliseconds: 1));
        done.add(i);
        inFlight--;
      },
    );

    expect(done.length, total, reason: 'every item ran exactly once');
    expect(done.toSet().length, total, reason: 'no duplicates');
    expect(maxInFlight, lessThanOrEqualTo(concurrency),
        reason: 'never more than `concurrency` tasks in flight');
    expect(maxInFlight, greaterThan(1),
        reason: 'work actually overlapped (not serial)');
  });

  test('empty input is a no-op; fewer items than workers still all run',
      () async {
    var count = 0;
    await boundedParallel(<int>[], 4, (_) async => count++);
    expect(count, 0);

    await boundedParallel([1, 2], 8, (_) async => count++);
    expect(count, 2);
  });

  test('a throwing task surfaces the error from the pool', () async {
    expect(
      boundedParallel([1, 2, 3], 2, (i) async {
        if (i == 2) throw StateError('boom');
      }),
      throwsA(isA<StateError>()),
    );
  });
}
