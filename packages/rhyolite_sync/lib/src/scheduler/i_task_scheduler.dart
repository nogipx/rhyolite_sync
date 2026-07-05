import 'dart:async';

/// The closure a scheduled task runs. It is handed a [TaskCancelToken] it may
/// poll ([TaskCancelToken.isCancelled]) or await ([TaskCancelToken.onCancel])
/// to stop early when cancelled.
typedef TaskRun = Future<void> Function(TaskCancelToken token);

/// A generic priority task scheduler: it orders `Future`-returning closures on
/// a small set of lanes. Deliberately knows NOTHING about sync, files, or RPC,
/// so a host can own one instance and share it across subsystems (e.g. an
/// engine's steady-state work and the host's own lifecycle work).
///
/// It buys ordering, not throughput — there is no parallelism beyond the
/// implementation's concurrency cap, which on a single-threaded host stays 1:
///   * **priority** — higher `priority` runs first; ties break FIFO.
///   * **coalescing** — re-scheduling a still-pending `key` replaces it.
///   * **debounce** — a non-zero `delay` holds a task until it is quiet.
///   * **cancellation** — [cancel] / [cancelGroup] drop pending tasks and
///     signal running ones' [TaskCancelToken]s.
///   * **grouping** — an optional group tags tasks so one owner can tear down
///     only its own work via [cancelGroup] on a shared instance.
///   * **gating** — [setMinPriority] pauses everything below a threshold.
abstract interface class ITaskScheduler {
  /// Enqueue [run], or coalesce it onto a pending task with the same [key].
  /// Returns a future that completes when the task finishes (or is dropped via
  /// [cancel] / [cancelGroup] / [dispose]). [group] tags the task for
  /// [cancelGroup]; [delay] debounces; [preemptible] lets a higher-priority
  /// schedule signal this task's token while it runs.
  Future<void> schedule({
    Object? key,
    Object? group,
    int priority,
    Duration delay,
    bool preemptible,
    required TaskRun run,
  });

  /// Drop the pending task for [key], or signal the running task's token.
  void cancel(Object key);

  /// Drop every pending task tagged [group] and signal every running task in
  /// it. Tasks without that group are untouched — how an owner tears down only
  /// its own work on a shared instance.
  void cancelGroup(Object group);

  /// Only tasks whose priority is >= [minPriority] may start; lower-priority
  /// tasks wait until [clearMinPriority]. Does not affect running tasks.
  void setMinPriority(int minPriority);

  /// Lift the [setMinPriority] gate.
  void clearMinPriority();

  /// Completes the next time the scheduler is idle (nothing pending/running).
  Future<void> get whenIdle;

  bool get isIdle;
  int get queuedCount;
  int get runningCount;

  /// Drop all pending tasks and signal all running ones. The owner calls this;
  /// subsystems that merely borrow the instance use [cancelGroup] instead.
  Future<void> dispose();
}

/// Cancellation signal handed to a running task. The scheduler never forcibly
/// stops a task — cancellation is cooperative. Created via a
/// [TaskCancelController]; the scheduler holds the controller, the task holds
/// the token (the StreamController/Stream split, so the task can't self-cancel).
class TaskCancelToken {
  TaskCancelToken._(this._controller);

  final TaskCancelController _controller;

  bool get isCancelled => _controller._cancelled;

  /// Completes when (and if) the task is cancelled. Never completes for a task
  /// that runs to completion uncancelled.
  Future<void> get onCancel => _controller._onCancel.future;
}

/// The write side of a [TaskCancelToken]. Held by the scheduler; [signal]
/// flips the paired [token] to cancelled.
class TaskCancelController {
  late final TaskCancelToken token = TaskCancelToken._(this);
  bool _cancelled = false;
  final Completer<void> _onCancel = Completer<void>();

  void signal() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_onCancel.isCompleted) _onCancel.complete();
  }
}
