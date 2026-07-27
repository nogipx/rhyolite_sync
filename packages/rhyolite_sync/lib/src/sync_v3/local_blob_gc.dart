import '../local/local_blob_store.dart';
import 'file_state_store.dart';

/// Garbage-collects blobs in the local cache that are no longer referenced.
///
/// A blob is "live" when it is either:
/// - the current content of some file (file_state.blobRef), or
/// - the lastSyncedBlobRef of some file (kept for future 3-way merge base), or
/// - claimed by a sibling sync sharing this cache (see [externalLiveIds]).
///
/// Everything else is dead weight from past edits and gets deleted.
///
/// Symmetric to the server-side blob GC in HistoryResponder. The two are
/// independent: the server keeps blobs alive for ~30 days for cross-device
/// 3-way merge fallback; the client keeps only what THIS device needs.
class LocalBlobGc {
  LocalBlobGc({
    required this.store,
    required this.blobStore,
    required this.vaultId,
    this.externalLiveIds,
  });

  final FileStateStore store;
  final LocalBlobStore blobStore;
  final String vaultId;

  /// Blob ids owned by a sibling sync that shares this vault's local cache —
  /// today the settings sync, whose plugin-code resources store their bytes
  /// here under the same vaultId. Without this the notes-only live set treats
  /// every plugin blob as an orphan and evicts it right after it is written.
  ///
  /// Returning null means "cannot answer right now" (the sibling has not
  /// started yet) and SKIPS the whole sweep. Deleting on an incomplete live set
  /// is the one failure this must never have; a postponed sweep costs nothing.
  final Set<String>? Function()? externalLiveIds;

  Future<LocalBlobGcResult> call() async {
    final live = <String>{};

    final external = externalLiveIds?.call();
    if (externalLiveIds != null && external == null) {
      return const LocalBlobGcResult(scanned: 0, deleted: 0, skipped: true);
    }
    if (external != null) live.addAll(external);
    // Walk every TaggedValue across all registers — multi-value registers
    // pin each concurrent version's blobs until the resolver collapses
    // them (doc §9).
    for (final state in store.allValuesFlat) {
      if (state.blobRef.isNotEmpty) live.add(state.blobRef);
      live.addAll(state.chunks);
    }
    for (final fileId in store.fileIds) {
      final synced = store.lastSyncedBlobRefFor(fileId);
      if (synced != null && synced.isNotEmpty) live.add(synced);
    }

    final List<String> allBlobIds;
    try {
      allBlobIds = await blobStore.listBlobIds(vaultId: vaultId);
    } catch (_) {
      return const LocalBlobGcResult(scanned: 0, deleted: 0);
    }

    final orphans = allBlobIds.where((id) => !live.contains(id)).toList();
    if (orphans.isEmpty) {
      return LocalBlobGcResult(scanned: allBlobIds.length, deleted: 0);
    }

    try {
      await blobStore.deleteBlobs(orphans, vaultId: vaultId);
    } catch (_) {
      // Partial deletes are fine — the next sweep will catch the rest.
    }

    return LocalBlobGcResult(scanned: allBlobIds.length, deleted: orphans.length);
  }
}

class LocalBlobGcResult {
  /// Total blobs found in the local cache.
  final int scanned;

  /// Blobs deleted because nothing referenced them.
  final int deleted;

  /// The sweep did not run: a sibling sync could not report its live blobs, so
  /// the live set would have been incomplete.
  final bool skipped;

  const LocalBlobGcResult({
    required this.scanned,
    required this.deleted,
    this.skipped = false,
  });
}
