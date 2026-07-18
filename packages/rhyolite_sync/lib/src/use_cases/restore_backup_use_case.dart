import 'dart:typed_data';

import '../contract/backup_contract.dart' show GetBackupResponse;
import '../contract/state_sync_contract.dart' show StateRecord;
import '../platform/i_platform_io.dart';
import '../sync_v3/file_state.dart';

/// Restores a backup snapshot IN PLACE: it writes each frozen file back to its
/// original path under [targetRoot] (= the vault root), so the restore syncs as
/// a normal edit and stays reversible through file history — no scratch folder
/// that would itself sync as a pile of new files.
///
/// It only writes files whose content DIFFERS from the current vault
/// ([currentLiveBlobByPath]): a file identical to what's on disk is skipped
/// (writing it would be needless churn). A path with concurrent versions is
/// resolved to its max-HLC value (LWW), the same one the engine materialises;
/// a tombstoned effective version is skipped — a restore never deletes.
///
/// Per record it decrypts the envelope (to recover the path), downloads +
/// materialises the content, and writes it. Reuses the same decrypt/download the
/// live pull uses; the caller wires them so this stays testable.
class RestoreBackupUseCase {
  RestoreBackupUseCase({
    required this.records,
    required this.decodeRecord,
    required this.downloadContent,
    required this.targetIO,
    required this.targetRoot,
    this.currentLiveBlobByPath = const {},
  });

  /// The snapshot's frozen records (from [GetBackupResponse.records]).
  final List<StateRecord> records;

  /// Decrypts + parses one record's envelope into a [FileState] (path/blobRef/
  /// tombstone). In the engine: `(r) async => (await codec.decode(r)).value`.
  final Future<FileState> Function(StateRecord record) decodeRecord;

  /// Downloads a blob and materialises it into the on-disk file bytes by its
  /// manifest ref + path, or null if unavailable. The path matters: text is
  /// stored as the Fugue serialization and must be projected to plain text
  /// before writing. In the engine: download + `materializeFileContent`.
  final Future<Uint8List?> Function(String blobRef, String path) downloadContent;

  final IPlatformIO targetIO;

  /// Write-path prefix — the vault root, so files land at their original path.
  final String targetRoot;

  /// path -> blobRef of every live file now; a match means "identical", skip it.
  final Map<String, String> currentLiveBlobByPath;

  Future<RestoreReport> call({
    void Function(int completed, int total)? onProgress,
  }) async {
    final report = RestoreReport();

    // Decode every record, group by path (path <-> fileId is 1:1).
    final byPath = <String, List<FileState>>{};
    for (final r in records) {
      try {
        final state = await decodeRecord(r);
        (byPath[state.path] ??= <FileState>[]).add(state);
      } catch (e) {
        report.errors.add('decode failed: $e');
      }
    }

    // Resolve each path to its effective version — the max-HLC value (LWW), the
    // same one the engine materialises. Skip ones identical to what's on disk.
    final restorable = <FileState>[];
    for (final versions in byPath.values) {
      final winner = versions.reduce((a, b) => b.hlc > a.hlc ? b : a);
      if (winner.tombstone) {
        report.skippedTombstones++;
      } else if (currentLiveBlobByPath[winner.path] == winner.blobRef) {
        report.skippedIdentical++;
      } else {
        restorable.add(winner);
      }
    }

    final total = restorable.length;
    onProgress?.call(0, total);
    var done = 0;
    for (final state in restorable) {
      try {
        final bytes = await downloadContent(state.blobRef, state.path);
        if (bytes == null) {
          report.errors.add('${state.path}: blob ${state.blobRef} unavailable');
        } else {
          await targetIO.writeFile('$targetRoot/${state.path}', bytes);
          report.restoredFiles++;
          report.restoredBytes += bytes.length;
        }
      } catch (e) {
        report.errors.add('${state.path}: $e');
      }
      onProgress?.call(++done, total);
    }
    return report;
  }
}

class RestoreReport {
  int restoredFiles = 0;
  int restoredBytes = 0;
  int skippedTombstones = 0;
  int skippedIdentical = 0;
  final List<String> errors = [];

  bool get success => errors.isEmpty;
}
