import 'dart:async';

/// Coordinates per-path debounce for text-file edits.
///
/// The engine feeds two signals:
///   * [onDiskEvent] — a file save has landed; the next push needs a
///     reconcile against disk. Sets the per-path "has disk event" flag
///     and arms/extends the timer.
///   * [onTypingEvent] — the user pressed a key in [path]. Arms/extends
///     the timer without setting the disk-event flag, so a timer that
///     fires after typing-only ticks is a cheap no-op until a real
///     save lands.
///
/// When the timer fires:
///   * disk-event flag set → invokes [onReconcile] (the engine's
///     reconcile-and-push closure).
///   * flag unset → no-op; user typed but the editor hasn't saved yet.
///
/// Each path owns at most one [Timer]. State is bounded by the number
/// of paths edited within the debounce window — clears entirely on
/// [cancelAll].
class TextDebounceCoordinator {
  TextDebounceCoordinator({
    required this.debounce,
    required this.onReconcile,
  });

  /// Quiet period waited after the most recent disk or typing event.
  final Duration debounce;

  /// Invoked once per fired timer with a pending disk event. Errors
  /// raised here are caught and logged by the caller's closure.
  final Future<void> Function(String relPath) onReconcile;

  final Map<String, Timer> _timers = {};
  final Set<String> _hasDiskEvent = {};

  /// Visible for tests — number of paths currently being tracked.
  int get pendingCount => _timers.length;

  void onDiskEvent(String relPath) {
    _hasDiskEvent.add(relPath);
    _arm(relPath);
  }

  void onTypingEvent(String relPath) {
    _arm(relPath);
  }

  /// Drops any pending state for [relPath] — used when a delete or
  /// move supersedes a not-yet-flushed text edit.
  void forget(String relPath) {
    _timers.remove(relPath)?.cancel();
    _hasDiskEvent.remove(relPath);
  }

  /// Cancels every outstanding debounce. The coordinator stays usable
  /// — a subsequent [onDiskEvent] / [onTypingEvent] resumes scheduling.
  /// The engine guards against calling this on a stopped engine via
  /// its own `_running` flag and the reconcile callback's checks.
  void cancelAll() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _hasDiskEvent.clear();
  }

  void _arm(String relPath) {
    _timers.remove(relPath)?.cancel();
    _timers[relPath] = Timer(debounce, () async {
      _timers.remove(relPath);
      final hadDiskEvent = _hasDiskEvent.remove(relPath);
      if (!hadDiskEvent) return;
      await onReconcile(relPath);
    });
  }
}
