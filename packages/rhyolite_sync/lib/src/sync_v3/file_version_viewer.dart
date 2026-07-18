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
    required ChunkedBlobIO? Function() chunkedIOBuilder,
    required this.io,
    required this.changeProvider,
    required this.vaultPath,
    required this.vaultId,
  }) : _chunkedIOBuilder = chunkedIOBuilder;

  final HistoryBrowser browser;

  /// Builds a [ChunkedBlobIO] over the live connection. History content lives
  /// as a chunk manifest (blobRef = manifest hash), so content MUST be
  /// assembled through this — reading the manifest blob directly hands back its
  /// JSON, not the file. Null when there's no connection (no content then).
  final ChunkedBlobIO? Function() _chunkedIOBuilder;
  final IPlatformIO io;
  final IChangeProvider changeProvider;
  final String vaultPath;
  final String vaultId;

  String _fileIdFor(String relPath) =>
      const Uuid().v5(vaultId, normalizeVaultPath(relPath));

  /// All recorded versions for the file at [relPath], newest first.
  Future<List<HistoryEntry>> versionsOf(String relPath) =>
      browser.list(fileId: _fileIdFor(relPath));

  /// Materialise a past version to the actual file bytes: assemble the chunk
  /// manifest, then — for text files — project the Fugue tree to plain text
  /// (text content is stored as the CRDT serialization, not the raw document).
  /// Returns null if the blob is gone (retention) or there's no live
  /// connection. Pure read — never mutates the live Fugue tree.
  Future<Uint8List?> contentAt(HistoryEntry entry) async {
    if (entry.blobRef.isEmpty) return null;
    final chunkedIO = _chunkedIOBuilder();
    if (chunkedIO == null) return null;
    Uint8List? bytes;
    try {
      bytes = await chunkedIO.download(entry.blobRef);
    } catch (_) {
      return null;
    }
    if (bytes == null) return null;
    // Text is stored as the Fugue serialization; a legacy Sequence blob decodes
    // to null (unavailable). Shared with backup restore/diff via one helper.
    return materializeFileContent(bytes, entry.path);
  }

  /// Current on-disk bytes for [relPath], or null when the file no longer
  /// exists (e.g. deleted). Lets the UI diff a past version against what's
  /// live on disk ("what restoring would change").
  Future<Uint8List?> currentContent(String relPath) async {
    final fullPath = '$vaultPath/$relPath';
    try {
      if (!await io.fileExists(fullPath)) return null;
      return await io.readFile(fullPath);
    } catch (_) {
      return null;
    }
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
