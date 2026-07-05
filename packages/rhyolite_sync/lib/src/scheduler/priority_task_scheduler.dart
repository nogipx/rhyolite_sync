import 'dart:async';

import 'i_task_scheduler.dart';

export 'i_task_scheduler.dart';

/// A generic, dependency-free [ITaskScheduler].
///
/// Deliberately knows NOTHING about sync, files, or RPC — it only orders
/// `Future`-returning closures. That keeps it universal and trivially
/// extractable into its own package later; the sync engine adapts to it, not
/// the other way round.
///
/// What it gives (not throughput — there is no parallelism beyond
/// [maxConcurrent], which on a single-threaded host stays 1):
///   * **priority** — higher [schedule]`priority` runs first; ties break FIFO
///     by enqueue order, so equal-priority work stays fair.
///   * **coalescing** — scheduling a [key] that is still PENDING replaces its
///     closure and resets its [delay]; the older closure never runs. (A key
///     that is currently RUNNING is not coalesced — a fresh task is enqueued
///     to run after it, since the running one acted on now-stale input.)
///   * **debounce** — a non-zero [delay] holds a task until it has been quiet
///     for that long; re-scheduling the same key restarts the quiet period.
///   * **cancellation** — [cancel] drops a pending task or signals a running
///     task's [TaskCancelToken]; the task decides how to honour it.
///   * **grouping** — an optional [group] tags a task so a whole subsystem's
///     work can be cancelled at once via [cancelGroup], without disturbing
///     other owners that share the same scheduler instance.
///   * **gating** — [setMinPriority] pauses every task below a threshold
///     (e.g. background work while the user is active), [clearMinPriority]
///     reopens the gate.
///
/// Task errors are isolated: they go to [onError] (if given) and never stop
/// the scheduler or other tasks.
class PriorityTaskScheduler implements ITaskScheduler {
  PriorityTaskScheduler({
    this.maxConcurrent = 1,
    void Function(Object error, StackTrace stack)? onError,
  })  : assert(maxConcurrent >= 1),
        _onError = onError;

  /// Maximum tasks running at once. 1 (the default) makes the scheduler a
  /// strict serializer — correct for a single connection / single thread.
  final int maxConcurrent;
  final void Function(Object error, StackTrace stack)? _onError;

  final List<_Task> _pending = [];
  final Map<Object, _Task> _pendingByKey = {};
  final Set<_Task> _running = {};
  final Map<Object, _Task> _runningByKey = {};
  int _seq = 0;
  int? _minPriority;
  bool _disposed = false;
  Completer<void>? _idleWaiter;

  @override
  int get queuedCount => _pending.length;
  @override
  int get runningCount => _running.length;
  @override
  bool get isIdle => _pending.isEmpty && _running.isEmpty;

  /// Completes the next time the scheduler becomes idle (nothing pending or
  /// running). Resolves immediately if already idle.
  @override
  Future<void> get whenIdle {
    if (isIdle) return Future<void>.value();
    return (_idleWaiter ??= Completer<void>()).future;
  }

  /// Enqueue [run], or coalesce it onto a pending task with the same [key].
  ///
  /// Returns a future that completes when the task finishes (or is dropped via
  /// [cancel] / [dispose]). When a schedule coalesces onto a pending task,
  /// both callers' futures complete together when that task runs — so awaiting
  /// the return value is safe under coalescing.
  @override
  Future<void> schedule({
    Object? key,
    Object? group,
    int priority = 0,
    Duration delay = Duration.zero,
    bool preemptible = false,
    required TaskRun run,
  }) {
    if (_disposed) return Future<void>.value();

    if (key != null) {
      final existing = _pendingByKey[key];
      if (existing != null) {
        // Coalesce: latest closure + priority win, quiet period restarts.
        existing.run = run;
        existing.priority = priority;
        existing.preemptible = preemptible;
        existing.group = group;
        existing.delayTimer?.cancel();
        existing.delayTimer = null;
        if (delay > Duration.zero) {
          existing.eligible = false;
          existing.delayTimer = Timer(delay, () {
            existing.eligible = true;
            existing.delayTimer = null;
            _pump();
          });
        } else {
          existing.eligible = true;
          _pump();
        }
        return existing.done.future;
      }
    }

    final task = _Task(
      key: key,
      group: group,
      priority: priority,
      run: run,
      seq: _seq++,
      preemptible: preemptible,
    );
    _pending.add(task);
    if (key != null) _pendingByKey[key] = task;
    if (delay > Duration.zero) {
      task.eligible = false;
      task.delayTimer = Timer(delay, () {
        task.eligible = true;
        task.delayTimer = null;
        _pump();
      });
    } else {
      task.eligible = true;
    }
    _pump();
    return task.done.future;
  }

