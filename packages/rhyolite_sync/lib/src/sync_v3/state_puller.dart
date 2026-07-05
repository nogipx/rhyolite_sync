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
      IStateConflictResolver resolver,
    ) applyFile,
    required Future<void> Function(int newEpoch) handleEpochMismatch,
    required void Function(SyncEngineEvent event) emit,
    required bool Function(Object error) isFatalRejection,
    required LogScope log,
  })  : _rpcTimeout = rpcTimeout,
        _getRemoteBlobStorage = getRemoteBlobStorage,
        _newResolver = newResolver,
        _applyFile = applyFile,
        _handleEpochMismatch = handleEpochMismatch,
        _emit = emit,
        _isFatalRejection = isFatalRejection,
        _log = log;

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
    IStateConflictResolver resolver,
  ) _applyFile;
  final Future<void> Function(int newEpoch) _handleEpochMismatch;
  final void Function(SyncEngineEvent event) _emit;
  final bool Function(Object error) _isFatalRejection;
  final LogScope _log;

  Future<void> pull() async {
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
          StateGetRequest(
            vaultId: vaultId,
            sinceCursor: store.serverCursor,
          ),
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
      return;
    }

    if (response.records.isEmpty) {
      store.setServerCursor(response.cursor);
      _adoptEpoch(response.epoch);
      // Pull was a no-op — don't flash the indicator; SyncPulling was
      // never emitted in this path.
      return;
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
    final fileIds = byFile.keys.toList();
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
    var slowFileCount = 0;
    var maxFileMs = 0;
    String? maxFilePath;
    var fileIdx = 0;

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

      swPrefetchTotal.start();
      final downloaded = await _prefetchBlobs(
        batchRecords,
        progressOffset: prefetched,
        progressTotal: totalMissing == 0 ? null : totalMissing,
      );
      prefetched += downloaded;
      swPrefetchTotal.stop();

      swApplyTotal.start();
      for (final fileId in batchFileIds) {
        fileIdx += 1;
        _log.info(
          'Pull: applying file $fileIdx/$totalFiles '
          'fileId=${fileId.substring(0, 8)}... '
          'records=${byFile[fileId]!.length}',
        );
        final swFile = Stopwatch()..start();
        try {
          await _applyFile(fileId, byFile[fileId]!, resolver);
        } catch (e) {
          // A fatal policy/auth rejection means every subsequent record
          // will fail the same way. Bubble it out so the top-level start()
          // catch can emit a typed event and stop the engine — without
          // this we burn the host event loop on per-file no-op work for
          // every record in the batch.
          if (_isFatalRejection(e)) rethrow;
          _log.warning('Skipping bad state records $fileId: $e');
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
        await Future<void>.delayed(Duration.zero);
      }
      swApplyTotal.stop();
    }

    if (totalMissing > 0) {
      _emit(
        SyncBlobDownloadDone(
          totalDownloaded: totalMissing,
          elapsed: swPrefetchTotal.elapsed,
        ),
      );
    }

    store.setServerCursor(response.cursor);
    _adoptEpoch(response.epoch);
    _emit(
      SyncCursorAdvanced(
        cursor: response.cursor,
        recordCount: response.records.length,
      ),
    );
    swPullTotal.stop();
    // Permanent breakdown log. Lets us spot regressions: if `apply` jumps
    // while `fetch` stays flat, the server is fine and we have a client-
    // side compute regression. `slowFiles` and `maxFile` flag individual
    // pathological files. Keep this line — every future "why did the
    // plugin start freezing on startup?" debug session begins here.
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

    // Tell the server this device has now processed up to response.cursor.
    // Best-effort — failure must not block sync. The server uses these
    // heads to keep history events safe from cleanup until every active
    // device has caught up.
    unawaited(_reportHistoryHead(response.cursor));
  }

  Future<void> _reportHistoryHead(int headSeq) async {
    try {
      await historyCaller.reportHistoryHead(
        ReportHistoryHeadRequest(
          vaultId: vaultId,
          deviceId: store.deviceId,
          headSeq: headSeq,
        ),
      );
    } catch (e) {
      _log.warning('reportHistoryHead failed: $e');
    }
  }

  /// Number of fileIds whose blobs are prefetched and applied together
  /// inside [pull]. See the interleaved pipeline block in [pull] for the
  /// trade-off (UI feedback vs per-batch atomicity).
  static const int _pullFileBatchSize = 8;

  /// Counts how many distinct blobRefs from [records] are not yet in the
  /// local cache. Used by [pull] to emit a stable progress total across
  /// interleaved prefetch batches.
  Future<int> _countMissingBlobRefs(List<StateRecord> records) async {
    if (records.isEmpty) return 0;
    final candidates = <String>{};
    for (final r in records) {
      if (r.tombstone) continue;
      if (r.blobRef.isEmpty) continue;
      candidates.add(r.blobRef);
    }
    if (candidates.isEmpty) return 0;
    var missing = 0;
    for (final ref in candidates) {
      final cached = await blobStore.read(ref, vaultId: vaultId);
      if (cached == null) missing += 1;
    }
    return missing;
  }

  /// Bulk-download blobs referenced by [records] that aren't already in
  /// the local cache. Returns the number of blobs newly downloaded.
  ///
  /// Internally chunks the work into HTTP batches of 8 (HttpBlobStorage
  /// fans each chunk into 8 parallel GETs).
  ///
  /// When called as a stand-alone prefetch (no [progressTotal]), emits its
  /// own start/done log lines and `SyncBlobDownloadProgress` against just
  /// this call's missing count.
  ///
  /// When called per-batch from the interleaved pipeline ([progressTotal]
  /// non-null), suppresses the standalone log/done emission and reports
  /// progress as `progressOffset + done / progressTotal` so the UI sees a
  /// single stable bar across the whole pull.
  Future<int> _prefetchBlobs(
    List<StateRecord> records, {
    int progressOffset = 0,
    int? progressTotal,
  }) async {
    if (records.isEmpty) return 0;
    final remote = _getRemoteBlobStorage();
    if (remote == null) return 0;

    // Collect candidate blob refs (skip tombstones + empty refs).
    final candidates = <String>{};
    for (final r in records) {
      if (r.tombstone) continue;
      if (r.blobRef.isEmpty) continue;
      candidates.add(r.blobRef);
    }
    if (candidates.isEmpty) return 0;

    // Filter out blobs we already have locally — no point re-fetching.
    final missing = <String>[];
    for (final ref in candidates) {
      final cached = await blobStore.read(ref, vaultId: vaultId);
      if (cached == null) missing.add(ref);
    }
    if (missing.isEmpty) return 0;

    final interleaved = progressTotal != null;
    final total = progressTotal ?? missing.length;
    if (!interleaved) {
      _log.info('Pull: prefetching ${missing.length} blob(s)…');
      _emit(SyncBlobDownloadProgress(completed: 0, total: total));
    }
    final swatch = Stopwatch()..start();
    const chunkSize = 8;
    var done = 0;
    for (var i = 0; i < missing.length; i += chunkSize) {
      final end = (i + chunkSize) > missing.length
          ? missing.length
          : (i + chunkSize);
      final chunk = missing.sublist(i, end);
      try {
        final downloaded = await remote.download(chunk);
        for (final entry in downloaded.entries) {
          await blobStore.write(
            entry.value,
            entry.key,
            vaultId: vaultId,
          );
        }
      } catch (e) {
        _log.warning('Pull: blob chunk download failed: $e');
      }
      done += chunk.length;
      _emit(
        SyncBlobDownloadProgress(
          completed: progressOffset + done,
          total: total,
        ),
      );
    }
    if (!interleaved) {
      _emit(
        SyncBlobDownloadDone(
          totalDownloaded: missing.length,
          elapsed: swatch.elapsed,
        ),
      );
      _log.info(
        'Pull: prefetched ${missing.length} blob(s) in ${swatch.elapsed.inSeconds}s',
      );
    }
    return missing.length;
  }

  bool _isEpochAhead(int serverEpoch, int? localEpoch) =>
      localEpoch != null && serverEpoch > localEpoch;

  void _adoptEpoch(int epoch) {
    if (store.serverEpoch == epoch) return;
    store.setServerEpoch(epoch);
  }
}
