import '../local/local_blob_store.dart';
import '../platform/i_platform_io.dart';
import '../sync_v3/chunked_blob_io.dart';
import '../sync_v3/file_state.dart';
import '../sync_v3/file_state_store.dart';

/// Export every live file in the vault to plain bytes on disk.
///
/// Escape hatch — lets the user walk away with their data even if the
/// sync server is down or the vendor disappears. Reads only from the
/// local in-memory store and the local + remote blob caches. Skips
/// tombstones and multi-value registers (caller can fetch those
/// separately via [ConflictListUseCase] if they want to handle them).
///
/// The destination is the user's choice — supply an [IPlatformIO] that
/// writes wherever you want (filesystem on desktop, Obsidian vault file
/// API on the plugin, or a custom adapter that builds a zip in memory).
class ExportVaultUseCase {
  ExportVaultUseCase({
    required this.store,
    required this.chunkedBlobIO,
    required this.targetIO,
    required this.targetRoot,
    required this.localBlobStore,
    required this.vaultId,
  });

  final FileStateStore store;
  final ChunkedBlobIO chunkedBlobIO;
  final IPlatformIO targetIO;
  final String targetRoot;
  final LocalBlobStore localBlobStore;
  final String vaultId;

  /// Performs the export. Returns a [ExportReport] summarising what
  /// happened. [onProgress] is invoked after each file with the
  /// (completed, total) counter so a UI can show a progress bar.
  Future<ExportReport> call({
    void Function(int completed, int total)? onProgress,
  }) async {
    final report = ExportReport();
    final exportable = <FileState>[];
    for (final fileId in store.fileIds) {
      final reg = store.registerFor(fileId);
      if (reg == null || reg.hasConflict) {
        if (reg != null && reg.hasConflict) report.skippedConflicted++;
        continue;
      }
      final state = reg.singleValue;
      if (state == null || state.tombstone) {
        if (state?.tombstone ?? false) report.skippedTombstones++;
        continue;
      }
      exportable.add(state);
    }

    final total = exportable.length;
    onProgress?.call(0, total);
    var done = 0;
    for (final state in exportable) {
      try {
        var bytes = await localBlobStore.read(state.blobRef, vaultId: vaultId);
        bytes ??= await chunkedBlobIO.download(state.blobRef);
        if (bytes == null) {
          report.errors.add('${state.path}: blob ${state.blobRef} unavailable');
          continue;
        }
        final fullPath = '$targetRoot/${state.path}';
        await targetIO.writeFile(fullPath, bytes);
        report.exportedFiles++;
        report.exportedBytes += bytes.length;
      } catch (e) {
        report.errors.add('${state.path}: $e');
      }
      done++;
      onProgress?.call(done, total);
    }
    return report;
  }
}

class ExportReport {
  int exportedFiles = 0;
  int exportedBytes = 0;
  int skippedTombstones = 0;
  int skippedConflicted = 0;
  final List<String> errors = [];

  bool get success => errors.isEmpty;
}
