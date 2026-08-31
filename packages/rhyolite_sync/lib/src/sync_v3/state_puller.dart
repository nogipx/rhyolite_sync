import 'dart:async';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Pull-side transport mechanics for one sync session.
///
/// Owns the getStates fetch, the interleaved prefetch+apply pipeline,
/// per-batch blob prefetch, cursor/epoch advance and the best-effort
/// history-head report. The per-file apply (decode -> MvRegister join ->
/// conflict resolution -> disk write) is delegated back via [_applyFile]
/// — that cluster still lives on the engine and moves in a later step.
///
/// Extracted from `StateSyncEngine` so the pull loop can be reasoned about
/// and (via the engine's seams) tested in isolation. Behavior is preserved
/// verbatim, including the dart2js cooperative yields that keep the JS main
/// thread responsive during a large pull.
class StatePuller {
  StatePuller({
    required this.stateCaller,
    required this.historyCaller,
    required this.store,
    required this.blobStore,
    required this.vaultId,
    required Duration rpcTimeout,
    required IBlobStorage? Function() getRemoteBlobStorage,
    required IStateConflictResolver Function() newResolver,
    required Future<void> Function(
      String fileId,
      List<StateRecord> records,
      IStateConflictResolver resolver, {
      RpcContext? context,
    })
    applyFile,
    required Future<void> Function(int newEpoch) handleEpochMismatch,
    required void Function(SyncEngineEvent event) emit,
    required bool Function(Object error) isFatalRejection,
    required LogScope log,
    required Future<void> Function(
      List<String> blobRefs, {
      RpcContext? context,
      void Function(String manifestHash, int sent, int total)? onFileProgress,
    })
    prefetchFiles,
    required int downloadConcurrency,
    Future<bool> Function(StateRecord record)? shouldPrefetch,
    Future<String?> Function(StateRecord record)? pathOfRecord,
    String Function()? clientName,
    String clientVersion = '',
    String clientKind = '',
  }) : _rpcTimeout = rpcTimeout,
       _getRemoteBlobStorage = getRemoteBlobStorage,
       _newResolver = newResolver,
       _applyFile = applyFile,
       _handleEpochMismatch = handleEpochMismatch,
       _emit = emit,
       _isFatalRejection = isFatalRejection,
       _log = log,
       _prefetchFiles = prefetchFiles,
       _downloadConcurrency = downloadConcurrency,
       _shouldPrefetch = shouldPrefetch ?? ((_) async => true),
       _pathOfRecord = pathOfRecord ?? ((_) async => null),
       _clientName = clientName ?? (() => ''),
       _clientVersion = clientVersion,
       _clientKind = clientKind;

  final IStateSyncContract stateCaller;
  final IHistoryContract historyCaller;
  final FileStateStore store;
  final LocalBlobStore blobStore;
  final String vaultId;
  final Duration _rpcTimeout;
  final IBlobStorage? Function() _getRemoteBlobStorage;
  final IStateConflictResolver Function() _newResolver;
  final Future<void> Function(
    String fileId,
    List<StateRecord> records,
    IStateConflictResolver resolver, {
    RpcContext? context,
  })
  _applyFile;
  final Future<void> Function(int newEpoch) _handleEpochMismatch;
  final void Function(SyncEngineEvent event) _emit;
  final bool Function(Object error) _isFatalRejection;
  final LogScope _log;

  /// Max prefetch groups in flight at once.
  final int _downloadConcurrency;

  /// Warms the local blob cache for a whole batch of files at once, so the
  /// subsequent (serial) apply is an all-cache-hit assemble.
  ///
  /// Takes the batch rather than one file because the cost here is round
  /// trips, not bytes: per file it was a request for the manifest and then
  /// another for its chunks, and no amount of running four of those in
  /// parallel changes that 207 files cost 414 requests.
  final Future<void> Function(
    List<String> blobRefs, {
    RpcContext? context,
    void Function(String manifestHash, int sent, int total)? onFileProgress,
  })
  _prefetchFiles;

