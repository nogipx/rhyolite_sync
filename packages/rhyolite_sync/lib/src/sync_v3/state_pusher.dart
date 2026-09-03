import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

import 'package:rhyolite_core/rhyolite_core.dart';
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
    this.clientVersion,
    this.clientKind,
    required Duration rpcTimeout,
    required void Function(SyncEngineEvent event) emit,
    required Future<void> Function(int newEpoch) handleEpochMismatch,
    required void Function(Iterable<String> fileIds) clearPending,
    required LogScope log,
    Set<String> Function()? pendingFileIds,
  }) : _pendingFileIds = pendingFileIds ?? (() => const <String>{}),
       _rpcTimeout = rpcTimeout,
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
  final String? clientVersion;
  final String? clientKind;
  final Duration _rpcTimeout;
  final void Function(SyncEngineEvent event) _emit;
  final Future<void> Function(int newEpoch) _handleEpochMismatch;
  final void Function(Iterable<String> fileIds) _clearPending;

  /// The host's "unsent changes" set, read live.
  ///
  /// Scanned alongside the store's owed set for one reason: a file can be
  /// marked pending by a change event and then turn out to owe nothing — the
  /// reconcile found the content unchanged, so no register was written and the
  /// store never heard of it. The full-vault walk used to sweep those up as a
  /// side effect. Without them here the indicator would sit on "unsent
  /// changes" forever for a file that has none.
  final Set<String> Function() _pendingFileIds;
  final LogScope _log;

  /// Files the server rejected per-item, keyed by fileId → the exact blobRef
  /// that was rejected. Skipped by [_collectDirty] so we don't re-push the same
  /// over-limit record every cycle; a new version (different blobRef) retries.
  final Map<String, ({String blobRef, StatePutRejection rejection})> _rejected =
      {};

  /// fileId → signature of the last value this device successfully pushed. A
  /// push never advances the synced LCA (only _materialise / a sealed merge do),
  /// so without this guard the post-pull _push() re-collects the same value on
  /// every cycle; when the server echoes our own write back as a notify that
  /// re-triggers the pull, that is an unbounded push/notify/pull/push storm.
  ///
  /// The signature captures path + blobRef + tombstone — everything that makes a
  /// record meaningfully different to a peer. It must NOT be blobRef alone: a
  /// rename/move keeps identical content (same blobRef) but changes the path, so
  /// a blobRef-only guard would silently drop the rename (never pushed, and the
  /// file lingers in the pending set forever → stuck "pending" indicator).

  /// Identity of a pushed record for the [_lastPushed] guard: path + content +
  /// tombstone. HLC is deliberately excluded — it bumps on every mutation, and
  /// including it would defeat the guard and re-open the push storm.
  static String _signatureOf(FileState s) =>
      '${s.blobRef}\u0000${s.path}\u0000${s.tombstone}';

  /// Push every dirty file as one Δ-state TaggedValue per file.
  /// Files per putStates call.
  ///
  /// The push used to send everything in one request. That was invisible while
  /// a vault meant a hundred files — and fatal at nine thousand, because the
  /// server writes the items one at a time inside the call and the client
  /// gives it thirty seconds. A first sync would have timed out, kept every
  /// file dirty (the signature is only recorded on a response), and sent the
  /// same nine thousand again on the next attempt, burning a server seq apiece
  /// forever.
  ///
  /// The first fix put the batch at two hundred, on an estimate of "a couple
  /// of seconds of server work". A startup pass measured end to end says
  /// otherwise. Client and server logs of the same run, aligned (the server
  /// runs UTC, the device MSK):
  ///
  ///   21:23:59  the startup pass ends, push begins
  ///   21:24:24  server finishes the batch and logs `items=100`
  ///   21:24:24  client logs `push+persist 25425ms`
  ///
  /// So a hundred states cost about 25 seconds, or ~250ms each. What that
  /// number is NOT: server time. The server's line is written after its item
  /// loop, and there is no arrival log to subtract, so the 25 seconds covers
  /// collecting, encoding and encrypting 100 records, the round trip, the
  /// server's writes and `persistMeta` — and these logs cannot say how it
  /// divides. An earlier draft of this comment claimed the server was the slow
  /// part and that two hundred would blow the 30-second deadline. Neither is
  /// established: the deadline wraps only `putStates`, and the encode loop
  /// above it is not inside it.
  ///
  /// What the measurement does support is the size of the unbanked window. A
  /// batch is atomic to this client — the signature is recorded only on a
  /// response — so an interrupted batch banks nothing. Two hundred is fifty
  /// seconds of work to lose and fifty seconds before the server hears
  /// anything; fifty is around thirteen. The cost is round trips, and they are
  /// the cheap part: a first sync pays them alongside blob uploads that take
  /// minutes.
  ///
  /// Public so a test can express "one batch landed, the next did not" in
  /// terms of the batch rather than a number that silently stops meaning that.
  static const int pushBatchSize = 50;

  Future<void> push({RpcContext? context}) async {
    final caller = stateCaller;
    final token = context?.cancellationToken;

    final collected = _collectDirty();
    final dirty = collected.dirty;
    // Files whose current value we already pushed (signature match) owe the
    // server nothing — drop them from the engine's pending set so the "pending
    // changes" indicator clears even when there is nothing new to send. Without
    // this a no-op mutation (e.g. a rename there-and-back, or a re-marked but
    // unchanged file) would leave the fileId pending forever.
    if (collected.settled.isNotEmpty) _clearPending(collected.settled);
    if (dirty.isEmpty) return;

    // The total, once, so the indicator counts the work rather than the batch.
    _emit(SyncPushing(fileCount: dirty.length));
    var sent = 0;
    var batches = 0;
    var lastCursor = 0;

    for (var offset = 0; offset < dirty.length; offset += pushBatchSize) {
      final end = offset + pushBatchSize > dirty.length
          ? dirty.length
          : offset + pushBatchSize;
      final batch = dirty.sublist(offset, end);

      final items = <StatePutItem>[];
      for (final entry in batch) {
        token?.throwIfCancelled();
        items.add(await codec.encode(entry.state, entry.contextAtWrite));
      }

      token?.throwIfCancelled();
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
      for (final entry in batch) {
        final state = entry.state;
        final result = byId[state.fileId];
        if (result != null && result.rejected) {
          _rejected[state.fileId] = (
            blobRef: state.blobRef,
            rejection: result.rejection!,
          );
          _log.warning(
            'Push: server rejected '
            '(${result.rejection!.code} '
            '${result.rejection!.current}>${result.rejection!.limit}) — not '
            'synced; will retry only when the file changes',
            data: {'path': LogPath(state.path)},
          );
          continue;
        }
        _rejected.remove(state.fileId);
        // Written down before persistOne, which is the call that saves it. Held
        // per file rather than in the meta row, and NOT in lastSyncedBlobRef —
        // see the note below on why a push cannot advance the LCA.
        store.recordPushedSignature(state.fileId, _signatureOf(state));
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
      // Per batch, not once at the end. A batch that lands is banked: its
      // signatures are on their rows, so a later batch failing costs only
      // itself and the retry sends what is left rather than starting over.
      await store.persistMeta();

      sent += items.length;
      batches++;
      lastCursor = response.cursor;
    }

    _log.info(
      'Push: sent $sent item(s) in $batches batch(es), '
      'server cursor=$lastCursor',
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
          deviceName: clientName ?? '',
          clientVersion: clientVersion ?? '',
          clientKind: clientKind ?? '',
        ),
      );
    } catch (e) {
      _log.warning('frontier report failed: $e');
    }
  }

  /// Bundle of (state, context) for one item to push. The context is
  /// taken from the locally-stored TaggedValue at the moment the value
  /// was written — that's what the server's MvRegister.join needs.
  ({
    List<({FileState state, CausalContext contextAtWrite})> dirty,
    List<String> settled,
  })
  _collectDirty() {
    final dirty = <({FileState state, CausalContext contextAtWrite})>[];
    // Files the engine marked pending but that this pass will NOT push — because
    // nothing is owed to the server (already pushed, or not dirty). Reported so
    // push() drops them from the pending set: the "pending changes" indicator
    // must reflect what the engine will actually send, or it sticks amber
    // forever. A file the server REJECTED is deliberately NOT settled — it is
    // genuinely still owed and stays pending until its content changes.
    final settled = <String>[];
    // The candidates, not the vault.
    //
    // This walked every file on every push, which on a large vault meant nine
    // thousand examinations and as many signature strings for a single edit —
    // with the line that marked that one file pending sitting directly above
    // the call. The store now tracks what it has written since the server last
    // accepted it, so the walk is over what might actually owe something.
    //
    // The classification below is untouched: the set is a conservative
    // superset and every member still has to prove it is dirty here.
    for (final fileId in {...store.owedFileIds, ..._pendingFileIds()}) {
      final register = store.registerFor(fileId);
      if (register == null) {
        settled.add(fileId);
        continue;
      }

      final TaggedValue<FileState> tv;
      if (register.hasConflict) {
        // A conflicting register still owes the server THIS device's own
        // concurrent value. Usually it reaches the server via a standalone
        // push before the conflict forms — but a value absorbed into the
        // conflict by the pull's pre-join reconcile (an edit made inside the
        // pull window) or kept in a divergent multi-value union was never
        // published. Publish OUR value (the others came from the server
        // already) so peers can see it and render the same union.
        final own = register.values
            .where((t) => t.hlc.nodeId == store.deviceId)
            .toList(growable: false);
        if (own.isEmpty) {
          settled.add(fileId);
          continue;
        }
        tv = own.first;
      } else {
        tv = register.values.first;
      }

      final state = tv.value;

      // Already pushed this exact record (path + content + tombstone) and
      // nothing meaningful has changed since. A push deliberately never advances
      // the synced LCA (only _materialise / a sealed merge do), so isNew stays
      // isNew and a conflicting own-value stays owed; without this guard the
      // post-pull _push() re-collects the same value on every cycle and, when
      // the server echoes our own write back as a notify, loops unboundedly
      // (push/notify/pull/push). Keyed on the full signature, NOT blobRef alone,
      // so a rename/move (same content, new path) is still recognised as dirty.
      // Reported as settled so push() clears it from the pending indicator.
      //
      // Persisted, not in-memory. While this was a session-local map, a file
      // authored here and never pulled back was `isNew` again on every launch:
      // the server skips the insert when the HLC already matches, so nothing
      // came back to apply and nothing advanced the LCA. One vault re-sent 117
      // records at every startup, burning a seq apiece, forever.
      if (store.lastPushedSignatureFor(fileId) == _signatureOf(state)) {
        settled.add(fileId);
        continue;
      }

      final synced = store.lastSyncedBlobRefFor(fileId);
      final neverPushed = synced == null;
      final isNew = neverPushed && !state.tombstone;
      final isModified = synced != null && synced != state.blobRef;
      final isTombstoneToCommit = state.tombstone && synced != null;
      // A conflicting own-value is always a candidate — its "dirtiness" is
      // decided by the [_lastPushed] guard above, not the synced LCA (a
      // multi-value register never advances it).
      if (register.hasConflict || isNew || isModified || isTombstoneToCommit) {
        // Skip a file the server already rejected for this exact content —
        // don't re-push the same over-limit record every cycle. A new version
        // (different blobRef) clears the stale block and is retried. This file
        // is genuinely still owed, so it is NOT settled — it stays pending.
        final blocked = _rejected[fileId];
        if (blocked != null && blocked.blobRef == state.blobRef) continue;
        _rejected.remove(fileId);
        dirty.add((state: state, contextAtWrite: tv.context));
      } else {
        // Nothing owed for this file (e.g. a tombstone for a value the server
        // never confirmed, so it can't be committed). Clear any stale pending.
        settled.add(fileId);
      }
    }
    // Anything that proved it owes nothing leaves the set, so it is not
    // re-examined on the next push. Everything else stays until a push is
    // acknowledged for it.
    store.clearOwed(settled);
    // Anything that proved it owes nothing leaves the set, so the next push
    // does not examine it again. Everything else stays until a push for it is
    // acknowledged.
    store.clearOwed(settled);
    return (dirty: dirty, settled: settled);
  }

  void _adoptEpoch(int epoch) {
    if (store.serverEpoch == epoch) return;
    store.setServerEpoch(epoch);
  }
}
