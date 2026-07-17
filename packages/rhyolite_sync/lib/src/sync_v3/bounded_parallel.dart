import 'dart:collection';

/// Runs [task] over every item in [items] with at most [concurrency] tasks
/// in flight at once — a bounded-concurrency worker pool.
///
/// The same shape the upload path uses (StateStartupDiff): N workers drain a
/// shared queue, so wall-clock is the slowest chain rather than the sum. If a
/// task throws, the pool rejects with that error once it surfaces from
/// [Future.wait]; in-flight siblings run to their next await (callers that want
/// prompt teardown throw a cancellation the siblings also observe).
Future<void> boundedParallel<T>(
  Iterable<T> items,
  int concurrency,
  Future<void> Function(T item) task,
) async {
  final queue = Queue<T>.of(items);
  if (queue.isEmpty) return;
  final workers = concurrency.clamp(1, queue.length);
  Future<void> worker() async {
    while (queue.isNotEmpty) {
      await task(queue.removeFirst());
    }
  }

  await Future.wait(List.generate(workers, (_) => worker()));
}
