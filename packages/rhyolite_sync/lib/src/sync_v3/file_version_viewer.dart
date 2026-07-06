import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:uuid/uuid.dart';

import 'path_normalize.dart';

/// Per-file version viewer. Lists every historical write for one file,
/// fetches and decrypts the bytes of any past version, and can restore
/// a chosen version to disk.
///
/// "Restore" is just `writeFile` with the selected version's content. The
/// engine's normal file-change watcher then picks it up, computes the
/// new blobRef, and pushes a fresh state — creating a new modify event
/// in history. No special server flow needed.
class FileVersionViewer {
  FileVersionViewer({
    required this.browser,
    required this.remoteBlobStorage,
    required this.localBlobStore,
    required this.io,
    required this.changeProvider,
    required this.vaultPath,
    required this.vaultId,
  });

  final HistoryBrowser browser;
  final IBlobStorage remoteBlobStorage;
  final LocalBlobStore localBlobStore;
  final IPlatformIO io;
  final IChangeProvider changeProvider;
  final String vaultPath;
  final String vaultId;

  String _fileIdFor(String relPath) =>
      const Uuid().v5(vaultId, normalizeVaultPath(relPath));

  /// All recorded versions for the file at [relPath], newest first.
  Future<List<HistoryEntry>> versionsOf(String relPath) =>
      browser.list(fileId: _fileIdFor(relPath));

  /// Fetch the plain bytes for a particular version. Returns null if the
  /// blob can't be located locally or remotely (retention dropped it).
  Future<Uint8List?> contentAt(HistoryEntry entry) async {
    if (entry.blobRef.isEmpty) return null;
    final cached = await localBlobStore.read(entry.blobRef, vaultId: vaultId);
    if (cached != null) return cached;
    try {
      final downloaded = await remoteBlobStorage.download([entry.blobRef]);
      final bytes = downloaded[entry.blobRef];
      if (bytes != null) {
        await localBlobStore.write(bytes, entry.blobRef, vaultId: vaultId);
        return bytes;
      }
    } catch (_) {}
    return null;
  }

  /// Restore the file content of [entry] to disk at its recorded path.
  /// The engine's file-change watcher will pick up the write and emit
  /// a new modify event in history. Throws when the blob is no longer
  /// available anywhere.
  Future<void> restore(HistoryEntry entry) async {
    final bytes = await contentAt(entry);
    if (bytes == null) {
      throw StateError(
        'Blob ${entry.blobRef.substring(0, 8)} for ${entry.path} '
        'is no longer available',
      );
    }
    final fullPath = '$vaultPath/${entry.path}';
    // Do NOT suppress the change event — we want the engine to pick it
    // up, push a new state and write a fresh history record describing
    // this restore. That preserves an audit trail.
    await io.writeFile(fullPath, bytes);
  }
}
