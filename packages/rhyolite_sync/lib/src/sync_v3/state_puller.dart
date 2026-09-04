import 'dart:async';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rhyolite_core/rhyolite_core.dart';

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

    /// Asked before each batch is staged: is there room in the local database?
    ///
    /// The pull is the only thing that grows it now, so this is where the
    /// question belongs. A false answer does not stop the pull — see
    /// `StateSyncEngine._relieveDatabasePressure` for why.
    Future<bool> Function()? relievePressure,

    /// Awaited once a batch is banked, so the host can make it durable BEFORE
    /// the next batch starts writing.
    ///
    /// Awaited, not fired and forgotten, and that is the whole design. On a
    /// host whose storage drains on the same event loop this pull runs on,
    /// there is no such thing as a durability barrier that does not stop the
    /// pull: the drain needs an idle loop, and the pull is what makes it busy.
    /// Four flushes were observed starting and none finishing across a
    /// four-minute pull applying thirty files a second — and the timers
    /// themselves ran 24 to 47 seconds late, which is the same starvation seen
    /// from the other end.
    Future<void> Function()? checkpoint,

    /// Opens and closes the batch's in-memory transit area — see [BlobStaging].
    /// Paired: the pull opens before it fetches and closes once the batch is
    /// applied, and nothing between those two points may assume otherwise.
    void Function()? openStaging,
    void Function()? closeStaging,
    Future<bool> Function(StateRecord record)? shouldPrefetch,
    Future<String?> Function(StateRecord record)? pathOfRecord,

    /// Can the apply side prove, without fetching, that the file on disk
    /// already holds [blobRef]? See [_selfEchoedFileIds] for why the prefetch
    /// may not skip a file this answers no for. Omitted → nothing is treated
    /// as provable, which costs a batched prefetch and never correctness.
    bool Function(String fileId, String blobRef)? diskProvablyHolds,
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
       _relievePressure = relievePressure,
       _checkpoint = checkpoint,
       _openStaging = openStaging,
       _closeStaging = closeStaging,
       _shouldPrefetch = shouldPrefetch ?? ((_) async => true),
       _pathOfRecord = pathOfRecord ?? ((_) async => null),
       _diskProvablyHolds = diskProvablyHolds ?? ((_, _) => false),
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

  final Future<bool> Function()? _relievePressure;

  final Future<void> Function()? _checkpoint;

  final void Function()? _openStaging;
  final void Function()? _closeStaging;

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

  /// The apply side's own skip guard, asked in advance. In-memory only (a
  /// signature lookup), so it is safe to ask once per file in a pull.
  final bool Function(String fileId, String blobRef) _diskProvablyHolds;

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

  /// How long a batch waits for the host to make it durable.
  ///
  /// Generous, because the wait is the feature and a slow drain is still
  /// progress. Bounded because a host whose drain never completes would
  /// otherwise stop the pull forever, which is worse than the risk it was
  /// added to remove.
  static const Duration _checkpointTimeout = Duration(seconds: 30);


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
    int minSeq(String fid) => byFile[fid]!.fold<int>(
      1 << 62,
      (m, r) => r.serverSeq < m ? r.serverSeq : m,
    );
    // WITHIN A WINDOW of adjacent seqs, not across the whole response — and
    // that bound is what lets the cursor move.
    //
    // [commitProgress] can only advance to just below the smallest seq still
    // unapplied. Sorted globally by size, the response's lowest seq can sit at
    // the very end of the order, so the cursor stands still for the entire
    // pull however many files land: one real report applied every one of 9078
    // records across two passes and persisted a cursor of 61. A restart then
    // re-fetched all of them.
    //
    // Windowing keeps both properties. Inside a window notes still precede
    // attachments, which is the whole point of the size sort; between windows
    // the order is causal, so finishing one releases the cursor past it. The
    // window is several apply batches wide so a commit still covers real work
    // rather than firing per batch.
    //
    // Ties break on serverSeq so the order is deterministic (Dart's sort is not
    // stable) and, among equal-size files, causal — same as the old order.
    final fileIds = byFile.keys.toList()
      ..sort((a, b) => minSeq(a).compareTo(minSeq(b)));
    for (var start = 0; start < fileIds.length; start += _pullSeqWindowSize) {
      final end = start + _pullSeqWindowSize > fileIds.length
          ? fileIds.length
          : start + _pullSeqWindowSize;
      final window = fileIds.sublist(start, end)
        ..sort((a, b) {
          final c = chunkCount(a).compareTo(chunkCount(b));
          return c != 0 ? c : maxSeq(a).compareTo(maxSeq(b));
        });
      fileIds.setRange(start, end, window);
    }
    final totalFiles = fileIds.length;

    // Pre-count missing blobs across the whole batch so progress events
    // can show a stable total even as we interleave prefetch with apply.
    final totalMissing = await _countMissingBlobRefs(response.records);
    // How much of this response we already hold, which is what decides whether
    // a re-pull is cheap or a re-download of the vault.
    //
    // The two numbers are NOT the same question and reading one as the other
    // cost a diagnosis: `prefetching N` counts refs not filtered out, and says
    // nothing about how many of those the local cache already has. `held`
    // counts files whose register matches the incoming record — the state that
    // survived the last run. A pull that fetches the same records with
    // `held=0` every time is a durability problem; one with `held` high is
    // just a cursor that cannot advance, which is cheap and expected.
    final alreadyHeld = _selfEchoedFileIds(response.records).length;
    if (totalMissing > 0) {
      _log.info(
        'Pull: prefetching $totalMissing blob(s) interleaved with apply, '
        'fileBatch=$_pullFileBatchSize, held=$alreadyHeld/$totalFiles',
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
      if (safe > store.serverCursor) {
        store.setServerCursor(safe);
        await store.persistMeta();
      }
      // Announced whether or not the cursor moved, and that is the point.
      //
      // The host drains its write queue on this — see [SyncPullBatchApplied].
      // Hanging that on the cursor instead would have hung it on almost
      // nothing: files are applied smallest-first, the cursor is bounded by
      // the lowest unapplied serverSeq, and the two orders are unrelated, so
      // the cursor can stand still through a whole vault's worth of applied
      // files. Those files' register rows are banked and are what makes the
      // next pull cheap; losing them is what made an interrupted sync start
      // over.
      _emit(SyncPullBatchApplied(cursor: store.serverCursor));
      // AWAITED. The pull stops here while the host makes the batch durable,
      // and stopping is the point rather than a cost to be minimised: the
      // host's drain runs on the loop this pull saturates, so an unawaited
      // barrier is one that can never complete. Bounded and best-effort — a
      // drain that fails or hangs must not end the pull, it only means this
      // batch is at risk like every batch used to be.
      final checkpoint = _checkpoint;
      if (checkpoint != null) {
        try {
          await checkpoint().timeout(_checkpointTimeout);
        } catch (e) {
          _log.warning('Pull: checkpoint did not complete: $e');
        }
      }
    }

    // Interleaved pipeline: for each batch of fileIds, prefetch only that
    // batch's blobs, then apply the batch, then move on. UI sees the first
    // files appear within seconds instead of after the whole vault was
    // prefetched (was up to 122s on a 184-blob restore — see logs from
    // 2026-06-12). Atomicity is preserved per-batch: a network drop during
    // a batch's prefetch leaves the prior batches' files fully applied and
    // the failed batch wholly skipped (idempotent on next pull).
    // Batched by COUNT, and bounded in MEMORY by the staging area itself.
    //
    // Sizing the batch by bytes here was tried and reverted the same hour: a
    // record carries a chunk list but not a size, so the only bound available
    // in advance is chunk-count times the chunker's maximum — and a note is one
    // chunk of a few kilobytes counted as four megabytes. Batches came out six
    // files long, the pull ran five times slower for no memory saved, and it
    // was visible from outside as files arriving one at a time.
    //
    // So the estimate is gone and the real limit sits where the real sizes
    // are: [BlobStaging] stops accepting once it is full, and the prefetch
    // stops warming. Files past that point are fetched by the apply itself.
    var batchStart = 0;
    while (batchStart < fileIds.length) {
      final batchEnd = batchStart + _pullFileBatchSize > fileIds.length
          ? fileIds.length
          : batchStart + _pullFileBatchSize;
      final batchFileIds = fileIds.sublist(batchStart, batchEnd);
      batchStart = batchEnd;
      final batchRecords = <StateRecord>[];
      for (final fid in batchFileIds) {
        batchRecords.addAll(byFile[fid]!);
      }
      // Everything this batch fetches lives here until it has been applied.
      _openStaging?.call();

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
        // Per file, and BEFORE the work rather than after: a file that takes
        // three seconds is exactly the one during which the user is looking at
        // the indicator, and reporting on completion leaves it frozen for the
        // whole of it. The log line below is sampled and this is not — the
        // sample exists to keep the log readable, and a progress bar that
        // updates twenty times and then stops is worse than one that does not
        // exist.
        _emit(SyncPullProgress(applied: fileIdx, total: totalFiles));
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
      // Before the checkpoint, not after: the batch is on disk and in the
      // store, so these bytes are now the only copy of nothing. Holding them
      // across a drain that may take seconds is holding the peak twice.
      _closeStaging?.call();
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

  /// How many files the smallest-first sort may reorder across.
  ///
  /// The size sort and the cursor want opposite things: the sort wants the
  /// whole response to choose from, the cursor can only advance over a
  /// contiguous run of applied seqs. This is the seam between them, and its
  /// value is the trade — eight apply batches wide, so a commit still covers
  /// real work, and small enough that a 9000-file pull banks its progress
  /// thirty-odd times instead of once at the very end (which, when a restart
  /// arrived first, meant never).
  static const int _pullSeqWindowSize = _pullFileBatchSize * 8;

  /// Files per prefetch REQUEST inside a step. The step is fetched as several
  /// of these at once: batching alone made each request fatter and therefore
  /// slower, and with only one in flight that lost more than it saved —
  /// measured, 255 blobs went from 39 s to 74 s. Fat requests AND overlap.
  static const int _prefetchGroupSize = 8;

  /// Files whose content may be in flight at once, across all groups.
  ///
  /// Stated rather than emerging. It used to be the product of two constants
  /// chosen for unrelated reasons — the group size, picked to amortise round
  /// trips, times `downloadConcurrency`, which is wired from
  /// `startupUploadConcurrency` and is a decision about UPLOADS. Multiplying
  /// them gave 16 on mobile and 32 on desktop, and nobody had decided either
  /// number.
  ///
  /// A ceiling on files, not on requests, because that is what the far side
  /// and the link actually feel: a BYO WebDAV serving 32 concurrent transfers
  /// of a megabyte each is the case that stalls.
  static const int _maxFilesInFlight = 16;

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
  /// Safe only because that guard exists — and ONLY for the files it can
  /// actually answer for, which is why [_diskProvablyHolds] is asked here
  /// rather than assumed. Skipping the prefetch for a file the apply cannot
  /// skip does not remove the download; it moves it into the apply, one file
  /// at a time instead of a batch, which is six times the round trips.
  ///
  /// That is not hypothetical. The startup scan used to record its signatures
  /// without a blobRef, so the apply guard could never fire for a binary it
  /// had skipped — while the register test below said "echo" for all 9078 of
  /// them. The result was a finished first sync followed by a serial
  /// re-download of the entire vault to compare every file against itself.
  /// The register knows what this device HOLDS; only the signature knows what
  /// is on DISK, and the two must agree before any fetch is skipped.
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
      if (!allHeld) continue;
      // A tombstone materialises to a delete and never reads bytes, so there
      // is nothing for the disk guard to vouch for.
      if (!held.tombstone && !_diskProvablyHolds(entry.key, held.blobRef)) {
        continue;
      }
      echoed.add(entry.key);
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
    // Before the batch, not per group: staging is what fills the database, and
    // one check per batch is the granularity at which anything can be done
    // about it.
    await _relievePressure?.call();

    // Whichever binds first: the host's own limit, or the file ceiling above.
    final byFiles = _maxFilesInFlight ~/ _prefetchGroupSize;
    final concurrency = (_downloadConcurrency < byFiles
            ? _downloadConcurrency
            : byFiles)
        .clamp(1, groups.length);
    // The pull's quiet phase, named because it was silent for minutes.
    //
    // A batch's whole fetch used to produce one line, AFTER it finished. On a
    // vault holding 16 MB attachments over a BYO backend that is two and a
    // half minutes in which the log says nothing and the file counter — which
    // counts APPLIED files, and nothing has been applied — stands still. The
    // reading from outside is "it is stuck", and there was no line to say
    // otherwise.
    final swFetch = Stopwatch()..start();
    _log.info(
      'Pull: fetching ${refs.length} blob(s) for this batch, '
      '$concurrency group(s) in flight',
    );
    var fetchedInBatch = 0;
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
      // Per GROUP, not once the whole batch has landed. A batch of large
      // files takes minutes, and reporting only at the end of it is reporting
      // nothing for the part anyone would want to watch.
      fetchedInBatch += group.length;
      _emit(
        SyncBlobDownloadProgress(
          completed: (progressOffset + fetchedInBatch).clamp(0, total),
          total: total,
        ),
      );
    });
    swFetch.stop();
    // Close out everything this batch opened, whatever became of it.
    //
    // Reporting completion is not enough on its own: a transfer that FAILED —
    // a refusal, a 404, the idle bound cutting a dead connection — never
    // reaches its total, so its last report says `done: false` and the entry
    // outlives the fetch. One such entry is enough to hold the status at
    // "syncing" indefinitely. The batch's fetch is over here by definition,
    // so nothing it opened may still be open.
    for (final path in namedRefs.values) {
      _emit(
        SyncBlobTransfer(
          path: path,
          upload: false,
          sentBytes: 0,
          totalBytes: 0,
          done: true,
        ),
      );
    }
    _log.info(
      'Pull: fetched ${refs.length} blob(s) in ${swFetch.elapsedMilliseconds}ms',
    );
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

  /// Reports a file's transfer, and says when it is over.
  ///
  /// `done` was hard-coded false here, so the prefetch opened a transfer for
  /// every file above the narration threshold and closed none of them. The
  /// status is folded from `engineBusy || hasOpenTransfers || settingsBusy`,
  /// so a single unclosed entry holds the whole plugin at "syncing" for a
  /// vault that finished minutes ago — observed after a pull that had logged
  /// `applied 966 record(s)` and stopped.
  void _emitTransfer(String path, int sent, int total) => _emit(
    SyncBlobTransfer(
      path: path,
      upload: false,
      sentBytes: sent,
      totalBytes: total,
      done: total > 0 && sent >= total,
    ),
  );

  bool _isEpochAhead(int serverEpoch, int? localEpoch) =>
      localEpoch != null && serverEpoch > localEpoch;

  void _adoptEpoch(int epoch) {
    if (store.serverEpoch == epoch) return;
    store.setServerEpoch(epoch);
  }
}
