import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Outcome of a re-upload to the current blob backend.
class ReuploadStorageResult {
  const ReuploadStorageResult({
    required this.files,
    required this.uploadedFiles,
    required this.uploadedBlobs,
    required this.unreproducible,
    this.unreproducibleSample = const [],
  });

  /// Live files considered.
  final int files;

  /// Files whose content reached the backend.
  final int uploadedFiles;

  /// Blobs sent — chunks plus manifests. Reported because it is what the
  /// bandwidth was spent on, while [uploadedFiles] is what the user asked for.
  final int uploadedBlobs;

  /// Files this device cannot rebuild: their bytes live only on another
  /// device. Counted per FILE, because that is the unit a user can act on —
  /// "open the plugin on the laptop and it will push these" is advice; "142
  /// unhealable blobs" is not.
  final int unreproducible;

  /// A capped sample of [unreproducible] paths, for a UI that wants to name
  /// them. Capped because a whole-vault failure would otherwise hand the host
  /// a list as long as the vault.
  final List<String> unreproducibleSample;

  bool get isComplete => unreproducible == 0;

  @override
  String toString() =>
      'ReuploadStorageResult(files=$files, uploadedFiles=$uploadedFiles, '
      'uploadedBlobs=$uploadedBlobs, unreproducible=$unreproducible)';
}

/// Pushes every live file's content to the CURRENT blob backend, whether or
/// not the backend claims to have it.
///
/// Distinct from [VerifyBlobsUseCase], which is an integrity check that heals
/// the holes it finds. The two look similar and differ in three ways that
/// matter after a storage switch:
///
///   * Verify probes first. On a backend that has just been connected the
///     answer is "everything is missing", so the whole `exists` sweep is round
///     trips spent learning that an empty bucket is empty.
///   * Verify uploads the missing ids in id-set order, mixing manifests with
///     chunks. That is safe when it is patching holes in a populated backend
///     and unsafe on an empty one: a manifest visible while a chunk it names
///     is absent is exactly the silent-loss failure the two-phase ordering in
///     [ChunkedBlobIO] exists to prevent. This pass keeps that ordering.
///   * Verify trusts what the backend reports. A half-finished migration that
///     left truncated objects under the right ids reads as clean. A re-upload
///     rewrites regardless, which is what the user asked for when they pressed
///     a button called re-upload.
///
/// [regenerate] is the same hook verify uses, and carries the same guarantee:
/// ids come from the bytes, so a source that has moved on produces ids that
/// match nothing and uploads nothing. It can never publish the WRONG bytes
/// under a referenced id.
class ReuploadStorageUseCase {
  ReuploadStorageUseCase({
    required this.store,
    required this.blobStorage,
    required this.regenerate,
    this.batchLimitBytes = 2 * 1024 * 1024,
    this.onProgress,
    LogScope? logger,
  }) : _log = logger ?? LogScope.noop;

  final FileStateStore store;

  /// MUST be the engine's own upload stack (hub → gzip → encrypt → remote), so
  /// what lands is byte-identical to what the sync path would have written.
  final IBlobStorage blobStorage;

  /// Reproduces a file's blobs from the copy the vault already holds: the
  /// Fugue tree for a note, the file itself for a binary. Returns only the
  /// wanted ids those bytes really produce.
  final Future<Map<String, Uint8List>> Function(
    String relPath,
    Set<String> wantedIds,
  )
  regenerate;

  /// Bytes of chunk payload per upload call.
  final int batchLimitBytes;

  /// (files done, files total).
  final void Function(int done, int total)? onProgress;

  final LogScope _log;

  /// How many paths [ReuploadStorageResult.unreproducibleSample] carries.
  static const int _sampleCap = 20;

  Future<ReuploadStorageResult> call({RpcContext? context}) async {
    final live = <FileState>[];
    for (final state in store.allValuesFlat) {
      if (state.tombstone || state.path.isEmpty) continue;
      live.add(state);
    }
    if (live.isEmpty) {
      return const ReuploadStorageResult(
        files: 0,
        uploadedFiles: 0,
        uploadedBlobs: 0,
        unreproducible: 0,
      );
    }

    _log.info('Storage re-upload: ${live.length} live file(s)');

    var uploadedFiles = 0;
    var uploadedBlobs = 0;
    var unreproducible = 0;
    final sample = <String>[];
    var done = 0;

    // One group's worth of work, held until it is big enough to be worth two
    // round trips. Manifests are kept apart from chunks for the whole group,
    // not per file — the stricter reading of manifest-last, and the one
    // [ChunkedBlobIO.uploadAll] already applies to the startup path.
    var chunks = <(Uint8List, String)>[];
    var manifests = <(Uint8List, String)>[];
    var pendingFiles = 0;
    var pendingBytes = 0;

    Future<void> flush() async {
      if (chunks.isEmpty && manifests.isEmpty) return;
      context?.cancellationToken?.throwIfCancelled();
      // Phase 1: every chunk of every file in the group. Cut here and no
      // manifest was sent at all, so nothing published points at anything
      // missing.
      if (chunks.isNotEmpty) {
        await blobStorage.upload(chunks, context: context);
        uploadedBlobs += chunks.length;
      }
      // Phase 2: the manifests those chunks belong to.
      if (manifests.isNotEmpty) {
        await blobStorage.upload(manifests, context: context);
        uploadedBlobs += manifests.length;
      }
      uploadedFiles += pendingFiles;
      chunks = <(Uint8List, String)>[];
      manifests = <(Uint8List, String)>[];
      pendingFiles = 0;
      pendingBytes = 0;
    }

    for (final state in live) {
      context?.cancellationToken?.throwIfCancelled();
      done++;
      onProgress?.call(done, live.length);

      final wanted = <String>{
        if (state.blobRef.isNotEmpty) state.blobRef,
        ...state.chunks,
      };
      if (wanted.isEmpty) continue;

      Map<String, Uint8List> produced;
      try {
        produced = await regenerate(state.path, wanted);
      } catch (e) {
        // A path, so declared rather than interpolated — the shared log
        // carries a pseudonym for it.
        _log.warning(
          'Storage re-upload: cannot rebuild: $e',
          data: {'path': LogPath(state.path)},
        );
        produced = const {};
      }

      // Without the manifest the chunks are unreachable: a peer resolves
      // content by manifest, so uploading loose chunks would spend bandwidth
      // to leave the file exactly as missing as it was.
      if (state.blobRef.isNotEmpty && !produced.containsKey(state.blobRef)) {
        unreproducible++;
        if (sample.length < _sampleCap) sample.add(state.path);
        continue;
      }

      for (final entry in produced.entries) {
        if (entry.key == state.blobRef) {
          manifests.add((entry.value, entry.key));
        } else {
          chunks.add((entry.value, entry.key));
          pendingBytes += entry.value.length;
        }
      }
      pendingFiles++;
      if (pendingBytes >= batchLimitBytes) await flush();
    }
    await flush();

    final result = ReuploadStorageResult(
      files: live.length,
      uploadedFiles: uploadedFiles,
      uploadedBlobs: uploadedBlobs,
      unreproducible: unreproducible,
      unreproducibleSample: List.unmodifiable(sample),
    );
    _log.info('Storage re-upload: $result');
    return result;
  }
}
