import '../contract/state_sync_contract.dart' show StateRecord;
import '../sync_v3/file_state.dart';

/// How a file in a restore point compares to the vault as it is NOW — the basis
/// for the "what changed / what will I restore" preview. Because content is
/// content-addressed, "changed" is an exact `blobRef` mismatch, computed without
/// decrypting anything (fileId + blobRef are cleartext; the path is only decoded
/// for display).
enum BackupEntryStatus {
  /// Same path + same blobRef as the current vault — restoring is a no-op.
  identical,

  /// Present now but with different content — restoring brings back the older
  /// version (overwritten into the restore folder, live file untouched).
  changed,

  /// Absent now (deleted or tombstoned since) — restoring brings it back.
  restoresDeleted,

  /// Tombstoned in the snapshot itself — a delete was captured; not restored.
  deletedInBackup,
}

class BackupEntry {
  const BackupEntry({
    required this.path,
    required this.sizeBytes,
    required this.status,
    required this.blobRef,
  });

  final String path;
  final int sizeBytes;
  final BackupEntryStatus status;

  /// The snapshot version's content ref (empty for tombstones) — lets the UI
  /// fetch the frozen content for a per-file diff.
  final String blobRef;

  /// Whether restoring this entry actually writes a file to the restore folder.
  bool get willRestore =>
      status == BackupEntryStatus.changed ||
      status == BackupEntryStatus.restoresDeleted ||
      status == BackupEntryStatus.identical;
}

/// Inspects a restore point against the current vault, producing a per-file
/// status list (sorted by path) for a tree view + a summary. Pure and injected
/// like [RestoreBackupUseCase] so it stays testable without a cipher/transport.
class InspectBackupUseCase {
  InspectBackupUseCase({
    required this.records,
    required this.decodeRecord,
    required this.currentLiveBlobByPath,
  });

  /// The snapshot's frozen records (from `GetBackupResponse.records`).
  final List<StateRecord> records;

  /// Decrypts + parses one record's envelope into a [FileState].
  final Future<FileState> Function(StateRecord record) decodeRecord;

  /// path -> blobRef of every live (non-tombstone) file in the vault right now.
  final Map<String, String> currentLiveBlobByPath;

  Future<BackupInspection> call() async {
    final byPath = <String, List<FileState>>{};
    for (final r in records) {
      try {
        final state = await decodeRecord(r);
        (byPath[state.path] ??= <FileState>[]).add(state);
      } catch (_) {
        // Undecodable record (key mismatch / corruption) — skip it.
      }
    }

    final entries = <BackupEntry>[];
    for (final e in byPath.entries) {
      final path = e.key;
      // The effective version is the max-HLC value (LWW) — exactly what the
      // engine materialises on disk. Concurrent binary values are an unresolved
      // multi-value register, NOT a user conflict, so we resolve, never "skip".
      final winner = e.value.reduce((a, b) => b.hlc > a.hlc ? b : a);
      if (winner.tombstone) {
        entries.add(BackupEntry(
          path: path,
          sizeBytes: 0,
          status: BackupEntryStatus.deletedInBackup,
          blobRef: '',
        ));
        continue;
      }
      final current = currentLiveBlobByPath[path];
      final status = current == null
          ? BackupEntryStatus.restoresDeleted
          : (current == winner.blobRef
              ? BackupEntryStatus.identical
              : BackupEntryStatus.changed);
      entries.add(BackupEntry(
        path: path,
        sizeBytes: winner.sizeBytes,
        status: status,
        blobRef: winner.blobRef,
      ));
    }

    entries.sort((a, b) => a.path.compareTo(b.path));
    return BackupInspection(entries: entries);
  }
}

class BackupInspection {
  BackupInspection({required this.entries});

  final List<BackupEntry> entries;

  int _count(BackupEntryStatus s) =>
      entries.where((e) => e.status == s).length;

  int get identical => _count(BackupEntryStatus.identical);
  int get changed => _count(BackupEntryStatus.changed);
  int get restoresDeleted => _count(BackupEntryStatus.restoresDeleted);
  int get deletedInBackup => _count(BackupEntryStatus.deletedInBackup);

  /// Files whose content differs from now (or are absent now) — the meaningful
  /// result of a restore.
  int get differing => changed + restoresDeleted;
}
