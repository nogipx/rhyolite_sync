import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import 'fugue_frontier.dart';

/// Aggregates per-device heads from the server (one fetch, throttled) and does
/// two causal-stability sweeps off it:
///   * **Fugue text trees** — prunes fully-tombstoned blocks dominated by the
///     per-replica dot frontier (`min` over each device's Fugue version vector).
///   * **FileState tombstones** — reclaims deleted-file registers once every
///     active device's pull cursor (`headSeq`) has passed the tombstone's
///     serverSeq, i.e. the delete has propagated to all (`min(headSeq)` gate,
///     the same idiom BlobJanitor uses). Prevents unbounded tombstone growth
///     without ever resurrecting a delete a peer hasn't seen.
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
    required FileStateStore? Function() getStore,
    required IHistoryContract? Function() getHistoryCaller,
    required void Function(String message) onInfo,
    required void Function(String message) onWarning,
    this.minInterval = const Duration(minutes: 1),
    this.staleHeadAge = const Duration(days: 90),
    this.tombstoneBackfillMinAge = const Duration(hours: 24),
  }) : _getFugueStore = getFugueStore,
       _getStore = getStore,
       _getHistoryCaller = getHistoryCaller,
       _onInfo = onInfo,
       _onWarning = onWarning;

  final String vaultId;
  final FugueStore? Function() _getFugueStore;
  final FileStateStore? Function() _getStore;
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

  /// Minimum age of a tombstone before its UNKNOWN serverSeq is backfilled
  /// with the pull cursor (see the tombstone loop). Old tombstones (predating
  /// serverSeq tracking) are certainly confirmed/pulled-back, so the cursor is
  /// a safe upper bound; a just-created local delete not yet echoed from the
  /// server is younger than this and is left alone until its precise seq
  /// arrives on the next pull — otherwise the cursor could under-estimate its
  /// true seq and the delete could be reclaimed before a peer has seen it.
  final Duration tombstoneBackfillMinAge;

  DateTime _lastRunAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> run() async {
    final fugueStore = _getFugueStore();
    final history = _getHistoryCaller();
    if (fugueStore == null || history == null) return;
    final store = _getStore();

    // Anything to potentially GC? Fugue trees to prune OR tombstones to reclaim.
    // Both share the single heads fetch below — no extra RPC per cycle.
    final hasTombstones = store != null && store.tombstoneFileIds.isNotEmpty;
    if (fugueStore.count == 0 && !hasTombstones) return;

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

    // --- Fugue text-tree pruning (per-replica dot frontier) ---
    var prunedFiles = 0;
    var droppedElements = 0;
    final frontier = _minFrontier(heads.heads);
    if (fugueStore.count > 0 && frontier.isNotEmpty) {
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
    }

    // --- FileState tombstone pruning (min pull-cursor frontier) ---
    // Reuses the SAME heads fetch. A tombstone is dropped only once every
    // ACTIVE device's pull cursor (headSeq) has passed its serverSeq — i.e. the
    // delete has propagated to everyone, so the tombstone is no longer needed.
    // Conservative: an unknown serverSeq (locally-created delete not yet echoed
    // back) or a lagging device's low headSeq keeps the tombstone, so a delete
    // is never reclaimed before a peer has seen it (no resurrection).
    var prunedTombstones = 0;
    var metaDirty = false;
    if (store != null) {
      final minSafeHead = _minSafeHead(heads.heads);
      if (minSafeHead != null) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final backfillMinAgeMs = tombstoneBackfillMinAge.inMilliseconds;
        for (final fileId in store.tombstoneFileIds.toList()) {
          var seq = store.serverSeqFor(fileId);
          if (seq == null) {
            // A tombstone predating serverSeq tracking (the pre-fix backlog).
            // Backfill a SAFE upper bound — the current pull cursor — but only
            // once it's old enough to be certainly confirmed/pulled-back, so a
            // just-created local delete not yet echoed from the server isn't
            // reclaimed before a peer has seen it (see [tombstoneBackfillMinAge]
            // — the cursor would otherwise under-estimate a fresh own delete's
            // true seq). The precise seq arrives on the next pull regardless.
            final ts = store.get(fileId);
            if (ts == null) continue;
            if (nowMs - ts.hlc.millis < backfillMinAgeMs) continue;
            seq = store.serverCursor;
            store.recordServerSeq(fileId, seq);
            metaDirty = true;
          }
          if (seq > minSafeHead) continue;
          store.remove(fileId);
          // Drop the file's Fugue tree too — a tombstone doesn't need it, and
          // an orphan from a pre-fix remote delete would otherwise linger.
          await fugueStore.remove(fileId);
          await store.persistOne(fileId); // register now empty → row deleted
          prunedTombstones += 1;
          metaDirty = true;
        }
        // Persist the in-memory map changes (serverSeq backfills + removals).
        if (metaDirty) await store.persistMeta();
      }
    }

    swTotal.stop();
    if (prunedFiles > 0 ||
        prunedTombstones > 0 ||
        swTotal.elapsedMilliseconds > 100) {
      _onInfo(
        'Causal GC: dropped $droppedElements fugue element(s) across '
        '$prunedFiles file(s), $prunedTombstones tombstone(s) '
        '(heads=${heads.heads.length}, total=${swTotal.elapsedMilliseconds}ms)',
      );
    }
  }

  /// Smallest pull cursor (headSeq) across ACTIVE devices — the causal-
  /// stability boundary for FileState tombstones. A record with
  /// `serverSeq <= this` has been pulled (and applied, since headSeq is held
  /// below any un-applied record) by every active device. Devices whose head
  /// is older than [staleHeadAge] are excluded — the same abandoned-peer
  /// trade-off as the Fugue frontier. Returns null when no active device has
  /// reported (fail-safe: no pruning).
  int? _minSafeHead(List<DeviceHead> heads) {
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final staleMs = staleHeadAge.inMilliseconds;
    int? min;
    for (final h in heads) {
      if (nowMs - h.updatedAtMs >= staleMs) continue;
      if (min == null || h.headSeq < min) min = h.headSeq;
    }
    return min;
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
