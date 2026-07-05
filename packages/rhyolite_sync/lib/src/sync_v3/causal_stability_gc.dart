import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Aggregates per-device causal frontiers from the server, computes the
/// per-author causal-stability boundary, and prunes every Fugue
/// [Sequence]'s tombstones that are dominated by that boundary.
///
/// Owns three concerns the engine doesn't want to inline:
///   * Wall-clock throttle ([_lastRunAt] / [minInterval]) — the boundary
///     only advances when every device reports, so polling the heads
///     endpoint on every notify-driven micro-pull is wasteful.
///   * Stale-device exclusion — a device head older than [staleHeadAge]
///     is treated as abandoned to keep one long-offline peer from
///     blocking GC forever.
///   * Frontier intersection ([_minFrontier]) — set-theoretic min over
///     per-author HLCs, with explicit handling of empty/unreported
///     frontiers.
///
/// Idempotent: a tombstone that was once pruned simply isn't there to
/// find on the next pass, and live entries are never dropped (their
/// position metadata is required by their descendants).
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
  /// returns after its frontier expired can resurrect tombstones that
  /// the quorum has already pruned (Sequence.join is set-union). The
  /// default is sized so ordinary vacations / travel don't trigger it.
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
    if (frontier.entries.isEmpty) return;

    var prunedFiles = 0;
    var droppedTombstones = 0;
    for (final fileId in fugueStore.fileIds.toList()) {
      final seq = await fugueStore.get(fileId);
      if (seq == null || seq.entries.isEmpty) continue;

      final stable = <Hlc>{};
      for (final id in seq.entries.keys) {
        final boundary = frontier[id.nodeId];
        if (boundary == null) continue;
        if (id <= boundary) stable.add(id);
      }
      if (stable.isEmpty) continue;

      final pruned = seq.prune(DotSet.from(stable));
      if (identical(pruned, seq)) continue;

      fugueStore.set(fileId, pruned);
      await fugueStore.persistOne(fileId);
      prunedFiles += 1;
      droppedTombstones += seq.entries.length - pruned.entries.length;
    }

    swTotal.stop();
    if (prunedFiles > 0 || swTotal.elapsedMilliseconds > 100) {
      _onInfo(
        'Fugue GC: dropped $droppedTombstones tombstones across '
        '$prunedFiles file(s) (heads=${heads.heads.length}, '
        'total=${swTotal.elapsedMilliseconds}ms)',
      );
    }
  }

  /// Element-wise min over the supplied [DeviceHead]s' frontiers.
  ///
  /// A dot `d=(ms, cnt, X)` is causally stable iff every device has
  /// observed it — i.e., every device's frontier dominates `d` on
  /// author X. For each author X present in EVERY frontier, returns
  /// the min HLC across all devices. If any device has not reported a
  /// frontier yet (empty string) or hasn't observed author X at all,
  /// X is dropped — the boundary collapses to zero for that author
  /// until every peer checks in. Devices whose `updatedAtMs` is older
  /// than [staleHeadAge] are skipped entirely.
  CausalContext _minFrontier(List<DeviceHead> heads) {
    if (heads.isEmpty) return const CausalContext.empty();
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final staleMs = staleHeadAge.inMilliseconds;
    final active = heads
        .where((h) => nowMs - h.updatedAtMs < staleMs)
        .toList();
    if (active.isEmpty) return const CausalContext.empty();
    final ctxs = <CausalContext>[];
    for (final h in active) {
      if (h.frontierPacked.isEmpty) {
        ctxs.add(const CausalContext.empty());
        continue;
      }
      try {
        ctxs.add(CausalContext.unpack(h.frontierPacked));
      } catch (_) {
        ctxs.add(const CausalContext.empty());
      }
    }
    Set<String>? common;
    for (final ctx in ctxs) {
      final ids = ctx.entries.keys.toSet();
      common = common == null ? ids : common.intersection(ids);
    }
    if (common == null || common.isEmpty) {
      return const CausalContext.empty();
    }
    final out = <String, Hlc>{};
    for (final id in common) {
      Hlc? min;
      for (final ctx in ctxs) {
        final h = ctx[id]!;
        if (min == null || h < min) min = h;
      }
      out[id] = min!;
    }
    return CausalContext.from(out);
  }
}
