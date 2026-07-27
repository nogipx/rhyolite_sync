import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Result of a blob-integrity verification pass.
class VerifyBlobsResult {
  const VerifyBlobsResult({
    required this.referenced,
    required this.missing,
    required this.reuploaded,
    required this.unhealable,
  });

  /// Distinct blob ids referenced by live (non-tombstone) file states —
  /// manifests (`blobRef`) plus every content chunk.
  final int referenced;

  /// How many of [referenced] the server reported as absent.
  final int missing;

  /// How many missing blobs were found in the local cache and re-uploaded.
  final int reuploaded;

  /// How many missing blobs could NOT be healed because their bytes are
  /// not in the local cache (content lives only on another device).
  final int unhealable;

  bool get isClean => missing == 0;

  @override
  String toString() =>
      'VerifyBlobsResult(referenced=$referenced, missing=$missing, '
      'reuploaded=$reuploaded, unhealable=$unhealable)';
}

/// Verifies that every blob referenced by the current file states is
/// actually present on the server, and re-uploads any that are missing
/// from the local cache.
///
/// Why this exists: the upload path treated "this device has the chunk
/// locally" as "the server has the chunk" (the `knownChunks` dedup), so a
/// content chunk whose upload was silently lost (rate-limit mid-stream,
/// transport drop) became permanently absent — its manifest re-uploaded
/// fine but the chunk never did, and the file failed to materialise on
/// other devices. This pass is the authoritative reconciliation: it asks
/// the server which referenced blobs it really holds ([IBlobStorage.exists])
/// and re-pushes the rest from the local cache (content-addressed, so the
/// re-upload is idempotent).
///
/// [blobStorage] MUST be the same upload stack the engine uses for chunks
/// (hub → gzip → encrypt → remote) so a re-upload reproduces the original
/// bytes exactly. [localBlobStore] supplies the plain chunk bytes.
class VerifyBlobsUseCase {
  VerifyBlobsUseCase({
    required this.store,
    required this.blobStorage,
    required this.localBlobStore,
    required this.vaultId,
    this.existsBatch = 128,
    this.uploadBatch = 64,
    this.confirmedPresent,
    LogScope? logger,
  }) : _log = logger ?? LogScope.noop;

  final FileStateStore store;
  final IBlobStorage blobStorage;
  final LocalBlobStore localBlobStore;
  final String vaultId;

  /// Max ids probed per [IBlobStorage.exists] call. Kept well under the RPC
  /// call timeout so a large vault doesn't push a single bulk probe past it.
  final int existsBatch;

  /// Max blobs re-uploaded per [IBlobStorage.upload] call.
  final int uploadBatch;

  /// Ids the server has already confirmed it holds, carried ACROSS runs by the
  /// caller. This pass is preemptible and restarts from the top when it yields,
  /// so without somewhere to keep its findings a device that gets interrupted
  /// every few seconds re-probes the same blobs forever and never reaches a
  /// verdict. Ids found MISSING are deliberately not recorded — they may have
  /// been healed since, and must be probed again.
  ///
  /// Owned per session: a blob confirmed present can later be swept away
  /// server-side, and this pass exists to catch lost uploads, not deletions.
  final Set<String>? confirmedPresent;

  final LogScope _log;

  Future<VerifyBlobsResult> call({RpcContext? context}) async {
    final referenced = <String>{};
    for (final state in store.allValuesFlat) {
      if (state.tombstone) continue;
      if (state.blobRef.isNotEmpty) referenced.add(state.blobRef);
      referenced.addAll(state.chunks);
    }

    if (referenced.isEmpty) {
      return const VerifyBlobsResult(
        referenced: 0,
        missing: 0,
        reuploaded: 0,
        unhealable: 0,
      );
    }

    final refList = referenced.toList();
    final confirmed = confirmedPresent ?? <String>{};
    final present = <String>{};
    for (var i = 0; i < refList.length; i += existsBatch) {
      // Yielding here discards this run — everything learned so far survives
      // only because [confirmed] belongs to the caller.
      context?.cancellationToken?.throwIfCancelled();
      final end =
          (i + existsBatch) > refList.length ? refList.length : i + existsBatch;
      final slice = refList.sublist(i, end);
      final toProbe = slice.where((id) => !confirmed.contains(id)).toList();
      if (toProbe.isNotEmpty) {
        confirmed.addAll(await blobStorage.exists(toProbe, context: context));
      }
      present.addAll(slice.where(confirmed.contains));
    }
    final missing = referenced.difference(present);
    if (missing.isEmpty) {
      _log.info('Blob verify: ${referenced.length} referenced, all present');
      return VerifyBlobsResult(
        referenced: referenced.length,
        missing: 0,
        reuploaded: 0,
        unhealable: 0,
      );
    }

    _log.warning(
      'Blob verify: ${missing.length}/${referenced.length} referenced blob(s) '
      'absent on server — attempting heal from local cache',
    );

    final toUpload = <(Uint8List, String)>[];
    var unhealable = 0;
    for (final id in missing) {
      context?.cancellationToken?.throwIfCancelled();
      final bytes = await localBlobStore.read(id, vaultId: vaultId);
      if (bytes == null) {
        unhealable++;
        final tag = id.length <= 8 ? id : id.substring(0, 8);
        _log.warning(
          'Blob verify: $tag missing on server and not in '
          'local cache — cannot heal from this device',
        );
        continue;
      }
      toUpload.add((bytes, id));
    }

    var reuploaded = 0;
    for (var i = 0; i < toUpload.length; i += uploadBatch) {
      context?.cancellationToken?.throwIfCancelled();
      final end =
          (i + uploadBatch) > toUpload.length ? toUpload.length : i + uploadBatch;
      final batch = toUpload.sublist(i, end);
      await blobStorage.upload(batch, context: context);
      reuploaded += batch.length;
    }

    _log.info(
      'Blob verify: referenced=${referenced.length} missing=${missing.length} '
      'reuploaded=$reuploaded unhealable=$unhealable',
    );
    return VerifyBlobsResult(
      referenced: referenced.length,
      missing: missing.length,
      reuploaded: reuploaded,
      unhealable: unhealable,
    );
  }
}
