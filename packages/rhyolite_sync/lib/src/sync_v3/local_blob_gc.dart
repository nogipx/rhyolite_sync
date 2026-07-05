import '../local/local_blob_store.dart';
import 'file_state_store.dart';

/// Garbage-collects blobs in the local cache that are no longer referenced.
///
/// A blob is "live" when it is either:
/// - the current content of some file (file_state.blobRef), or
/// - the lastSyncedBlobRef of some file (kept for future 3-way merge base).
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
  });

  final FileStateStore store;
  final LocalBlobStore blobStore;
  final String vaultId;

  Future<LocalBlobGcResult> call() async {
    final live = <String>{};
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

  const LocalBlobGcResult({required this.scanned, required this.deleted});
}