  /// Drop the pending task for [key], or signal the running task's token.
  @override
  void cancel(Object key) {
    final pending = _pendingByKey.remove(key);
    if (pending != null) {
      pending.delayTimer?.cancel();
      _pending.remove(pending);
      pending.complete();
      _maybeIdle();
      return;
    }
    _runningByKey[key]?.controller?.signal();
  }

  /// Drop every pending task tagged with [group] and signal the token of every
  /// running task in it. Tasks without that group (other subsystems sharing
  /// this scheduler) are untouched — this is how an owner tears down only its
  /// own work on a shared instance.
  @override
  void cancelGroup(Object group) {
    final dropped = <_Task>[];
    for (final t in _pending) {
      if (t.group == group) dropped.add(t);
    }
    for (final t in dropped) {
      t.delayTimer?.cancel();
      _pending.remove(t);
      final key = t.key;
      if (key != null && identical(_pendingByKey[key], t)) {
        _pendingByKey.remove(key);
      }
      t.complete();
    }
    for (final r in _running) {
      if (r.group == group) r.controller?.signal();
    }
    _maybeIdle();
  }

  /// Only tasks whose priority is >= [minPriority] may start; lower-priority
  /// tasks wait until the gate is lowered or [clearMinPriority]ed. Does not
  /// affect already-running tasks.
  @override
  void setMinPriority(int minPriority) {
    _minPriority = minPriority;
    _pump();
  }

  @override
  void clearMinPriority() {
    _minPriority = null;
    _pump();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final t in _pending) {
      t.delayTimer?.cancel();
      t.complete();
    }
    _pending.clear();
    _pendingByKey.clear();
    for (final t in _running) {
      t.controller?.signal();
    }
    if (_idleWaiter != null && !_idleWaiter!.isCompleted) {
      _idleWaiter!.complete();
      _idleWaiter = null;
    }
  }

  void _pump() {
    if (_disposed) return;
    while (_running.length < maxConcurrent) {
      final next = _pickEligible();
      if (next == null) break;
      _start(next);
    }
    _preemptIfNeeded();
    _maybeIdle();
  }

  /// When a higher-priority task is waiting only because the slots are full,
  /// ask any running PREEMPTIBLE task of strictly lower priority to yield
  /// (signal its token). Whether it actually yields — and re-schedules itself
  /// to finish later — is up to the task; the scheduler only requests it.
  void _preemptIfNeeded() {
    if (_running.length < maxConcurrent) return;
    final floor = _minPriority;
    int? topPending;
    for (final t in _pending) {
      if (!t.eligible) continue;
      if (floor != null && t.priority < floor) continue;
      if (topPending == null || t.priority > topPending) topPending = t.priority;
    }
    if (topPending == null) return;
    for (final r in _running) {
      if (r.preemptible &&
          r.priority < topPending &&
          !(r.controller?.token.isCancelled ?? true)) {
        r.controller?.signal();
      }
    }
  }

  _Task? _pickEligible() {
    _Task? best;
    final floor = _minPriority;
    for (final t in _pending) {
      if (!t.eligible) continue;
      if (floor != null && t.priority < floor) continue;
      if (best == null ||
          t.priority > best.priority ||
          (t.priority == best.priority && t.seq < best.seq)) {
        best = t;
      }
    }
    return best;
  }

  void _start(_Task task) {
    _pending.remove(task);
    final key = task.key;
    if (key != null) {
      _pendingByKey.remove(key);
      _runningByKey[key] = task;
    }
    final controller = TaskCancelController();
    task.controller = controller;
    _running.add(task);
    () async {
      try {
        await task.run(controller.token);
      } catch (e, st) {
        _onError?.call(e, st);
      } finally {
        _running.remove(task);
        if (key != null && identical(_runningByKey[key], task)) {
          _runningByKey.remove(key);
        }
        task.complete();
        _pump();
      }
    }();
  }

  void _maybeIdle() {
    if (isIdle && _idleWaiter != null && !_idleWaiter!.isCompleted) {
      _idleWaiter!.complete();
      _idleWaiter = null;
    }
  }
}

class _Task {
  _Task({
    required this.key,
    required this.group,
    required this.priority,
    required this.run,
    required this.seq,
    required this.preemptible,
  });

  final Object? key;
  Object? group;
  int priority;
  TaskRun run;
  final int seq;
  bool preemptible;
  bool eligible = true;
  Timer? delayTimer;
  TaskCancelController? controller;
  final Completer<void> done = Completer<void>();

  void complete() {
    if (!done.isCompleted) done.complete();
  }
}
