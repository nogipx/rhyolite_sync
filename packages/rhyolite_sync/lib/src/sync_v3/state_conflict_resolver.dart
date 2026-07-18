import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Outcome of merging the concurrent values in a multi-value
/// MvRegister<FileState> (doc §6).
sealed class StateMergeOutcome {}

/// Merge produced a single resulting state, plus a freshly computed blob
/// (which the caller must upload and write to disk).
class StateMergeMerged extends StateMergeOutcome {
  final FileState merged;
  final Uint8List? newBlobBytes;
  final String newBlobRef;
  StateMergeMerged({
    required this.merged,
    required this.newBlobRef,
    this.newBlobBytes,
  });
}

/// Could not auto-merge. Caller should write the "loser" content alongside
/// (as a conflict-copy file) and adopt the "winner" as canonical.
///
/// **Recoverability promise:** when this outcome is returned for a
/// non-tombstone loser, the resolver guarantees the engine can fetch
/// the loser's content via the configured `blobStore` right now (the
/// resolver pre-loads it on the way out). When the promise cannot be
/// kept, the resolver returns [StateMergeWinnerOnlyLossy] instead and
/// the engine emits an explicit data-loss event.
class StateMergeConflictCopy extends StateMergeOutcome {
  final FileState winner;
  final FileState loser;
  final String suggestedCopyPath;
  StateMergeConflictCopy({
    required this.winner,
    required this.loser,
    required this.suggestedCopyPath,
  });
}

/// LWW fallback where the loser's content is unrecoverable — neither
/// the local blob cache nor the configured remote can produce its
/// bytes. The engine materialises the winner, seals the register, AND
/// emits an explicit data-loss event so the UI can surface the loss
/// instead of silently dropping the loser.
///
/// This replaces what used to be a silent failure: the resolver
/// returned `StateMergeConflictCopy` even when the engine had no way
/// to write the conflict-copy file, and the missing content
/// disappeared without trace.
class StateMergeWinnerOnlyLossy extends StateMergeOutcome {
  final FileState winner;
  final String lostBlobRef;
  final Hlc lostHlc;
  final String lostNodeId;
  final String reason;
  StateMergeWinnerOnlyLossy({
    required this.winner,
    required this.lostBlobRef,
    required this.lostHlc,
    required this.lostNodeId,
    required this.reason,
  });
}

/// More than two concurrent values could not all be merged into one. The
/// [winner] is the single canonical value (max-HLC) the engine materialises
/// and seals the register with; [parts] carries one entry per non-canonical
/// value so none is dropped — each is either a [StateMergeConflictCopy] (the
/// engine writes the loser's content as a conflict-copy file) or a
/// [StateMergeWinnerOnlyLossy] (the loser's bytes are unreachable and the
/// engine surfaces an explicit data-loss event).
///
/// This exists because the pairwise fold that resolves N>2 values used to
/// return on the first unmergeable pair, silently dropping every later
/// concurrent version.
class StateMergeMultiConflict extends StateMergeOutcome {
  final FileState winner;
  final List<StateMergeOutcome> parts;
  StateMergeMultiConflict({required this.winner, required this.parts});
}

/// Strategy interface for collapsing a multi-value
/// `MvRegister<FileState>` back to a single chosen value (doc §6).
///
/// The default implementation is [StateConflictResolver]. Embedders that
/// want different semantics (e.g. remove-wins instead of add-wins, or a
/// custom conflict-copy naming scheme) implement this interface and pass
/// it to [SyncEngine] via constructor.
abstract interface class IStateConflictResolver {
  /// Resolve [values] (surviving TaggedValues of one register) into a
  /// single chosen [FileState]. [baseRef] is the
  /// `lastSyncedBlobRef[fileId]` (if known) for 3-way-merge base.
  Future<StateMergeOutcome> resolve(List<FileState> values, {String? baseRef});
}

/// Default implementation of [IStateConflictResolver] per doc §6.
///
/// Collapses a multi-value MvRegister<FileState> back to a single chosen
/// FileState. The caller seals the conflict by writing the chosen
/// value under a CausalContext that dominates every losing TaggedValue.
class StateConflictResolver implements IStateConflictResolver {
  final FileStateStore store;
  final LocalBlobStore blobStore;
  final IBlobStorage? remoteBlobStorage;

