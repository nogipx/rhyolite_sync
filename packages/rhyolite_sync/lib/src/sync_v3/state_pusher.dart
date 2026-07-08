import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

import 'fugue_frontier.dart';
import 'state_record_codec.dart';

/// Push-side mechanics for one sync session.
///
/// Collects dirty file states, encodes them via [StateRecordCodec], sends
/// one putStates batch, then persists/clears pending and reports the
/// device frontier. There is no OCC and no retry loop (doc §5.1): each
/// item carries the writer's HLC + CausalContext and the server's
/// MvRegister.join resolves dominance; the only batch-level rejection is
/// epoch mismatch, handed back to the engine via [_handleEpochMismatch].
///
/// Extracted from `StateSyncEngine`. Behavior is preserved verbatim,
/// including the deliberate choice NOT to advance the pull cursor on push.
class StatePusher {
  StatePusher({
    required this.stateCaller,
    required this.historyCaller,
    required this.store,
    required this.codec,
    required this.vaultId,
    required this.clientName,
    required Duration rpcTimeout,
    required void Function(SyncEngineEvent event) emit,
    required Future<void> Function(int newEpoch) handleEpochMismatch,
    required void Function(Iterable<String> fileIds) clearPending,
    required LogScope log,
  })  : _rpcTimeout = rpcTimeout,
        _emit = emit,
        _handleEpochMismatch = handleEpochMismatch,
        _clearPending = clearPending,
        _log = log;

  final IStateSyncContract stateCaller;
  final IHistoryContract historyCaller;
  final FileStateStore store;
  final StateRecordCodec codec;
  final String vaultId;
  final String? clientName;
  final Duration _rpcTimeout;
  final void Function(SyncEngineEvent event) _emit;
  final Future<void> Function(int newEpoch) _handleEpochMismatch;
  final void Function(Iterable<String> fileIds) _clearPending;
  final LogScope _log;

  /// Files the server rejected per-item, keyed by fileId → the exact blobRef
  /// that was rejected. Skipped by [_collectDirty] so we don't re-push the same
  /// over-limit record every cycle; a new version (different blobRef) retries.
  final Map<String, ({String blobRef, StatePutRejection rejection})> _rejected =
      {};

  /// Push every dirty file as one Δ-state TaggedValue per file.
  Future<void> push({RpcContext? context}) async {
    final caller = stateCaller;
    final token = context?.cancellationToken;

    final dirty = _collectDirty();
    if (dirty.isEmpty) return;

    final items = <StatePutItem>[];
    for (final entry in dirty) {
      token?.throwIfCancelled();
      items.add(await codec.encode(entry.state, entry.contextAtWrite));
    }

    token?.throwIfCancelled();
    _emit(SyncPushing(fileCount: items.length));
    final response = await caller
        .putStates(
          StatePutRequest(
            vaultId: vaultId,
            items: items,
            expectedEpoch: store.serverEpoch,
            sourceClientId: clientName,
          ),
          context: context,
        )
        .timeout(_rpcTimeout);

    if (response.epochMismatch) {
      _log.info('Push: epoch mismatch — forcing restore');
      await _handleEpochMismatch(response.epoch);
      return;
    }

    // Correlate per-item outcomes. A rejected item was NOT written server-side
    // (e.g. its record exceeds the size cap): it must not be reported as pushed
    // and must stop being re-pushed until the file changes.
    final byId = {for (final r in response.results) r.fileId: r};
    final accepted = <String>[];
    for (final entry in dirty) {
      final state = entry.state;
      final result = byId[state.fileId];
      if (result != null && result.rejected) {
        _rejected[state.fileId] =
            (blobRef: state.blobRef, rejection: result.rejection!);
        _log.warning(
          'Push: server rejected ${state.path} '
          '(${result.rejection!.code} '
          '${result.rejection!.current}>${result.rejection!.limit}) — not '
          'synced; will retry only when the file changes',
        );
        continue;
      }
      _rejected.remove(state.fileId);
      // Push does NOT update lastSyncedBlobRef. The field is consumed
      // by StateConflictResolver as the 3-way-merge BASE (= LCA across
      // devices), and a push doesn't establish convergence with anyone.
      // Two devices that push concurrently from independent starts
      // would each seed their OWN blob as "base" → resolver produces
      // different output per device → divergence + garbled rebases.
      //
      // The LCA is only known to be shared once a non-conflicting
      // remote pull lands (`_materialise`) or after the resolver seals
      // a conflict (`_applyOutcome`). Until then, `findHistoryBaseRef`
      // queries the server's history for a real common ancestor; if
      // none exists, the resolver falls back to LWW with conflict-copy,
      // which is convergent without needing a base.
      await store.persistOne(state.fileId);
      if (state.tombstone) {
        _emit(SyncFileDeleted(state.path));
      } else {
        _emit(SyncFilePushed(state.path));
      }
      accepted.add(state.fileId);
    }
    _clearPending(accepted);

    // IMPORTANT: do NOT advance store.serverCursor to response.cursor here.
    // response.cursor is the server's max seq, which includes records
    // written by OTHER devices between our last pull and this push. If we
    // advanced past those seqs we would skip them on the next pull and
    // never see them (unless notify happens to trigger a pull in time).
    // The next pull naturally fetches everything since the last
    // successful pull — including our own just-pushed records, which
    // applyRemote/join treats idempotently.
    _adoptEpoch(response.epoch);
    await store.persistMeta();

    _log.info(
      'Push: sent ${items.length} item(s), server cursor=${response.cursor}',
    );
    // History is written server-side as a side-effect of putStates.

    // Report our frontier so the server can compute the per-vault
    // causal-stability boundary used by tombstone GC (Phase 5). The
    // report carries the device's current ownContext and the pull
    // cursor; together they describe everything this device has
    // observed. Failure is non-fatal — it just delays GC.
    await _reportFrontier(headSeq: store.serverCursor);
  }