  /// Whether a record's content is worth pulling down at all — the device's
  /// folder/type filter, asked per record.
  ///
  /// The prefetch is the ONLY place the decision can save bandwidth: by the
  /// time [RemoteApplier] turns an out-of-scope file away, its blobs are
  /// already in the local cache. A record's path lives inside its encrypted
  /// payload, so answering this costs a decrypt — which is why the caller
  /// short-circuits to true when the filter is empty, the case every device
  /// without a filter is in. Omitted → everything is prefetched, the behaviour
  /// that shipped before the filters existed.
  final Future<bool> Function(StateRecord record) _shouldPrefetch;

  /// A record's path, for naming a transfer in the UI. Costs a decrypt, so it
  /// is asked only for files big enough that the silence would read as a hang.
  final Future<String?> Function(StateRecord record) _pathOfRecord;

  /// Below this, a file finishes before anyone could wonder whether it is
  /// stuck, and naming it would cost a decrypt per record for nothing.
  static const int _narrateAboveBytes = 1 << 20; // 1 MiB

  /// Human-readable device label reported with the head so the
  /// device-management UI can name this device.
  final String Function() _clientName;
  final String _clientVersion;
  final String _clientKind;

  /// In-memory per-file consecutive apply-failure counter, scoped to this
  /// session's puller. A file that throws during apply holds the cursor
  /// (so the next pull re-fetches and retries it) until it either succeeds
  /// (counter cleared) or reaches [_maxApplyAttempts] — at which point we
  /// advance past it and surface a durable [SyncRecordSkipped], so a
  /// genuinely-corrupt record can't stall every later record forever.
  /// Intentionally not persisted: a restart is a fine point to re-attempt.
  final Map<String, int> _applyAttempts = {};

  /// Consecutive failed apply attempts after which a file is skipped past
  /// (with a surfaced event) rather than blocking the cursor further.
  static const int _maxApplyAttempts = 5;

  /// Per-file apply lines kept before the rest are counted instead of logged.
  ///
  /// The same bound the startup scan already lives under, for the same reason:
  /// one line per file reads fine at 230 files and destroys the log at 9000.
  /// A real report came back 98% one INFO line, and two other faults had been
  /// evicted from it by the time anyone read it. A sample keeps what the line
  /// was for — seeing WHICH files, and how long each took — while the summary
  /// at the end carries the counts, which is the part that was ever true in
  /// bulk. Slow files are exempt below: those are the ones worth naming.
  static const int _maxApplySamples = 20;