  /// Resolves a [FileState.blobRef] (which is a chunked-blob manifest
  /// hash in sync v3) into the actual concatenated file content. When
  /// non-null, takes precedence over the raw [blobStore] read — the raw
  /// store would return the manifest JSON, not the content, silently
  /// corrupting any 3-way text merge or conflict-copy write.
  final ChunkedBlobIO? chunkedBlobIO;
  final String vaultId;
  final String nodeId;

  /// Hook to find a base blobRef via the history service when the local
  /// `lastSyncedBlobRef` is unavailable (new device, restore from server,
  /// blob cache eviction).
  final Future<String?> Function(String fileId, Hlc beforeHlc)?
  findHistoryBaseRef;

  StateConflictResolver({
    required this.store,
    required this.blobStore,
    required this.vaultId,
    required this.nodeId,
    this.remoteBlobStorage,
    this.chunkedBlobIO,
    this.findHistoryBaseRef,
  });

  /// Collapse [values] (the surviving TaggedValues of one register) into a
  /// single chosen [FileState]. Algorithm (doc §6):
  ///
  /// 1. All values share `blobRef` → max-HLC, single-value (no real
  ///    content conflict).
  /// 2. Tombstone vs non-tombstone → add-wins. Tombstone becomes a
  ///    conflict-copy marker.
  /// 3. Real text divergence with base available → 3-way merge.
  /// 4. Otherwise → LWW by HLC + conflict-copy of the loser.
  ///
  /// For N>2 values, pairwise reduce: resolve(a,b) → c, resolve(c,d) → e, …
  Future<StateMergeOutcome> resolve(
    List<FileState> values, {
    String? baseRef,
  }) async {
    if (values.isEmpty) {
      throw ArgumentError('resolve called with no values');
    }
    if (values.length == 1) {
      final v = values.single;
      return StateMergeMerged(merged: v, newBlobRef: v.blobRef);
    }

    // Trivial case: all values converged on the same content.
    final allSameBlob = values.every((v) => v.blobRef == values.first.blobRef);
    final allSameTomb = values.every(
      (v) => v.tombstone == values.first.tombstone,
    );
    if (allSameBlob && allSameTomb) {
      final winner = values.reduce((a, b) => a.hlc >= b.hlc ? a : b);
      return StateMergeMerged(merged: winner, newBlobRef: winner.blobRef);
    }

    // Pairwise reduce. The fold is deterministic across replicas because
    // every replica sees the same register (CRDT) and folds in the same
    // hlc-sorted order.
    //
    // Unmergeable pairs do NOT stop the fold: each one's loser is collected
    // so it can be preserved (conflict-copy or surfaced loss), and folding
    // continues so the final `acc` is the true canonical winner across ALL
    // values. Previously the fold returned on the first conflict, silently
    // dropping every later concurrent version.
    final sorted = [...values]..sort((a, b) => a.hlc.compareTo(b.hlc));
    StateMergeOutcome last = StateMergeMerged(
      merged: sorted.first,
      newBlobRef: sorted.first.blobRef,
    );
    var acc = sorted.first;
    final losers = <StateMergeOutcome>[];
    for (var i = 1; i < sorted.length; i++) {
      final outcome = await _pair(
        local: acc,
        remote: sorted[i],
        baseRef: baseRef,
      );
      switch (outcome) {
        case StateMergeMerged(:final merged):
          acc = merged;
          last = outcome;
        case StateMergeConflictCopy(:final winner):
          acc = winner;
          losers.add(outcome);
        case StateMergeWinnerOnlyLossy(:final winner):
          acc = winner;
          losers.add(outcome);
        case StateMergeMultiConflict():
          // _pair never produces a compound outcome; unreachable.
          break;
      }
    }

    if (losers.isEmpty) return last;

    // Exactly one conflict across the whole fold: keep the existing N=2
    // outcome shape, but rebind the winner to the final `acc` (a later pair
    // may have merged the winner forward).
    if (losers.length == 1) {
      final only = losers.first;
      if (only is StateMergeConflictCopy) {
        return StateMergeConflictCopy(
          winner: acc,
          loser: only.loser,
          suggestedCopyPath: only.suggestedCopyPath,
        );
      }
      final l = only as StateMergeWinnerOnlyLossy;
      return StateMergeWinnerOnlyLossy(
        winner: acc,
        lostBlobRef: l.lostBlobRef,
        lostHlc: l.lostHlc,
        lostNodeId: l.lostNodeId,
        reason: l.reason,
      );
    }

    return StateMergeMultiConflict(winner: acc, parts: losers);
  }

