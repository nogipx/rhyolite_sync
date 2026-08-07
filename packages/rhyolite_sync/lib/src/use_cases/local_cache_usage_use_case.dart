import '../chunking/file_type_detector.dart';
import '../local/local_blob_store.dart';
import '../sync_v3/file_state_store.dart';

/// What the local blob cache actually weighs, and on whose behalf.
///
/// The storage overview could only report the *logical* vault size (the sum of
/// `FileState.sizeBytes`) and a count of distinct blobs. Neither says anything
/// about the database sitting on the user's disk, which is the number they care
/// about when the phone complains — and the one nobody can act on while it is
/// invisible.
class LocalCacheUsage {
  const LocalCacheUsage({
    required this.totalBytes,
    required this.blobCount,
    required this.binaryBytes,
    required this.textBytes,
    required this.orphanBytes,
    required this.redundantBinaryBytes,
  });

  /// Everything the cache occupies for this vault.
  final int totalBytes;
  final int blobCount;

  /// Chunks belonging to files that are stored as whole snapshots. For these
  /// the cache is a byte-for-byte second copy of what already sits in the
  /// vault on disk.
  final int binaryBytes;

  /// Chunks belonging to text files — the Fugue blobs. NOT a duplicate of
  /// anything: disk holds the rendered text, this holds the CRDT state that
  /// makes a conflict-free merge possible.
  final int textBytes;

  /// Referenced by nothing this device tracks. Reclaimable right now, by the
  /// GC that already runs; a non-zero figure here means a sweep is overdue.
  final int orphanBytes;

  /// The subset of [binaryBytes] whose file is present on disk, so the bytes
  /// can be regenerated from it (chunking is deterministic) instead of stored.
  /// This is the headroom a disk-backed cache policy would reclaim.
  final int redundantBinaryBytes;

  /// Bytes not attributable to any of the above — a manifest whose owning
  /// state is gone mid-sweep, a sibling sync's blobs.
  int get otherBytes =>
      totalBytes - binaryBytes - textBytes - orphanBytes < 0
          ? 0
          : totalBytes - binaryBytes - textBytes - orphanBytes;
}

/// Weighs the local blob cache and attributes each blob to the file that
/// references it.
class LocalCacheUsageUseCase {
  LocalCacheUsageUseCase({
    required this.store,
    required this.blobStore,
    required this.vaultId,
    this.forcedBinaryExtensions = const <String>{},
    this.fileOnDisk,
  });

  final FileStateStore store;
  final LocalBlobStore blobStore;
  final String vaultId;

  /// The vault-global force-binary policy, so classification here matches the
  /// engine's. Getting it wrong would only misattribute a row, but a report
  /// that disagrees with the engine is worse than no report.
  final Set<String> forcedBinaryExtensions;

  /// Whether a vault-relative path currently exists on disk. Optional: without
  /// it [LocalCacheUsage.redundantBinaryBytes] is reported as zero rather than
  /// guessed, since claiming bytes are redundant when the file may be gone is
  /// exactly the claim that must never be wrong.
  final Future<bool> Function(String relPath)? fileOnDisk;

  Future<LocalCacheUsage> call() async {
    final detector =
        FileTypeDetector(extraBinaryExtensions: forcedBinaryExtensions);

    // blobId -> the paths referencing it. A chunk shared by two files (content
    // addressing does that on purpose) is attributed once, to the first owner.
    final owner = <String, String>{};
    for (final state in store.allValuesFlat) {
      if (state.tombstone) continue;
      if (state.blobRef.isNotEmpty) owner.putIfAbsent(state.blobRef, () => state.path);
      for (final chunk in state.chunks) {
        owner.putIfAbsent(chunk, () => state.path);
      }
    }

    final blobs = await blobStore.listBlobSizes(vaultId: vaultId);

    var totalBytes = 0;
    var binaryBytes = 0;
    var textBytes = 0;
    var orphanBytes = 0;
    final binaryBytesByPath = <String, int>{};

    for (final blob in blobs) {
      totalBytes += blob.sizeBytes;
      final path = owner[blob.id];
      if (path == null) {
        orphanBytes += blob.sizeBytes;
        continue;
      }
      if (detector.isText(path)) {
        textBytes += blob.sizeBytes;
      } else {
        binaryBytes += blob.sizeBytes;
        binaryBytesByPath[path] = (binaryBytesByPath[path] ?? 0) + blob.sizeBytes;
      }
    }

    var redundant = 0;
    final onDisk = fileOnDisk;
    if (onDisk != null) {
      for (final entry in binaryBytesByPath.entries) {
        if (await onDisk(entry.key)) redundant += entry.value;
      }
    }

    return LocalCacheUsage(
      totalBytes: totalBytes,
      blobCount: blobs.length,
      binaryBytes: binaryBytes,
      textBytes: textBytes,
      orphanBytes: orphanBytes,
      redundantBinaryBytes: redundant,
    );
  }
}