  /// Returns the blob ids this pull touched — every record's manifest plus
  /// its chunks. The caller uses them to sweep just what was staged instead
  /// of the whole cache: prefetch writes downloaded chunks there to hand them
  /// to apply, and once apply has written the file the vault holds those bytes
  /// itself. Empty when the pull applied nothing.
  Future<Set<String>> pull({RpcContext? context}) async {
    final caller = stateCaller;

    final swPullTotal = Stopwatch()..start();
    _log.info('Pull: getStates sinceCursor=${store.serverCursor}');
    final swFetch = Stopwatch()..start();
    // Awaiter-level timeout only — RpcContext deadline cannot be used here
    // because it would tick during BearerTokenInterceptor's await on
    // ensureValidToken(), which itself can take 30+ seconds during a
    // refresh-with-backoff. The wire-hang case (silently-dead WebSocket
    // after resume) still surfaces as TimeoutException so the host's
    // visibility-change recovery can react.
    final response = await caller
        .getStates(
          StateGetRequest(vaultId: vaultId, sinceCursor: store.serverCursor),
        )
        .timeout(_rpcTimeout);
    swFetch.stop();
    _log.info(
      'Pull: getStates returned ${response.records.length} record(s) '
      'cursor=${response.cursor} epoch=${response.epoch} '
      'in ${swFetch.elapsedMilliseconds}ms',
    );

    if (_isEpochAhead(response.epoch, store.serverEpoch)) {
      _log.info('Pull: server epoch ahead, forcing restore');
      await _handleEpochMismatch(response.epoch);
      return const {};
    }

    if (response.records.isEmpty) {
      final prevCursor = store.serverCursor;
      final prevEpoch = store.serverEpoch;
      store.setServerCursor(response.cursor);
      _adoptEpoch(response.epoch);
      // Persist the advanced cursor/epoch even on an empty pull so it
      // survives a crash (otherwise a no-op pull re-fetches from the old
      // cursor next time). Skip the write when nothing actually moved.
      if (store.serverCursor != prevCursor || store.serverEpoch != prevEpoch) {
        await store.persistMeta();
      }
      // Pull was a no-op — don't flash the indicator; SyncPulling was
      // never emitted in this path.
      return const {};
    }

    // Real download starts here. Emit SyncPulling so the indicator
    // shows "down" — but only when there's actually data to apply,
    // not on every visibility-change probe.
    _emit(SyncPulling());

    final resolver = _newResolver();

    // Group records by fileId — a single fileId can carry multiple
    // surviving TaggedValues (multi-value MvRegister on the server).
    final byFile = <String, List<StateRecord>>{};
    for (final record in response.records) {
      byFile.putIfAbsent(record.fileId, () => []).add(record);
    }
    // Smallest-first ordering (text/small before large binaries). The records
    // are E2EE — the path/type isn't visible here — but the chunk-hash list is,
    // and chunk count is a faithful size proxy (text = 1 chunk, big binaries =
    // many). So the fast wins (notes) land first and a slow attachment can't
    // hold them up. Soft-priority only: an interactive edit still preempts.
    int chunkCount(String fid) =>
        byFile[fid]!.fold<int>(0, (n, r) => n + r.chunks.length);
    int maxSeq(String fid) =>
        byFile[fid]!.fold<int>(0, (m, r) => r.serverSeq > m ? r.serverSeq : m);
    // Ties break on serverSeq so the order is deterministic (Dart's sort is not
    // stable) and, among equal-size files, causal — same as the old order.
    final fileIds = byFile.keys.toList()
      ..sort((a, b) {
        final c = chunkCount(a).compareTo(chunkCount(b));
        return c != 0 ? c : maxSeq(a).compareTo(maxSeq(b));
      });
    final totalFiles = fileIds.length;

    // Pre-count missing blobs across the whole batch so progress events
    // can show a stable total even as we interleave prefetch with apply.
    final totalMissing = await _countMissingBlobRefs(response.records);
    if (totalMissing > 0) {
      _log.info(
        'Pull: prefetching $totalMissing blob(s) interleaved with apply, '
        'fileBatch=$_pullFileBatchSize',
      );
      _emit(SyncBlobDownloadProgress(completed: 0, total: totalMissing));
    }

    final swPrefetchTotal = Stopwatch();
    final swApplyTotal = Stopwatch();
    var prefetched = 0;
    var applySamples = 0;
    var slowFileCount = 0;
    var maxFileMs = 0;
    String? maxFilePath;
    var fileIdx = 0;
    final failedFileIds = <String>{};
    final applyYielder = TimeBudgetYielder();

    // Files whose records have not been applied yet. A file leaves only on a
    // successful apply, so a failed one keeps holding the cursor back — which
    // is what makes an early commit safe.
    final unapplied = Set<String>.from(fileIds);

    /// Commits the progress made so far.
    ///
    /// The cursor may advance to just below the smallest serverSeq still
    /// unapplied — never to the batch's own max, because [fileIds] is ordered
    /// by size rather than by seq and a later batch can hold a smaller one.
    ///
    /// Why per batch at all: the cursor used to be committed once, after the
    /// whole loop, while `throwIfCancelled` sits inside it and a pull is
    /// preemptible by design. An interactive edit arriving mid-pull therefore
    /// threw away every batch's progress even though the files were applied
    /// and persisted — and the next pull re-downloaded the identical records,
    /// which on a big vault is what "the counter resets and sync starts over"
    /// looked like. Cheap now that the meta row no longer carries a map per
    /// file.
    Future<void> commitProgress() async {
      int? minUnapplied;
      for (final fid in unapplied) {
        for (final r in byFile[fid]!) {
          if (minUnapplied == null || r.serverSeq < minUnapplied) {
            minUnapplied = r.serverSeq;
          }
        }
      }
      final safe = minUnapplied == null ? response.cursor : minUnapplied - 1;
      // Monotone. Nothing here may walk the cursor backwards: an applied file
      // has left [unapplied], so the bound only ever rises.
      if (safe <= store.serverCursor) return;
      store.setServerCursor(safe);
      await store.persistMeta();
    }

    // Interleaved pipeline: for each batch of fileIds, prefetch only that
    // batch's blobs, then apply the batch, then move on. UI sees the first
    // files appear within seconds instead of after the whole vault was
    // prefetched (was up to 122s on a 184-blob restore — see logs from
    // 2026-06-12). Atomicity is preserved per-batch: a network drop during
    // a batch's prefetch leaves the prior batches' files fully applied and
    // the failed batch wholly skipped (idempotent on next pull).
    for (
      var batchStart = 0;
      batchStart < fileIds.length;
      batchStart += _pullFileBatchSize
    ) {
      final batchEnd = batchStart + _pullFileBatchSize > fileIds.length
          ? fileIds.length
          : batchStart + _pullFileBatchSize;
      final batchFileIds = fileIds.sublist(batchStart, batchEnd);
      final batchRecords = <StateRecord>[];
      for (final fid in batchFileIds) {
        batchRecords.addAll(byFile[fid]!);
      }

      // Cooperative preemption point: an interactive edit can cancel this
      // pull (see StateSyncEngine.triggerPull). Bail before spending the next
      // batch's network/compute so the lane frees for the push; the engine
      // re-schedules the pull to finish later.
      context?.cancellationToken?.throwIfCancelled();

      swPrefetchTotal.start();
      final downloaded = await _prefetchBlobs(
        batchRecords,
        progressOffset: prefetched,
        progressTotal: totalMissing == 0 ? null : totalMissing,
        context: context,
      );
      prefetched += downloaded;
      swPrefetchTotal.stop();

      swApplyTotal.start();
      for (final fileId in batchFileIds) {
        fileIdx += 1;
        if (++applySamples <= _maxApplySamples) {
          _log.info(
            'Pull: applying file $fileIdx/$totalFiles '
            'fileId=${fileId.substring(0, 8)}... '
            'records=${byFile[fileId]!.length}',
          );
        }
        final swFile = Stopwatch()..start();
        try {
          // Inside the try, so a preemption arriving mid-batch reaches the
          // handler below and commits what this batch already applied.
          context?.cancellationToken?.throwIfCancelled();
          await _applyFile(fileId, byFile[fileId]!, resolver, context: context);
          // Success ends any prior failure streak for this file.
          _applyAttempts.remove(fileId);
          unapplied.remove(fileId);
        } catch (e) {
          // Preemption/cancellation aborts the WHOLE pull — it must not be
          // recorded as a per-file failure (that would advance-past or
          // hold-retry a file we simply chose to defer). Re-throw so the
          // engine's triggerPull catches it and re-schedules the pull, but
          // bank the progress first: discarding it is what made a preempted
          // pull re-download everything it had already applied.
          if (e is RpcCancelledException) {
            await commitProgress();
            rethrow;
          }
          // A fatal policy/auth rejection means every subsequent record
          // will fail the same way. Bubble it out so the top-level start()
          // catch can emit a typed event and stop the engine — without
          // this we burn the host event loop on per-file no-op work for
          // every record in the batch.
          if (_isFatalRejection(e)) rethrow;
          // Transient/per-file failure: remember it so the cursor logic
          // below can hold-and-retry instead of skipping it forever.
          failedFileIds.add(fileId);
          _log.warning('Deferring bad state records $fileId: $e');
        }
        swFile.stop();
        if (swFile.elapsedMilliseconds > maxFileMs) {
          maxFileMs = swFile.elapsedMilliseconds;
          maxFilePath = fileId;
        }
        if (swFile.elapsedMilliseconds > 200) {
          slowFileCount += 1;
        }
        // Cooperative yield to the host event loop. dart2js shares the JS
        // main thread with Obsidian; without this every fileId's compute
        // chain (decode + reconcile + materialise) runs back-to-back and
        // freezes the UI for the duration of the pull.
        //
        // Budgeted, not per file: this used to pay a clamped setTimeout for
        // every record, including the ones that applied in microseconds
        // because disk already held them — which on a full-vault pull is
        // thousands of timers bought for nothing.
        await applyYielder.maybeYield();
      }
      swApplyTotal.stop();
      await commitProgress();
    }

    if (totalMissing > 0) {
      _emit(
        SyncBlobDownloadDone(
          totalDownloaded: totalMissing,
          elapsed: swPrefetchTotal.elapsed,
        ),
      );
    }

    // In-pull retry: a per-file apply failure is often transient (a momentary
    // IO error, or an apply that raced a just-finished blob write). Retry the
    // failed files once more within THIS pull — after a yield so any pending
    // microtask (e.g. an in-flight cache write) can settle — so the common
    // case is corrected in the same sync cycle instead of waiting for the
    // next pull. Only failures that survive fall through to the cross-pull
    // hold-and-retry below.
    if (failedFileIds.isNotEmpty) {
      await Future<void>.delayed(Duration.zero);
      final stillFailed = <String>{};
      for (final fid in failedFileIds) {
        try {
          context?.cancellationToken?.throwIfCancelled();
          await _applyFile(fid, byFile[fid]!, resolver, context: context);
          _applyAttempts.remove(fid);
          unapplied.remove(fid);
        } catch (e) {
          if (e is RpcCancelledException) {
            await commitProgress();
            rethrow;
          }
          if (_isFatalRejection(e)) rethrow;
          stillFailed.add(fid);
          _log.warning('In-pull retry still failing $fid: $e');
        }
      }
      failedFileIds
        ..clear()
        ..addAll(stillFailed);
    }

    // A file that failed to apply must not be silently skipped by advancing
    // the cursor past it (getStates(sinceCursor) never re-emits it). Hold
    // the cursor just below the lowest failed record so the next pull
    // re-fetches and retries it — bounded by [_maxApplyAttempts] so a
    // genuinely-corrupt record can't stall every later record forever.
    var effectiveCursor = response.cursor;
    if (failedFileIds.isNotEmpty) {
      final retrySeqs = <int>[];
      for (final fid in failedFileIds) {
        final attempts = (_applyAttempts[fid] ?? 0) + 1;
        if (attempts >= _maxApplyAttempts) {
          // Give up: advance past it, but surface the drop durably.
          _applyAttempts.remove(fid);
          for (final r in response.records) {
            if (r.fileId != fid) continue;
            _emit(
              SyncRecordSkipped(
                fileId: fid,
                hlcPacked: r.hlcPacked,
                reason:
                    'apply failed $_maxApplyAttempts times — '
                    'skipped to unblock sync',
              ),
            );
          }
          _log.warning(
            'Pull: giving up on $fid after $_maxApplyAttempts failed '
            'attempts — advancing past it',
          );
        } else {
          _applyAttempts[fid] = attempts;
          for (final r in response.records) {
            if (r.fileId == fid) retrySeqs.add(r.serverSeq);
          }
        }
      }
      if (retrySeqs.isNotEmpty) {
        final minRetrySeq = retrySeqs.reduce((a, b) => a < b ? a : b);
        final holdCursor = minRetrySeq - 1;
        if (holdCursor < effectiveCursor) {
          effectiveCursor = holdCursor;
          _log.warning(
            'Pull: holding cursor at $effectiveCursor (from '
            '${response.cursor}) to retry ${retrySeqs.length} record(s) '
            'from failed file(s)',
          );
        }
      }
    }

    // Never below what the batches already committed — see [commitProgress].
    if (effectiveCursor > store.serverCursor) {
      store.setServerCursor(effectiveCursor);
    }
    _adoptEpoch(response.epoch);
    // Persist cursor + ownContext + recorded LCAs now, at the pull's
    // convergence point. Register rows are persisted per-file (persistOne),
    // but the meta row used to be written only by a later push/housekeeping
    // — a crash in that window left the persisted registers ahead of a
    // stale meta (ownContext behind the register, cursor and the binary
    // resolver base rolled back). See sync_v3_lca_semantics.
    await store.persistMeta();
    _emit(
      SyncCursorAdvanced(
        cursor: effectiveCursor,
        recordCount: response.records.length,
      ),
    );
    swPullTotal.stop();
    // Permanent breakdown log. Lets us spot regressions: if `apply` jumps
    // while `fetch` stays flat, the server is fine and we have a client-
    // side compute regression. `slowFiles` and `maxFile` flag individual
    // pathological files. Keep this line — every future "why did the
    // plugin start freezing on startup?" debug session begins here.
    if (applySamples > _maxApplySamples) {
      _log.info(
        'Pull: ${applySamples - _maxApplySamples} more per-file line(s) '
        'withheld — the counts below are the whole picture',
      );
    }
    _log.info(
      'Pull: applied ${response.records.length} record(s) across '
      '$totalFiles file(s), cursor=${store.serverCursor}, '
      'fetch=${swFetch.elapsedMilliseconds}ms '
      'prefetch=${swPrefetchTotal.elapsedMilliseconds}ms '
      'apply=${swApplyTotal.elapsedMilliseconds}ms '
      'total=${swPullTotal.elapsedMilliseconds}ms '
      'slowFiles(>200ms)=$slowFileCount '
      'maxFile=${maxFileMs}ms (${maxFilePath ?? 'n/a'})',
    );
    // Terminal signal — flips the indicator out of sticky pulling state
    // via _setWithRevert in the host. fileId/path empty by design: this
    // is a "pull complete" sentinel, not a per-file event.
    _emit(SyncFilePulled(fileId: '', nodeCount: response.records.length));

    // Tell the server this device has now processed up to effectiveCursor
    // (which may be held below response.cursor while a failed file retries).
    // Best-effort — failure must not block sync. The server uses these
    // heads to keep history events safe from cleanup until every active
    // device has caught up; reporting the held (lower) cursor is the
    // conservative choice.
    unawaited(_reportHistoryHead(effectiveCursor));

    return <String>{
      for (final r in response.records) ...[
        if (r.blobRef.isNotEmpty) r.blobRef,
        ...r.chunks,
      ],
    };
  }