  Future<StateMergeOutcome> _pair({
    required FileState local,
    required FileState remote,
    required String? baseRef,
  }) async {
    if (local.blobRef == remote.blobRef &&
        local.tombstone == remote.tombstone) {
      final winner = local.hlc >= remote.hlc ? local : remote;
      return StateMergeMerged(merged: winner, newBlobRef: winner.blobRef);
    }

    // Tombstone vs edit: add-wins by default (a concurrent edit beats a
    // delete), surfacing the deleter's marker as a conflict-copy file.
    //
    // BUT the "edit" can be an illusion. A peer that still had the file on disk
    // when another device deleted it re-observes it as a live value that is
    // byte-identical to the last converged version — its blobRef equals the LCA
    // `lastSyncedBlobRef`. The delete causally follows that exact version, so it
    // must win; otherwise a rename/move (modelled as tombstone(old path) +
    // create(new path)) resurrects the old path on every peer that hasn't
    // applied the delete yet. Only when the live side GENUINELY diverged from
    // the LCA (blobRef != LCA) is it a real edit-vs-delete race → add-wins.
    // Unknown/empty LCA → keep the safe add-wins default (never delete data we
    // cannot prove is just a stale copy).
    if (local.tombstone != remote.tombstone) {
      final tomb = local.tombstone ? local : remote;
      final live = local.tombstone ? remote : local;
      final lca = baseRef ?? store.lastSyncedBlobRefFor(local.fileId);
      if (lca != null && lca.isNotEmpty && live.blobRef == lca) {
        return StateMergeMerged(merged: tomb, newBlobRef: tomb.blobRef);
      }
      return StateMergeConflictCopy(
        winner: live,
        loser: tomb,
        suggestedCopyPath: _conflictCopyPath(live.path, tomb.hlc),
      );
    }

    // Try 3-way text merge.
    String? base = baseRef ?? store.lastSyncedBlobRefFor(local.fileId);
    if (base == null && findHistoryBaseRef != null) {
      final beforeHlc = local.hlc.compareTo(remote.hlc) < 0
          ? local.hlc
          : remote.hlc;
      try {
        base = await findHistoryBaseRef!(local.fileId, beforeHlc);
      } catch (_) {
        base = null;
      }
    }

    if (base != null) {
      final outcome = await _tryThreeWayTextMerge(
        local: local,
        remote: remote,
        baseBlobRef: base,
      );
      if (outcome != null) return outcome;
    }

    // LWW fallback + conflict-copy of the loser.
    final winner = local.hlc >= remote.hlc ? local : remote;
    final loser = identical(winner, local) ? remote : local;

    // ConflictCopy promises the engine can write the loser's content.
    // Ensure that promise is keepable before returning it: tombstone
    // losers have no content (semantically fine to skip), but for a
    // regular edit-loser we must be able to fetch its bytes either
    // from the local cache or via the configured remote. If we can't,
    // returning ConflictCopy would result in a silently-skipped file
    // write and lost content.
    if (!loser.tombstone && loser.blobRef.isNotEmpty) {
      final loserBytes = await _readBlob(loser.fileId, loser.blobRef);
      if (loserBytes == null) {
        return StateMergeWinnerOnlyLossy(
          winner: winner,
          lostBlobRef: loser.blobRef,
          lostHlc: loser.hlc,
          lostNodeId: loser.hlc.nodeId,
          reason:
              'loser blob ${loser.blobRef} unreachable from local cache '
              'and remote',
        );
      }
    }

    return StateMergeConflictCopy(
      winner: winner,
      loser: loser,
      suggestedCopyPath: _conflictCopyPath(winner.path, loser.hlc),
    );
  }

