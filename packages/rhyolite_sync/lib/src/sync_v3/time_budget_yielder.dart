/// Gives the host event loop a turn, but no more often than once per [budget]
/// of actual work.
///
/// dart2js shares Obsidian's single JS thread, so any loop over a vault has to
/// yield or the UI freezes for its duration. The question is how often, and
/// counting iterations answers it badly: the per-item cost is not uniform. In
/// one sweep a text file costs a set lookup and a binary file costs a `stat`;
/// in the startup scan a skipped file costs a stat and a changed one costs
/// sha256 over a megabyte. Any fixed stride is therefore both too eager on the
/// cheap items and too lazy on the expensive ones — with the same constant.
///
/// Yielding is not free either. `Future.delayed(Duration.zero)` compiles to
/// `setTimeout(_, 0)`, which browsers clamp to a few milliseconds once timers
/// nest, so every yield costs real wall clock whether or not there was
/// anything to paint. That is what makes a per-item yield expensive: it pays
/// the clamp for an item that ran in microseconds. Measuring work instead
/// spends that cost only where enough work happened to be worth it.
///
/// The default is a little under half a 60 Hz frame: long enough to amortise
/// the clamp, short enough that a frame is never missed by this loop alone.
///
/// Only yields BETWEEN calls — a single item that blocks for 500 ms cannot be
/// helped from here, and wants splitting instead.
class TimeBudgetYielder {
  TimeBudgetYielder({this.budget = const Duration(milliseconds: 8)});

  final Duration budget;
  final Stopwatch _sinceYield = Stopwatch()..start();

  /// Yields if [budget] has elapsed since the last yield, otherwise returns
  /// immediately. Cheap enough for the hot path: the fast path costs one
  /// microtask, against the clamped timer a real yield costs.
  Future<void> maybeYield() async {
    if (_sinceYield.elapsed < budget) return;
    // Reset before awaiting so the budget measures work, not the yield.
    _sinceYield.reset();
    await Future<void>.delayed(Duration.zero);
  }
}