  Future<void> _reportHistoryHead(int headSeq) async {
    try {
      await historyCaller.reportHistoryHead(
        ReportHistoryHeadRequest(
          vaultId: vaultId,
          deviceId: store.deviceId,
          headSeq: headSeq,
          deviceName: _clientName(),
          clientVersion: _clientVersion,
          clientKind: _clientKind,
        ),
      );
    } catch (e) {
      _log.warning('reportHistoryHead failed: $e');
    }
  }

  /// Number of fileIds whose blobs are prefetched and applied together
  /// inside [pull]. See the interleaved pipeline block in [pull] for the
  /// trade-off (UI feedback vs per-batch atomicity).
  /// Files per interleaved prefetch+apply step.
  ///
  /// Raised from 8 once prefetch started batching: the round trips a step
  /// costs no longer scale with it (one request for the step's manifests, one
  /// for its chunks, spread over [_prefetchGroupSize] concurrent groups), so a
  /// small step just meant more sequential steps. It still bounds how much
  /// work is done before the first files appear.
  static const int _pullFileBatchSize = 32;

  /// Files per prefetch REQUEST inside a step. The step is fetched as several
  /// of these at once: batching alone made each request fatter and therefore
  /// slower, and with only one in flight that lost more than it saved —
  /// measured, 255 blobs went from 39 s to 74 s. Fat requests AND overlap.
  static const int _prefetchGroupSize = 8;