  Future<StateMergeOutcome?> _tryThreeWayTextMerge({
    required FileState local,
    required FileState remote,
    required String baseBlobRef,
  }) async {
    final baseBytes = await _readBlob(local.fileId, baseBlobRef);
    final localBytes = await _readBlob(local.fileId, local.blobRef);
    final remoteBytes = await _readBlob(local.fileId, remote.blobRef);
    if (baseBytes == null || localBytes == null || remoteBytes == null) {
      return null;
    }
    if (!_looksLikeText(localBytes) || !_looksLikeText(remoteBytes)) {
      return null;
    }

    final baseText = utf8.decode(baseBytes, allowMalformed: true);
    final localText = utf8.decode(localBytes, allowMalformed: true);
    final remoteText = utf8.decode(remoteBytes, allowMalformed: true);

    final patches = patchMake(baseText, b: remoteText);
    final result = patchApply(patches, localText);
    final applied = (result[1] as List).cast<bool>();
    if (!applied.every((x) => x)) return null;

    final mergedText = result[0] as String;
    final mergedBytes = Uint8List.fromList(utf8.encode(mergedText));
    final mergedRef = sha256.convert(mergedBytes).toString();

    // Fresh HLC for the merge — dominates both inputs. The caller will
    // re-stamp via store.applyLocal under ownContext anyway, but we set
    // a sensible default in case callers materialise directly.
    final mergedHlc = store.nextHlc();

    final merged = local.copyWith(
      path: local.path,
      blobRef: mergedRef,
      sizeBytes: mergedBytes.length,
      hlc: mergedHlc,
      tombstone: false,
    );

    return StateMergeMerged(
      merged: merged,
      newBlobRef: mergedRef,
      newBlobBytes: mergedBytes,
    );
  }

  Future<Uint8List?> _readBlob(String fileId, String blobRef) async {
    if (blobRef.isEmpty) return null;
    // In sync v3 every blobRef is a chunked-blob manifest hash. Reading
    // it as raw bytes returns the manifest JSON, not the file content —
    // which silently corrupts 3-way text merges and conflict-copy
    // writes (they end up containing `{"v":1,"size":..,"chunks":[..]}`).
    // Resolve through ChunkedBlobIO so we get the concatenated chunks.
    final chunked = chunkedBlobIO;
    if (chunked != null) {
      try {
        return await chunked.download(blobRef);
      } catch (_) {
        return null;
      }
    }
    // Fallback path retained for legacy/offline-only setups that have no
    // remote storage configured and therefore no ChunkedBlobIO.
    final local = await blobStore.read(blobRef, vaultId: vaultId);
    if (local != null) return local;
    final remote = remoteBlobStorage;
    if (remote != null) {
      try {
        final downloaded = await remote.download([blobRef]);
        final bytes = downloaded[blobRef];
        if (bytes != null) {
          await blobStore.write(bytes, blobRef, vaultId: vaultId);
          return bytes;
        }
      } catch (_) {}
    }
    return null;
  }

  bool _looksLikeText(Uint8List bytes) {
    final probe = bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes;
    return !probe.contains(0);
  }

  String _conflictCopyPath(String path, Hlc loserHlc) {
    final ts = DateTime.fromMillisecondsSinceEpoch(loserHlc.millis).toUtc();
    final stamp =
        '${ts.year.toString().padLeft(4, '0')}-'
        '${ts.month.toString().padLeft(2, '0')}-'
        '${ts.day.toString().padLeft(2, '0')}T'
        '${ts.hour.toString().padLeft(2, '0')}'
        '${ts.minute.toString().padLeft(2, '0')}'
        '${ts.second.toString().padLeft(2, '0')}';
    final idx = path.lastIndexOf('.');
    if (idx <= 0) return '$path (conflict $stamp from ${loserHlc.nodeId})';
    final stem = path.substring(0, idx);
    final ext = path.substring(idx);
    return '$stem (conflict $stamp from ${loserHlc.nodeId})$ext';
  }
}
