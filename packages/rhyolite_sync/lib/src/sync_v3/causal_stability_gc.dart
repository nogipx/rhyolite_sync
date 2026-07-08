import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import 'fugue_frontier.dart';

/// Aggregates per-device causal frontiers from the server, computes the
/// per-replica causal-stability boundary, and prunes every [Fugue] tree's
/// fully-tombstoned blocks that are dominated by that boundary.
///
/// **Conservative by design.** The block model already makes tombstones
/// cheap (a deleted paragraph is one block with a deleted range, not
/// thousands of nodes), so GC is far less urgent than it was for the
/// per-node Sequence. Under-pruning only costs a little memory;
/// over-pruning breaks convergence. Every uncertain case therefore skips.
///
/// The frontier is a **version vector over Fugue dots** (`Map<replica,
/// counter>`), not the old HLC [CausalContext]. A device reports the max
/// counter it has observed per replica; an element `(counter, replica)` is
/// stable once EVERY active device's report covers it. Boundaries are the
/// per-replica min across the reporting devices — for replicas that appear
/// in EVERY report. See [FugueFrontier] for the wire form and the
/// fail-safe on an unrecognised (old-format) frontier.
///
/// Owns three concerns the engine doesn't want to inline:
///   * Wall-clock throttle ([_lastRunAt] / [minInterval]) — the boundary
///     only advances when every device reports, so polling the heads
///     endpoint on every notify-driven micro-pull is wasteful.
///   * Stale-device exclusion — a device head older than [staleHeadAge]
///     is treated as abandoned to keep one long-offline peer from
///     blocking GC forever.
///   * Frontier intersection ([_minFrontier]) — per-replica min over the
///     reported version vectors, with explicit handling of empty/unknown
///     frontiers.
///
/// Idempotent: a block that was once pruned simply isn't there to find on
/// the next pass, and blocks with any live element (or a live descendant)
/// are never dropped.
class CausalStabilityGc {
  CausalStabilityGc({
    required this.vaultId,
    required FugueStore? Function() getFugueStore,
    required IHistoryContract? Function() getHistoryCaller,
    required void Function(String message) onInfo,
    required void Function(String message) onWarning,
    this.minInterval = const Duration(minutes: 1),
    this.staleHeadAge = const Duration(days: 90),
  }) : _getFugueStore = getFugueStore,
       _getHistoryCaller = getHistoryCaller,
       _onInfo = onInfo,
       _onWarning = onWarning;

  final String vaultId;
  final FugueStore? Function() _getFugueStore;
  final IHistoryContract? Function() _getHistoryCaller;
  final void Function(String message) _onInfo;
  final void Function(String message) _onWarning;

  /// Throttle: heads are fetched at most once per [minInterval].
  final Duration minInterval;

  /// Trade-off documented at field doc on the engine: a device that
  /// returns after its frontier expired can resurrect blocks that the
  /// quorum has already pruned (Fugue.join is union). The default is sized
  /// so ordinary vacations / travel don't trigger it.
  final Duration staleHeadAge;

  DateTime _lastRunAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> run() async {
    final fugueStore = _getFugueStore();
    final history = _getHistoryCaller();
    if (fugueStore == null || history == null) return;
    if (fugueStore.count == 0) return;

    final now = DateTime.now();
    if (now.difference(_lastRunAt) < minInterval) return;
    _lastRunAt = now;
    final swTotal = Stopwatch()..start();

    GetHistoryHeadsResponse heads;
    try {
      heads = await history.getHistoryHeads(
        GetHistoryHeadsRequest(vaultId: vaultId),
      );
    } catch (e) {
      _onWarning('heads fetch failed: $e');
      return;
    }

    final frontier = _minFrontier(heads.heads);
    if (frontier.isEmpty) return;

    var prunedFiles = 0;
    var droppedElements = 0;
    for (final fileId in fugueStore.fileIds.toList()) {
      final f = await fugueStore.get(fileId);
      if (f == null || f.elementCount == 0) continue;

      // Stable = every dot whose per-replica boundary dominates its counter.
      final stable = <Dot>{};
      for (final d in f.dots) {
        final boundary = frontier[d.replica];
        if (boundary == null) continue;
        if (d.counter <= boundary) stable.add(d);
      }
      if (stable.isEmpty) continue;

      final before = f.elementCount;
      final pruned = f.prune(stable);
      final after = pruned.elementCount;
      if (after == before) continue; // nothing was droppable

      fugueStore.set(fileId, pruned);
      await fugueStore.persistOne(fileId);
      prunedFiles += 1;
      droppedElements += before - after;
    }

    swTotal.stop();
    if (prunedFiles > 0 || swTotal.elapsedMilliseconds > 100) {
      _onInfo(
        'Fugue GC: dropped $droppedElements element(s) across '
        '$prunedFiles file(s) (heads=${heads.heads.length}, '
        'total=${swTotal.elapsedMilliseconds}ms)',
      );
    }
  }

  /// Per-replica min over the supplied [DeviceHead]s' version vectors.
  ///
  /// A dot `(counter, X)` is causally stable iff every active device has
  /// observed it — i.e. every device's frontier reports replica X with a
  /// counter ≥ `counter`. For each replica X present in EVERY frontier,
  /// returns the min counter across all devices. A replica missing from any
  /// device's report is dropped from the result — its boundary collapses to
  /// "unknown" (no pruning) until every peer confirms it.
  ///
  /// **Fail-safe.** A device whose `frontierPacked` is empty, unrecognised
  /// (old HLC format), or corrupt is treated as reporting an EMPTY vector:
  /// it shares no replica with anyone, so the intersection collapses and
  /// nothing is pruned during a mixed-version rollout. Devices whose
  /// `updatedAtMs` is older than [staleHeadAge] are skipped entirely.
  Map<String, int> _minFrontier(List<DeviceHead> heads) {
    if (heads.isEmpty) return const <String, int>{};
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final staleMs = staleHeadAge.inMilliseconds;
    final active = heads
        .where((h) => nowMs - h.updatedAtMs < staleMs)
        .toList();
    if (active.isEmpty) return const <String, int>{};

    final vvs = <Map<String, int>>[];
    for (final h in active) {
      // Unknown/old-format/corrupt → empty VV (fail-safe: blocks pruning).
      vvs.add(FugueFrontier.unpack(h.frontierPacked) ?? const <String, int>{});
    }

    Set<String>? common;
    for (final vv in vvs) {
      final ids = vv.keys.toSet();
      common = common == null ? ids : common.intersection(ids);
    }
    if (common == null || common.isEmpty) return const <String, int>{};

    final out = <String, int>{};
    for (final replica in common) {
      int? min;
      for (final vv in vvs) {
        final c = vv[replica]!;
        if (min == null || c < min) min = c;
      }
      out[replica] = min!;
    }
    return out;
  }
}