  /// Counts how many distinct blobRefs from [records] are not yet in the
  /// local cache. Used by [pull] to emit a stable progress total across
  /// interleaved prefetch batches.
  /// Distinct files with content to prefetch in [records] (non-tombstone,
  /// non-empty ref) — drives the pull's progress total. A cached file still
  /// counts; its parallel prefetch is just a fast cache hit.
  Future<int> _countMissingBlobRefs(List<StateRecord> records) async =>
      (await _prefetchableRefs(records)).length;

  /// Distinct blobRefs in [records] this device actually wants: content-bearing
  /// (non-tombstone, non-empty ref) AND admitted by the device's filter. Shared
  /// by the progress total and the prefetch itself so the bar counts what will
  /// really be fetched.
  Future<Set<String>> _prefetchableRefs(List<StateRecord> records) async {
    final echoed = _selfEchoedFileIds(records);
    final refs = <String>{};
    for (final r in records) {
      if (r.tombstone || r.blobRef.isEmpty) continue;
      if (echoed.contains(r.fileId)) continue;
      if (!await _shouldPrefetch(r)) continue;
      refs.add(r.blobRef);
    }
    return refs;
  }

  /// Files whose incoming records are this device's own work coming back.
  ///
  /// A pass publishes its states, the server gives them cursor positions, and
  /// the next pull hands them straight back. Nothing in them is new here, and
  /// the apply proves it: the join collapses to the value already held, and
  /// materialise stops at the guard that recognises content already on disk.
  /// The bytes were fetched and then never read.
  ///
  /// Safe only because that guard exists. Skipping the prefetch without it
  /// does not remove the download — it moves it into the apply, one file at a
  /// time instead of a batch, which is six times the round trips.
  ///
  /// Requiring a single local value keeps this in step with the apply side. A
  /// register already holding two versions is a real conflict, its resolver
  /// does need every side's blob, and it is left alone.
  Set<String> _selfEchoedFileIds(List<StateRecord> records) {
    final byFile = <String, List<StateRecord>>{};
    for (final r in records) {
      byFile.putIfAbsent(r.fileId, () => []).add(r);
    }
    final echoed = <String>{};
    for (final entry in byFile.entries) {
      final register = store.registerFor(entry.key);
      if (register == null || register.values.length != 1) continue;
      final held = register.values.first.value;
      if (held.blobRef.isEmpty) continue;
      final allHeld = entry.value.every(
        (r) => r.blobRef == held.blobRef && r.tombstone == held.tombstone,
      );
      if (allHeld) echoed.add(entry.key);
    }
    return echoed;
  }

