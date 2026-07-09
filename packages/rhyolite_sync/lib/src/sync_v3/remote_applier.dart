import 'dart:convert';

import 'package:convergent/convergent.dart' hide Dot;
import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

import 'disk_reconciler.dart';
import 'state_record_codec.dart';
import 'text_union_merge.dart';

/// Applies pulled records for one fileId onto local state and disk.
///
/// Owns the per-file apply pipeline the puller delegates to: decode →
/// pre-join disk reconcile → `MvRegister.join` → dispatch (single value /
/// Fugue text-conflict / binary resolver) → materialise → seal. This is
/// the correctness-critical heart of the pull side; behavior is preserved
/// verbatim from `StateSyncEngine`.
class RemoteApplier {
  RemoteApplier({
    required this.store,
    required this.fugueStore,
    required this.reconciler,
    required this.codec,
    required this.blobStore,
    required this.io,
    required this.changeProvider,
    required this.vaultId,
    required this.vaultPath,
    required ChunkedBlobIO? Function() newChunkedIO,
    required Set<String> Function() collectKnownChunks,
    required void Function(SyncEngineEvent event) emit,
    required bool Function(Object error) isFatalRejection,
    required LogScope log,
  }) : _newChunkedIO = newChunkedIO,
       _collectKnownChunks = collectKnownChunks,
       _emit = emit,
       _isFatalRejection = isFatalRejection,
       _log = log;

  final FileStateStore store;
  final FugueStore fugueStore;
  final DiskReconciler reconciler;
  final StateRecordCodec codec;
  final LocalBlobStore blobStore;
  final IPlatformIO io;
  final IChangeProvider changeProvider;
  final String vaultId;
  final String vaultPath;
  final ChunkedBlobIO? Function() _newChunkedIO;
  final Set<String> Function() _collectKnownChunks;
  final void Function(SyncEngineEvent event) _emit;
  final bool Function(Object error) _isFatalRejection;
  final LogScope _log;

