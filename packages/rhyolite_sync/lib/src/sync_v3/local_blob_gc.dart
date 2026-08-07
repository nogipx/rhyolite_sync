import '../local/local_blob_store.dart';
import 'file_state.dart';
import 'file_state_store.dart';

/// Garbage-collects blobs in the local cache that are no longer referenced.
///
/// A blob is "live" when it is either:
/// - the current content of some file (file_state.blobRef), or
/// - claimed by a sibling sync sharing this cache (see [externalLiveIds]),
///
/// and is NOT regenerable from the vault itself (see [isRegenerable]).
///
/// `lastSyncedBlobRef` used to be pinned here too, as a 3-way merge base. That
/// merge is gone (see [StateConflictResolver]: every file reaching it was
/// classified not-text on purpose, so merging it was never correct), and the
/// ref itself is only ever compared as a HASH — to tell a real concurrent edit
/// from a peer re-observing an unchanged copy. Nothing reads those bytes, so
/// pinning them kept a second copy of every file that has ever changed.
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
    this.isRegenerable,
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

  /// Whether a file's blobs can be rebuilt from the file itself, so the cache
  /// need not hold a second copy of them.
  ///
  /// This is what stops an attachment costing its own size twice — once in the
  /// vault, once here as chunks. Chunking is deterministic, so for a binary
  /// still sitting on disk the cache is pure duplication; the pull path
  /// already treats a cache miss as routine and refetches, and blob verify can
  /// now re-derive a lost chunk from the file.
  ///
  /// Applies only where the answer is exact. A text file's blob is its Fugue
  /// tree — the disk holds a rendered projection, not the blob — so text is
  /// never regenerable and its cache entries stay. Null (the default) keeps
  /// every referenced blob, the behaviour that shipped before this.
  ///
  /// A blob is dropped only when EVERY state referencing it says yes: chunks
  /// are content-addressed and shared, and one shared with a file that is not
  /// on disk must survive.
  final Future<bool> Function(FileState state)? isRegenerable;

  Future<LocalBlobGcResult> call() async {
    final live = <String>{};

    final external = externalLiveIds?.call();
    if (externalLiveIds != null && external == null) {
      return const LocalBlobGcResult(scanned: 0, deleted: 0, skipped: true);
    }
    if (external != null) live.addAll(external);
    // Blobs referenced by at least one state that CANNOT rebuild them. A
    // shared chunk is kept if any of its owners needs it kept, which is why
    // this is collected separately rather than decided per state.
    final pinned = <String>{};
    final regenerable = isRegenerable;
    // Walk every TaggedValue across all registers — multi-value registers
    // pin each concurrent version's blobs until the resolver collapses
    // them (doc §9).
    for (final state in store.allValuesFlat) {
      final refs = [
        if (state.blobRef.isNotEmpty) state.blobRef,
        ...state.chunks,
      ];
      live.addAll(refs);
      if (regenerable == null || !await regenerable(state)) pinned.addAll(refs);
    }
    // Anything live only on behalf of files that can rebuild it is dropped —
    // the vault is holding those bytes already.
    if (regenerable != null) {
      live.removeWhere((id) => !pinned.contains(id) && !(external?.contains(id) ?? false));
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