  /// Prefetch the CONTENT of every file in [records] (manifest + chunks) into
  /// the local blob cache, running up to [_downloadConcurrency] file downloads
  /// in parallel. The subsequent (serial) apply then assembles from cache with
  /// no network — this replaces the previous one-blob-at-a-time-over-a-single-
  /// stream download that dominated a full restore. Returns the file count.
  ///
  /// Stand-alone (no [progressTotal]): emits its own start/done log +
  /// `SyncBlobDownloadProgress`. Interleaved ([progressTotal] non-null): reports
  /// `progressOffset + done / progressTotal` so the UI shows one stable bar
  /// across the whole pull, suppressing the standalone log/done.
  Future<int> _prefetchBlobs(
    List<StateRecord> records, {
    int progressOffset = 0,
    int? progressTotal,
    RpcContext? context,
  }) async {
    if (records.isEmpty) return 0;
    if (_getRemoteBlobStorage() == null) return 0; // offline — nothing to fetch
    final refs = await _prefetchableRefs(records);
    if (refs.isEmpty) return 0;

    final interleaved = progressTotal != null;
    final total = progressTotal ?? refs.length;
    if (!interleaved) {
      _log.info('Pull: prefetching ${refs.length} file(s)…');
      _emit(SyncBlobDownloadProgress(completed: 0, total: total));
    }
    final swatch = Stopwatch()..start();

    // Each group is one request for its manifests and one for its chunks;
    // several groups run at once. Both halves matter: batching cuts the number
    // of round trips, overlap keeps the link busy while any one of them is in
    // flight. Progress steps per group rather than per file — the round trips
    // saved are what the user was actually waiting on.
    final list = refs.toList();
    final groups = <List<String>>[
      for (var i = 0; i < list.length; i += _prefetchGroupSize)
        list.sublist(
          i,
          i + _prefetchGroupSize > list.length
              ? list.length
              : i + _prefetchGroupSize,
        ),
    ];
    // Records by the blob they carry, so a progress report keyed by manifest
    // hash can be named. Only consulted above [_narrateAboveBytes].
    final recordOfRef = <String, StateRecord>{
      for (final r in records)
        if (r.blobRef.isNotEmpty) r.blobRef: r,
    };
    final namedRefs = <String, String>{};
    final concurrency = _downloadConcurrency.clamp(1, groups.length);
    await boundedParallel(groups, concurrency, (group) async {
      context?.cancellationToken?.throwIfCancelled();
      try {
        await _prefetchFiles(
          group,
          context: context,
          onFileProgress: (ref, sent, total) {
            if (total < _narrateAboveBytes) return;
            final known = namedRefs[ref];
            if (known != null) {
              _emitTransfer(known, sent, total);
              return;
            }
            final record = recordOfRef[ref];
            if (record == null) return;
            // Fire-and-forget: the decrypt must not hold up the transfer it
            // is describing, and a later report for the same file will find
            // the name cached.
            unawaited(
              _pathOfRecord(record).then((path) {
                if (path == null || path.isEmpty) return;
                namedRefs[ref] = path;
                _emitTransfer(path, sent, total);
              }, onError: (_) {}),
            );
          },
        );
      } catch (e) {
        // A preempted pull must abort so the lane frees for the push; every
        // other failure stays best-effort — each file's apply hold-and-retries.
        if (e is RpcCancelledException) rethrow;
        _log.warning('Pull: prefetch failed for ${group.length} file(s): $e');
      }
    });
    _emit(
      SyncBlobDownloadProgress(
        completed: (progressOffset + refs.length).clamp(0, total),
        total: total,
      ),
    );

    if (!interleaved) {
      _emit(
        SyncBlobDownloadDone(
          totalDownloaded: refs.length,
          elapsed: swatch.elapsed,
        ),
      );
      _log.info(
        'Pull: prefetched ${refs.length} file(s) in '
        '${swatch.elapsed.inSeconds}s',
      );
    }
    return refs.length;
  }

  void _emitTransfer(String path, int sent, int total) => _emit(
    SyncBlobTransfer(
      path: path,
      upload: false,
      sentBytes: sent,
      totalBytes: total,
      done: false,
    ),
  );

  bool _isEpochAhead(int serverEpoch, int? localEpoch) =>
      localEpoch != null && serverEpoch > localEpoch;

  void _adoptEpoch(int epoch) {
    if (store.serverEpoch == epoch) return;
    store.setServerEpoch(epoch);
  }
}
