import 'dart:async';
import 'dart:convert';

import 'package:convergent/fugue.dart';
import 'package:uuid/uuid.dart';

import '../chunking/file_type_detector.dart';
import '../engine/sync_engine_event.dart';
import '../platform/i_platform_io.dart';
import '../sync_v3/file_state.dart';
import '../sync_v3/file_state_store.dart';
import '../sync_v3/fugue_store.dart';
import '../sync_v3/fugue_text_sync.dart';

/// Result of a vault repair pass.
class RepairResult {
  const RepairResult({
    required this.total,
    required this.repaired,
    required this.failed,
  });

  final int total;
  final int repaired;
  final int failed;

  @override
  String toString() =>
      'RepairResult(total: $total, repaired: $repaired, failed: $failed)';
}

/// Rebuilds the local CRDT state of every text file in the vault from
/// the file's current disk content, then queues the rebuilt FileStates
/// for push.
///
/// For each text file:
///   1. Read disk bytes.
///   2. Build a clean [Sequence] via [FugueTextSync.seedFromText]
///      (deterministic dots — same bytes on any device produce the
///      same Sequence, so the repaired state converges across peers
///      without re-introducing the duplication bug we just fixed).
///   3. Replace the cached Sequence in [FugueStore] and persist.
///   4. Upload the new Sequence as a fresh blob via the caller-
///      supplied [uploadSequenceBlob] (the engine owns chunking +
///      encryption + remote storage selection; we deliberately do
///      not duplicate that logic here).
///   5. Write a new FileState pointing at the fresh blob under a
///      newly-minted HLC. Since the HLC strictly dominates any prior
///      state, the next `_push` will overwrite the bloated history
///      on the server, and other devices adopt the clean state on
///      their next pull.
///
/// The user's actual file bytes on disk are NOT touched.
class RepairVaultUseCase {
  const RepairVaultUseCase({
    required this.io,
    required this.vaultPath,
    required this.vaultId,
    required this.store,
    required this.fugueStore,
    required this.uploadSequenceBlob,
    required this.emit,
    required this.logWarning,
    this.forcedBinaryExtensions = const <String>{},
  });

  final IPlatformIO io;
  final String vaultPath;
  final String vaultId;
  final FileStateStore store;
  final FugueStore fugueStore;

  /// Snapshot of the vault-global force-binary extension policy, so a
  /// user-forced-binary file is NOT rebuilt as a Fugue text tree here.
  final Set<String> forcedBinaryExtensions;

  /// Caller-supplied uploader. The engine wires this to its
  /// chunked-blob + cipher + remote-storage pipeline so this use case
  /// stays free of those concerns. Returns null when no remote storage
  /// is configured (offline-only); the repair aborts in that case.
  final Future<({String manifestHash, List<String> chunkHashes, int blobSize})?>
      Function(Fugue<String> seq) uploadSequenceBlob;

  /// Caller-supplied event sink — emits the repair lifecycle events so
  /// the UI can show progress and a final summary.
  final void Function(SyncEngineEvent event) emit;

  /// Caller-supplied warning logger — engine and CLI use different
  /// `LogScope` instances and we don't want to take a hard dependency
  /// on either.
  final void Function(String message) logWarning;

  Future<RepairResult> call() async {
    final sw = Stopwatch()..start();
    final all = await io.listFiles(vaultPath);
    final detector =
        FileTypeDetector(extraBinaryExtensions: forcedBinaryExtensions);
    final textPaths = <String>[];
    for (final abs in all) {
      final rel = abs.substring(vaultPath.length + 1);
      if (_isHidden(rel)) continue;
      if (!detector.isText(rel)) continue;
      textPaths.add(rel);
    }

    emit(SyncRepairStarted(totalFiles: textPaths.length));

    var repaired = 0;
    var failed = 0;

    for (final rel in textPaths) {
      try {
        await _repairOne(rel);
        repaired += 1;
      } catch (e) {
        failed += 1;
        logWarning('Repair failed for $rel: $e');
      }
      emit(
        SyncRepairProgress(
          completed: repaired + failed,
          total: textPaths.length,
          currentPath: rel,
        ),
      );
      // Yield between files — keeps host UI responsive on large vaults.
      await Future<void>.delayed(Duration.zero);
    }

    sw.stop();
    emit(
      SyncRepairDone(
        repaired: repaired,
        failed: failed,
        elapsed: sw.elapsed,
      ),
    );
    return RepairResult(
      total: textPaths.length,
      repaired: repaired,
      failed: failed,
    );
  }

  Future<void> _repairOne(String relPath) async {
    final absPath = '$vaultPath/$relPath';
    if (!await io.fileExists(absPath)) return;

    final fileId = const Uuid().v5(vaultId, relPath);
    final bytes = await io.readFile(absPath);
    final text = utf8.decode(bytes, allowMalformed: true);

    // 1-3: deterministic clean seed, replace cache, persist.
    final seq = FugueTextSync.seedFromText(text);
    fugueStore.set(fileId, seq);
    await fugueStore.persistOne(fileId);

    // 4: upload the freshly-seeded Sequence as a new blob.
    final upload = await uploadSequenceBlob(seq);
    if (upload == null) {
      throw StateError(
        'No remote storage configured — cannot push repaired state',
      );
    }

    // 5: dominant FileState under this device's HLC. `applyLocal`
    // marks the entry as locally-modified, so the engine's next
    // `_push` will send it. Any bloated prior version on the server
    // has a strictly smaller HLC and loses the join.
    final hlc = store.nextHlc();
    store.applyLocal(
      FileState(
        fileId: fileId,
        path: relPath,
        blobRef: upload.manifestHash,
        sizeBytes: upload.blobSize,
        hlc: hlc,
        tombstone: false,
        chunks: upload.chunkHashes,
      ),
    );
    await store.persistOne(fileId);
  }

  static bool _isHidden(String relPath) =>
      relPath.split('/').any((s) => s.startsWith('.'));
}