  /// Apply all TaggedValues received for one fileId. Performs
  /// `localRegister.join(remoteRegister)` via [FileStateStore.applyRemote]
  /// then either writes the canonical single value to disk or invokes the
  /// resolver on the multi-value register (doc §5.2, §6).
  ///
  /// Per-record decode errors (corrupted row, wrong key, schema mismatch)
  /// are isolated: the bad record is logged and skipped, every healthy
  /// record for the same fileId still applies. Without this isolation a
  /// single bad row would freeze sync for the whole file forever
  /// (`cursor` never advances past the bad record on subsequent pulls).
  Future<void> apply(
    String fileId,
    List<StateRecord> records,
    IStateConflictResolver resolver,
  ) async {
    final swApply = Stopwatch()..start();
    final swDecodeSum = Stopwatch();
    final tagged = <TaggedValue<FileState>>[];
    var decodedSinceYield = 0;
    for (final r in records) {
      try {
        swDecodeSum.start();
        tagged.add(await codec.decode(r));
        swDecodeSum.stop();
      } catch (e) {
        swDecodeSum.stop();
        // Per-record decode failures are usually isolated (corrupted
        // row, wrong key, schema mismatch) — skip and continue. But a
        // policy/auth refusal hits every record identically, so bail
        // out instead of logging hundreds of identical "skipped" lines
        // and grinding through compute the engine should not be doing.
        if (_isFatalRejection(e)) rethrow;
        _log.warning(
          'Skipping unreadable record fileId=${r.fileId} '
          'hlc=${r.hlcPacked} seq=${r.serverSeq}: $e',
        );
        _emit(
          SyncRecordSkipped(
            fileId: r.fileId,
            hlcPacked: r.hlcPacked,
            reason: '$e',
          ),
        );
      }
      decodedSinceYield += 1;
      if (decodedSinceYield >= 4) {
        decodedSinceYield = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (tagged.isEmpty) {
      swApply.stop();
      // Even the all-skipped path is worth logging — it's the signal that
      // a whole file's records failed (e.g. cipher race, schema break).
      _log.info(
        'apply fileId=$fileId records=${records.length} tagged=0 '
        'decode=${swDecodeSum.elapsedMilliseconds}ms '
        'total=${swApply.elapsedMilliseconds}ms result=all-skipped',
      );
      return;
    }

    // Reconcile the local register with disk BEFORE joining remote.
    // Otherwise an in-flight user edit (watcher's handler hasn't reached
    // `applyLocal` yet) is invisible to `applyRemote`; the join then
    // treats the incoming remote as the single-value winner and the
    // disk write that follows silently overwrites the user's edit.
    final swPreReconcile = Stopwatch();
    final knownPath =
        store.get(fileId)?.path ??
        tagged
            .map((tv) => tv.value.path)
            .firstWhere((p) => p.isNotEmpty, orElse: () => '');
    // Pre-join reconcile exists for ONE reason: capture local edits
    // (in-flight watcher-save, or offline-accumulated user changes
    // since last sync) BEFORE merging with remote. Otherwise the
    // disk-write step at the end overwrites the user's work.
    //
    // That reason only applies when this device has a FileState for
    // this fileId — i.e. it has been tracking the file. If
    // `store.get(fileId)` is null, the engine has never seen this
    // file, so there is by definition no in-flight or offline-
    // accumulated local edit to capture; running reconcile here just
    // creates a phantom local FileState (seeded from whatever happens
    // to be on disk under this device's HLC) that is then guaranteed
    // to look concurrent with the incoming remote, forcing every
    // first-pull file through `_resolveTextConflict` — observed cost
    // 1.5-6s per file × N files = minutes wasted on every post-wipe
    // recovery.
    //
    // Files where disk content genuinely differs from remote (e.g.
    // user edited externally between sync sessions on a never-before-
    // seen file) are caught by [StateStartupDiff] right after the
    // pull completes — that scan is the architecturally correct place
    // for the "is this file new to the engine but already on disk?"
    // question.
    if (knownPath.isNotEmpty && store.get(fileId) != null) {
      _log.info(
        'apply preReconcile begin fileId=${fileId.substring(0, 8)} '
        'path=$knownPath',
      );
      swPreReconcile.start();
      try {
        await reconciler.reconcileWithDisk(knownPath);
      } catch (e) {
        // Same rationale as the per-record decode catch: a policy/auth
        // rejection here will fire on every file in the batch, freezing
        // the host with hundreds of redundant attempts. Bail.
        if (_isFatalRejection(e)) rethrow;
        _log.warning('Pre-join reconcile failed for $fileId ($knownPath): $e');
      }
      swPreReconcile.stop();
      _log.info(
        'apply preReconcile end '
        'fileId=${fileId.substring(0, 8)} '
        'took=${swPreReconcile.elapsedMilliseconds}ms',
      );
    }

    final swApplyRemote = Stopwatch()..start();
    final joined = store.applyRemote(
      fileId,
      tagged,
      onSkip: (tv, _) => _emit(
        SyncRecordSkipped(
          fileId: fileId,
          hlcPacked: tv.hlc.pack(),
          reason: 'hlc.millis exceeds skew bound',
        ),
      ),
    );
    swApplyRemote.stop();
    _emit(
      SyncRegisterJoined(
        fileId: fileId,
        incomingCount: tagged.length,
        finalCardinality: joined.values.length,
      ),
    );
    if (joined.values.isEmpty) {
      swApply.stop();
      _log.info(
        'apply fileId=$fileId path=$knownPath records=${records.length} '
        'tagged=${tagged.length} '
        'decode=${swDecodeSum.elapsedMilliseconds}ms '
        'preReconcile=${swPreReconcile.elapsedMilliseconds}ms '
        'applyRemote=${swApplyRemote.elapsedMilliseconds}ms '
        'total=${swApply.elapsedMilliseconds}ms result=empty',
      );
      return;
    }
    if (!joined.hasConflict) {
      final swMaterialise = Stopwatch()..start();
      await _materialise(joined.singleValue!);
      await store.persistOne(fileId);
      swMaterialise.stop();
      swApply.stop();
      // Full per-file breakdown. Every freeze-investigation starts here:
      // grep `apply ` → find the file that ate the most ms → drill into
      // its `fugue materialise ...` line for decode/project split.
      _log.info(
        'apply fileId=$fileId path=$knownPath records=${records.length} '
        'tagged=${tagged.length} '
        'decode=${swDecodeSum.elapsedMilliseconds}ms '
        'preReconcile=${swPreReconcile.elapsedMilliseconds}ms '
        'applyRemote=${swApplyRemote.elapsedMilliseconds}ms '
        'materialise=${swMaterialise.elapsedMilliseconds}ms '
        'total=${swApply.elapsedMilliseconds}ms result=single',
      );
      return;
    }

    // Multi-value register → real concurrent divergence. Resolver collapses
    // back to a single FileState and sets register cardinality to 1.
    _emit(
      SyncConflictAppeared(fileId: fileId, valueCount: joined.values.length),
    );

    // Text path: CRDT `join` over all concurrent Sequences — lossless
    // and convergent by construction. No 3-way merge, no conflict-copy
    // file, no LCA needed. The binary resolver below is left untouched
    // for files that don't go through Fugue.
    final conflictPath = joined.allValues
        .map((s) => s.path)
        .firstWhere((p) => p.isNotEmpty, orElse: () => '');
    if (conflictPath.isNotEmpty &&
        const FileTypeDetector().isText(conflictPath)) {
      final swResolve = Stopwatch()..start();
      await _resolveTextConflict(fileId, joined);
      await store.persistOne(fileId);
      swResolve.stop();
      swApply.stop();
      _log.info(
        'apply fileId=$fileId path=$conflictPath records=${records.length} '
        'tagged=${tagged.length} '
        'decode=${swDecodeSum.elapsedMilliseconds}ms '
        'preReconcile=${swPreReconcile.elapsedMilliseconds}ms '
        'applyRemote=${swApplyRemote.elapsedMilliseconds}ms '
        'resolveText=${swResolve.elapsedMilliseconds}ms '
        'total=${swApply.elapsedMilliseconds}ms result=text-conflict',
      );
      return;
    }

    final baseRef = store.lastSyncedBlobRefFor(fileId);
    final swResolveBinary = Stopwatch()..start();
    final outcome = await resolver.resolve(joined.allValues, baseRef: baseRef);
    await _applyOutcome(fileId, outcome, joined);
    await store.persistOne(fileId);
    swResolveBinary.stop();
    swApply.stop();
    _log.info(
      'apply fileId=$fileId path=$conflictPath records=${records.length} '
      'tagged=${tagged.length} '
      'decode=${swDecodeSum.elapsedMilliseconds}ms '
      'preReconcile=${swPreReconcile.elapsedMilliseconds}ms '
      'applyRemote=${swApplyRemote.elapsedMilliseconds}ms '
      'resolveBinary=${swResolveBinary.elapsedMilliseconds}ms '
      'total=${swApply.elapsedMilliseconds}ms result=binary-conflict',
    );
  }

  /// Resolves a multi-value text register, choosing the strategy by whether
  /// the concurrent versions share genuine causal history:
  ///
  ///   * **Shared history** (ordinary concurrent edits over a common base) —
  ///     char-level Fugue `join`. Lossless AND a true lattice join, so the
  ///     result is sealed back as a single dominating value (CRDT-safe:
  ///     associative). This is the headline "конфликты невозможны" path.
  ///   * **No shared history** (independent seeds, post-reseed, repair) — a
  ///     char-join would silently drop colliding seed dots, so instead the
  ///     register is LEFT multi-valued (a genuine MV-register that converges)
  ///     and a deterministic line-union VIEW is rendered to the single file.
  ///     It collapses only when the user makes a dominating edit. No
  ///     conflict-copy file, no data loss.
  Future<void> _resolveTextConflict(
    String fileId,
    MvRegister<FileState> joined,
  ) async {
    final chunkedIO = _newChunkedIO();
    if (chunkedIO == null) return;

    // Real (non-tombstone, content-bearing) concurrent values we must
    // account for. If any of these can't be downloaded, resolving now
    // would drop that side.
    final realValues = joined.allValues
        .where((s) => !s.tombstone && s.blobRef.isNotEmpty)
        .toList(growable: false);

    final sequences = <Fugue<String>>[];
    String? path;
    for (final state in joined.allValues) {
      if (state.path.isNotEmpty) path = state.path;
      if (state.tombstone || state.blobRef.isEmpty) continue;
      Uint8List? bytes;
      try {
        bytes = await chunkedIO.download(state.blobRef);
      } catch (e) {
        _log.warning('Conflict download failed for $fileId: $e');
      }
      if (bytes == null) continue;
      // decode is sync compute; yield before each so multi-version
      // conflicts don't pin the main thread.
      await Future<void>.delayed(Duration.zero);
      final decoded = reconciler.tryDecodeFugueBlob(bytes);
      if (decoded != null) {
        sequences.add(decoded);
      } else if (FugueStore.isLegacySequenceBlob(bytes)) {
        // A concurrent side still in the old Sequence format (peer not yet
        // upgraded). We cannot merge it losslessly. Leave it out — the
        // `sequences.length < realValues.length` guard below then defers the
        // whole conflict, keeping the register multi-valued so no side is
        // dropped until every blob is reachable in the new format.
        _log.warning(
          'Deferring text conflict for $fileId: legacy Sequence blob present',
        );
        continue;
      } else {
        // Genuine plain-text blob — seed deterministically.
        sequences.add(
          FugueTextSync.seedFromText(utf8.decode(bytes, allowMalformed: true)),
        );
      }
    }

    final winnerPath = path ?? joined.allValues.first.path;

    // A concurrent side whose blob we could not retrieve must never be
    // collapsed away: sealing the surviving subset (or tombstoning when
    // every real blob is unreachable) would drop it permanently. Leave the
    // register multi-valued so a later pull — once the blob is reachable —
    // resolves it losslessly. This mirrors the binary resolver's
    // no-silent-loss guarantee on the text path.
    if (sequences.length < realValues.length) {
      _log.warning(
        'Deferring text conflict for $fileId: '
        '${realValues.length - sequences.length}/${realValues.length} '
        'concurrent blob(s) unreachable — register kept multi-valued',
      );
      return;
    }

    if (sequences.isEmpty) {
      // All surviving values are tombstones (or all blobs unreachable).
      // Tombstone the register so peers see a consistent delete.
      final hlc = store.nextHlc();
      store.applyLocal(
        FileState(
          fileId: fileId,
          path: winnerPath,
          blobRef: '',
          sizeBytes: 0,
          hlc: hlc,
          tombstone: true,
        ),
      );
      fugueStore.set(fileId, Fugue<String>());
      await fugueStore.persistOne(fileId);
      final fullPath = '$vaultPath/$winnerPath';
      if (winnerPath.isNotEmpty && await io.fileExists(fullPath)) {
        changeProvider.suppress(winnerPath);
        await io.deleteFile(fullPath);
        _emit(SyncFileDeleted(winnerPath));
      }
      store.recordSyncedBlobRef(fileId, '');
      _emit(
        SyncConflictResolved(
          fileId: fileId,
          strategy: 'fugue-tombstone',
          winnerBlobRef: '',
        ),
      );
      return;
    }

    // No shared causal history between divergent versions → render a
    // deterministic line-union VIEW over the retained multi-value register.
    // The register is NOT collapsed: it stays a CRDT MV-register and
    // converges; the union is its single-file projection.
    if (sequences.length >= 2 && !sharesGenuineHistory(sequences)) {
      final union = deterministicLineUnion([
        for (final s in sequences) s.values.join(),
      ]);
      final wrote = await reconciler.renderUnionView(fileId, winnerPath, union);
      if (wrote) _emit(SyncFileModified(winnerPath));
      _emit(
        SyncConflictResolved(
          fileId: fileId,
          strategy: 'text-union',
          winnerBlobRef: '',
        ),
      );
      return;
    }

    // Shared history (or a single surviving value): char-level Fugue join is
    // lossless and a true lattice join, so sealing it back as a dominating
    // single value is CRDT-safe.
    var merged = sequences.first;
    for (var i = 1; i < sequences.length; i++) {
      merged = merged.join(sequences[i]);
    }

    final upload = await reconciler.uploadSequenceBlob(merged);
    if (upload == null) return;

    fugueStore.set(fileId, merged);
    await fugueStore.persistOne(fileId);

    final hlc = store.nextHlc();
    final sealed = FileState(
      fileId: fileId,
      path: winnerPath,
      blobRef: upload.manifestHash,
      sizeBytes: upload.blobSize,
      hlc: hlc,
      tombstone: false,
      chunks: upload.chunkHashes,
    );
    store.applyLocal(sealed);
    // CRDT join is a convergence point — record the merged blob as
    // the new LCA so [sync_v3_lca_semantics] holds for any future
    // 3-way comparisons that might still touch this register (e.g.
    // tooling that walks history).
    store.recordSyncedBlobRef(fileId, upload.manifestHash);

    final projection = Uint8List.fromList(utf8.encode(merged.values.join()));
    final fullPath = '$vaultPath/$winnerPath';
    changeProvider.suppress(winnerPath);
    await io.writeFile(fullPath, projection);

    _emit(SyncFileModified(winnerPath));
    _emit(
      SyncConflictResolved(
        fileId: fileId,
        strategy: 'fugue-join',
        winnerBlobRef: upload.manifestHash,
      ),
    );
  }

  /// True when the concurrent text [seqs] genuinely share causal history (a
  /// real common base) and can be char-merged losslessly via Fugue join.
  ///
  /// Signal: they must share at least one element [Dot] AND no shared dot may
  /// carry differing character values. A seed collision — the same positional
  /// `('seed')` dot holding different chars on two devices — is exactly the
  /// divergent-no-history case and trips the value check. Tombstoned elements
  /// keep their original value (Fugue never discards a run's values), so a
  /// concurrent delete-vs-keep on the same dot (same char) is NOT a false
  /// conflict. Returns false when there is no overlap at all (disjoint trees →
  /// also no shared history).
  ///
  /// Package-public (not `_`-prefixed) so the invariant it guards — two
  /// independently-seeded divergent versions must NOT be char-joined — is
  /// unit-testable directly; it is otherwise an internal detail of the
  /// text-conflict resolver.
  static bool sharesGenuineHistory(List<Fugue<String>> seqs) {
    final seen = <Dot, String>{};
    var overlap = false;
    for (final seq in seqs) {
      // rawBlocks yields (start, parent, side, values, delRanges): element k
      // of a run has dot (start.counter + k, start.replica) and value
      // values[k] — enumerable whether or not it is tombstoned.
      for (final (start, _, _, values, _) in seq.rawBlocks) {
        for (var k = 0; k < values.length; k++) {
          final dot = Dot(start.counter + k, start.replica);
          final value = values[k];
          if (seen.containsKey(dot)) {
            overlap = true;
            if (seen[dot] != value) return false;
          } else {
            seen[dot] = value;
          }
        }
      }
    }
    return overlap;
  }

  /// Write a single canonical [FileState] to disk and update the synced
  /// blob ref. No-op when the file already matches.
  Future<void> _materialise(FileState state) async {
    if (state.tombstone) {
      final fullPath = '$vaultPath/${state.path}';
      if (await io.fileExists(fullPath)) {
        changeProvider.suppress(state.path);
        await io.deleteFile(fullPath);
        _emit(SyncFileDeleted(state.path));
      }
      store.recordSyncedBlobRef(state.fileId, '');
      return;
    }
    // Record the synced LCA ONLY if the content actually landed on disk.
    // A failed blob download writes nothing; recording the ref anyway
    // would trip the already-synced short-circuit on every later pull and
    // leave the file permanently missing (no retry). Leaving the LCA
    // untouched lets a subsequent pull/verify re-attempt the write.
    final wrote = await reconciler.writeFileToDisk(state);
    if (wrote) store.recordSyncedBlobRef(state.fileId, state.blobRef);
  }

  Future<void> _applyOutcome(
    String fileId,
    StateMergeOutcome outcome,
    MvRegister<FileState> sourceRegister,
  ) async {
    switch (outcome) {
      case StateMergeMerged(:final merged, :final newBlobBytes):
        var sealed = merged;
        if (newBlobBytes != null) {
          // The resolver computed a content sha256 as merged.blobRef, but
          // in sync v3 blobRef must be a chunked-blob manifest hash.
          // Re-upload the merged bytes through ChunkedBlobIO so peers can
          // resolve them — otherwise their disk applier hits a JSON-decode
          // failure on the raw content and silently skips the write.
          final chunkedIO = _newChunkedIO();
          if (chunkedIO != null) {
            try {
              final result = await chunkedIO.upload(
                newBlobBytes,
                _collectKnownChunks(),
              );
              sealed = merged.copyWith(
                blobRef: result.manifestHash,
                chunks: result.chunkHashes,
              );
            } catch (e) {
              _log.warning('Merged blob chunked upload failed: $e');
              await blobStore.write(
                newBlobBytes,
                merged.blobRef,
                vaultId: vaultId,
              );
            }
          } else {
            await blobStore.write(
              newBlobBytes,
              merged.blobRef,
              vaultId: vaultId,
            );
          }
          final fullPath = '$vaultPath/${sealed.path}';
          changeProvider.suppress(sealed.path);
          await io.writeFile(fullPath, newBlobBytes);
        }
        // Seal the conflict: write under ownContext that dominates every
        // losing TaggedValue's hlc → register cardinality goes back to 1
        // (doc §6 last paragraph).
        store.applyLocal(sealed);
        // Resolver collapse is a convergence point — both devices arrive
        // at the same sealed.blobRef from the same inputs (deterministic
        // resolve over the same MvRegister values). Record it as the new
        // LCA so subsequent 3-way merges have a real shared base.
        if (!sealed.tombstone && sealed.blobRef.isNotEmpty) {
          store.recordSyncedBlobRef(fileId, sealed.blobRef);
        }
        _emit(SyncFileModified(sealed.path));
        _emit(
          SyncConflictResolved(
            fileId: fileId,
            strategy: newBlobBytes != null ? '3-way-merge' : 'same-blob',
            winnerBlobRef: sealed.blobRef,
          ),
        );
      case StateMergeConflictCopy(
        :final winner,
        :final loser,
        :final suggestedCopyPath,
      ):
        await _writeConflictCopyFile(loser, suggestedCopyPath);
        // Materialise winner content + register-collapse via applyLocal.
        await _materialise(winner);
        store.applyLocal(winner);
        _emit(SyncFileModified(winner.path));
        _emit(
          SyncConflictResolved(
            fileId: fileId,
            strategy: loser.tombstone ? 'tombstone-loses' : 'lww',
            winnerBlobRef: winner.blobRef,
          ),
        );
      case StateMergeWinnerOnlyLossy(
        :final winner,
        :final lostBlobRef,
        :final lostNodeId,
        :final reason,
      ):
        // Materialise the winner and seal the register the normal way,
        // then surface the loss explicitly — the loser's bytes are gone
        // and the UI must know.
        await _materialise(winner);
        store.applyLocal(winner);
        _emit(SyncFileModified(winner.path));
        _log.warning('Data loss sealing $fileId via LWW: $reason');
        _emit(
          SyncDataLoss(
            fileId: fileId,
            path: winner.path,
            lostBlobRef: lostBlobRef,
            lostNodeId: lostNodeId,
            reason: reason,
          ),
        );
        _emit(
          SyncConflictResolved(
            fileId: fileId,
            strategy: 'lww-lossy',
            winnerBlobRef: winner.blobRef,
          ),
        );
      case StateMergeMultiConflict(:final winner, :final parts):
        // N>2 concurrent divergence. Preserve every non-canonical value —
        // conflict-copy the recoverable ones, surface a loss for any whose
        // bytes are unreachable — then materialise and seal the winner once.
        for (final part in parts) {
          switch (part) {
            case StateMergeConflictCopy(:final loser, :final suggestedCopyPath):
              await _writeConflictCopyFile(loser, suggestedCopyPath);
            case StateMergeWinnerOnlyLossy(
                :final lostBlobRef,
                :final lostNodeId,
                :final reason,
              ):
              _log.warning('Data loss sealing $fileId via LWW (N>2): $reason');
              _emit(
                SyncDataLoss(
                  fileId: fileId,
                  path: winner.path,
                  lostBlobRef: lostBlobRef,
                  lostNodeId: lostNodeId,
                  reason: reason,
                ),
              );
            case StateMergeMerged():
            case StateMergeMultiConflict():
              // The fold only ever collects ConflictCopy / WinnerOnlyLossy.
              break;
          }
        }
        await _materialise(winner);
        store.applyLocal(winner);
        _emit(SyncFileModified(winner.path));
        _emit(
          SyncConflictResolved(
            fileId: fileId,
            strategy: 'multi-conflict-copy',
            winnerBlobRef: winner.blobRef,
          ),
        );
    }
  }

  /// Reads a conflict loser's real content (through ChunkedBlobIO, falling
  /// back to the local cache) and writes it as a conflict-copy file. No-op
  /// when the bytes are unreachable — the caller decides whether that is a
  /// surfaced loss (it never is for a `StateMergeConflictCopy`, whose
  /// recoverability the resolver pre-verified).
  Future<void> _writeConflictCopyFile(
    FileState loser,
    String copyPath,
  ) async {
    // loser.blobRef is a manifest hash — read it through ChunkedBlobIO so the
    // conflict-copy file gets the real file content, not the manifest JSON.
    Uint8List? loserBytes;
    final chunkedIO = _newChunkedIO();
    if (chunkedIO != null) {
      try {
        loserBytes = await chunkedIO.download(loser.blobRef);
      } catch (e) {
        _log.warning('Conflict-copy chunked download failed: $e');
      }
    }
    loserBytes ??= await blobStore.read(loser.blobRef, vaultId: vaultId);
    if (loserBytes != null) {
      final fullCopyPath = '$vaultPath/$copyPath';
      changeProvider.suppress(copyPath);
      await io.writeFile(fullCopyPath, loserBytes);
    }
  }
}
