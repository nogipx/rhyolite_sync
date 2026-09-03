import 'package:rpc_dart/rpc_dart.dart';

import '../local/local_blob_store.dart';
import 'package:rhyolite_core/rhyolite_core.dart';
import 'file_state_store.dart';
import 'time_budget_yielder.dart';

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
  /// "The file itself" is not always the bytes on disk. A binary rebuilds from
  /// its disk copy; a text note rebuilds from its Fugue tree, which the disk
  /// does NOT hold (it holds a rendered projection) but the FugueStore does.
  /// Text was excluded here while only the disk route existed, which left the
  /// cache holding a second copy of every tree. Null (the default) keeps every
  /// referenced blob, the behaviour that shipped before this.
  ///
  /// A blob is dropped only when EVERY state referencing it says yes: chunks
  /// are content-addressed and shared, and one shared with a file that is not
  /// on disk must survive.
  final Future<bool> Function(FileState state)? isRegenerable;

  /// Sweeps the cache.
  ///
  /// [candidates] narrows the sweep to a known set of ids — what a pull just
  /// staged — instead of the whole cache. That turns the cost from O(vault)
  /// into O(what changed): the id list is already known so [listBlobIds] is
  /// skipped, and a state whose refs cannot touch a candidate is never asked
  /// [isRegenerable], which is the part that costs a stat per attachment. The
  /// full sweep still runs at startup, where paying once is the point.
  ///
  /// [context] aborts the sweep. Honoured only where aborting is SAFE: during
  /// the state walk it returns having deleted nothing, because a half-built
  /// pinned set would call a blob unreferenced merely for not having reached
  /// its owner yet. Once that set is complete, stopping early just deletes
  /// fewer — always safe, since the next sweep finds the rest.
  Future<LocalBlobGcResult> call({
    RpcContext? context,
    Set<String>? candidates,
  }) async {
    if (candidates != null && candidates.isEmpty) {
      return const LocalBlobGcResult(scanned: 0, deleted: 0);
    }
    final token = context?.cancellationToken;
    final live = <String>{};

    // A sibling that cannot answer yet does not stop the sweep any more — it
    // narrows it.
    //
    // Refusing outright was right about ORPHANS: an id that belongs to no
    // state of ours may be the sibling's, and deleting it on a partial live
    // set would take another feature's data. It was wrong about everything
    // else. A blob one of OUR states references is ours whatever the sibling
    // holds, and if the vault can rebuild it there is no argument for keeping
    // it — which is the entire cached copy of every binary in the vault, and
    // the reason one database reached 1.5 GB.
    //
    // That distinction is what lets this run BEFORE the initial pull. Settings
    // sync comes up seconds after the engine, so a sweep that needs it can
    // only ever run later — and later is after the pull, which is exactly the
    // ordering that let a full database block its own cleanup.
    final external = externalLiveIds?.call();
    final siblingUnknown = externalLiveIds != null && external == null;
    if (external != null) live.addAll(external);
    // Blobs referenced by at least one state that CANNOT rebuild them. A
    // shared chunk is kept if any of its owners needs it kept, which is why
    // this is collected separately rather than decided per state.
    final pinned = <String>{};
    /// Every id one of OUR states names, pinned or not — the set that can be
    /// judged without knowing anything about the sibling.
    final ourRefs = <String>{};
    final regenerable = isRegenerable;
    // Walk every TaggedValue across all registers — multi-value registers
    // pin each concurrent version's blobs until the resolver collapses
    // them (doc §9).
    final yielder = TimeBudgetYielder();
    for (final state in store.allValuesFlat) {
      if (token?.isCancelled ?? false) {
        return const LocalBlobGcResult(scanned: 0, deleted: 0, skipped: true);
      }
      final refs = [
        if (state.blobRef.isNotEmpty) state.blobRef,
        ...state.chunks,
      ];
      // Scoped: a state that shares nothing with the candidates can neither
      // pin one nor be pinned by one, so skip it BEFORE isRegenerable — that
      // call stats the file, and doing it per state is what made the full
      // sweep too heavy to run often.
      if (candidates != null && !refs.any(candidates.contains)) continue;
      live.addAll(refs);
      ourRefs.addAll(refs);
      if (regenerable == null || !await regenerable(state)) pinned.addAll(refs);
      // Thousands of iterations on a large vault, sharing the host's only
      // thread — and wildly uneven: a text state costs a set lookup, a binary
      // one costs a stat. Measured in time rather than items for exactly that
      // reason.
      await yielder.maybeYield();
    }
    // Anything live only on behalf of files that can rebuild it is dropped —
    // the vault is holding those bytes already.
    if (regenerable != null) {
      live.removeWhere(
        (id) => !pinned.contains(id) && !(external?.contains(id) ?? false),
      );
    }
    final List<String> allBlobIds;
    if (candidates != null) {
      allBlobIds = candidates.toList();
    } else {
      try {
        allBlobIds = await blobStore.listBlobIds(vaultId: vaultId);
      } catch (_) {
        return const LocalBlobGcResult(scanned: 0, deleted: 0);
      }
    }

    // With the sibling silent, delete only what is provably ours and provably
    // rebuildable; leave every unknown id alone. With it answering, the full
    // sweep runs as before and collects orphans too.
    final orphans = siblingUnknown
        ? allBlobIds
              .where((id) => ourRefs.contains(id) && !pinned.contains(id))
              .toList()
        : allBlobIds.where((id) => !live.contains(id)).toList();
    if (orphans.isEmpty) {
      return LocalBlobGcResult(
        scanned: allBlobIds.length,
        deleted: 0,
        skipped: siblingUnknown,
      );
    }

    try {
      await blobStore.deleteBlobs(orphans, vaultId: vaultId);
    } catch (_) {
      // Partial deletes are fine — the next sweep will catch the rest.
    }

    return LocalBlobGcResult(
      scanned: allBlobIds.length,
      deleted: orphans.length,
      skipped: siblingUnknown,
    );
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
