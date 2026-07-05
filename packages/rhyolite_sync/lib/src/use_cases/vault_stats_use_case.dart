import '../sync_v3/file_state_store.dart';

/// Aggregate statistics about a vault's current sync state.
///
/// Read-only against [FileStateStore]. Safe to call frequently — works
/// directly on in-memory data with no IO.
class VaultStatsUseCase {
  VaultStatsUseCase(this._store);

  final FileStateStore _store;

  VaultStats call() {
    var totalFiles = 0;
    var tombstones = 0;
    var conflicting = 0;
    var totalSizeBytes = 0;
    final uniqueBlobs = <String>{};

    for (final fileId in _store.fileIds) {
      final reg = _store.registerFor(fileId);
      if (reg == null || reg.values.isEmpty) continue;
      totalFiles++;
      if (reg.hasConflict) conflicting++;
      for (final tv in reg.values) {
        final s = tv.value;
        if (s.tombstone) {
          tombstones++;
        } else {
          totalSizeBytes += s.sizeBytes;
          if (s.blobRef.isNotEmpty) uniqueBlobs.add(s.blobRef);
          uniqueBlobs.addAll(s.chunks);
        }
      }
    }

    return VaultStats(
      totalFiles: totalFiles,
      tombstones: tombstones,
      conflicting: conflicting,
      uniqueBlobs: uniqueBlobs.length,
      totalSizeBytes: totalSizeBytes,
      serverCursor: _store.serverCursor,
      serverEpoch: _store.serverEpoch,
    );
  }
}

class VaultStats {
  const VaultStats({
    required this.totalFiles,
    required this.tombstones,
    required this.conflicting,
    required this.uniqueBlobs,
    required this.totalSizeBytes,
    required this.serverCursor,
    this.serverEpoch,
  });

  /// Number of distinct fileIds in the local store (including tombstones).
  final int totalFiles;

  /// How many of [totalFiles] are tombstoned (single tombstone TaggedValue
  /// or every TaggedValue in the register is a tombstone).
  final int tombstones;

  /// Number of fileIds whose register has more than one surviving value.
  final int conflicting;

  /// Distinct blob hashes (manifests + chunks) currently referenced.
  final int uniqueBlobs;

  /// Sum of sizeBytes across non-tombstone TaggedValues. May overcount
  /// when a fileId has multi-value register — each surviving value
  /// contributes — but that's the correct "storage footprint" answer.
  final int totalSizeBytes;

  final int serverCursor;
  final int? serverEpoch;
}