  Future<void> _reportFrontier({required int headSeq}) async {
    try {
      // The frontier is a version vector over FUGUE dots, not the HLC
      // ownContext (which tracks FileState registers, a different clock).
      // This conservative report carries only this device's own-replica
      // boundary — a correct lower bound that the GC intersects across all
      // devices. It's cheap (no per-file scan) and never over-prunes; a
      // fuller cross-replica vector is a safe future enhancement.
      final counter = store.fugueClockCounter;
      final frontier = counter > 0
          ? FugueFrontier.pack({store.deviceId: counter})
          : '';
      await historyCaller.reportHistoryHead(
        ReportHistoryHeadRequest(
          vaultId: vaultId,
          deviceId: store.deviceId,
          headSeq: headSeq,
          frontierPacked: frontier,
        ),
      );
    } catch (e) {
      _log.warning('frontier report failed: $e');
    }
  }

  /// Bundle of (state, context) for one item to push. The context is
  /// taken from the locally-stored TaggedValue at the moment the value
  /// was written — that's what the server's MvRegister.join needs.
  List<({FileState state, CausalContext contextAtWrite})> _collectDirty() {
    final dirty = <({FileState state, CausalContext contextAtWrite})>[];
    for (final fileId in store.fileIds) {
      final register = store.registerFor(fileId);
      if (register == null) continue;
      // Conflicting registers are NOT pushed — resolver collapses them
      // first (via applyLocal during _applyOutcome), and the resulting
      // single-value register IS pushed on the next cycle.
      if (register.hasConflict) continue;
      final tv = register.values.first;
      final state = tv.value;
      final synced = store.lastSyncedBlobRefFor(fileId);
      final neverPushed = synced == null;
      final isNew = neverPushed && !state.tombstone;
      final isModified = synced != null && synced != state.blobRef;
      final isTombstoneToCommit = state.tombstone && synced != null;
      if (isNew || isModified || isTombstoneToCommit) {
        // Skip a file the server already rejected for this exact content —
        // don't re-push the same over-limit record every cycle. A new version
        // (different blobRef) clears the stale block and is retried.
        final blocked = _rejected[fileId];
        if (blocked != null && blocked.blobRef == state.blobRef) continue;
        _rejected.remove(fileId);
        dirty.add((state: state, contextAtWrite: tv.context));
      }
    }
    return dirty;
  }

  void _adoptEpoch(int epoch) {
    if (store.serverEpoch == epoch) return;
    store.setServerEpoch(epoch);
  }
}
