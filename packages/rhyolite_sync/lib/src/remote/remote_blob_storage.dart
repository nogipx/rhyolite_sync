import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

const _chunkSize = 256 * 1024;

class RemoteBlobStorage implements IBlobStorage {
  RemoteBlobStorage({
    required BlobContractCaller caller,
    required this.vaultId,
    IVaultCipher? cipher,
  }) : _caller = caller,
       _cipher = cipher;

  final BlobContractCaller _caller;
  final String vaultId;
  final IVaultCipher? _cipher;

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    if (blobIds.isEmpty) return {};
    final stream = _caller.download(
      BulkDownloadBlobRequest(vaultId: vaultId, blobIds: blobIds),
      context: context,
    );
    final result = <String, Uint8List>{};
    String? currentBlobId;
    BytesBuilder? currentBuilder;
    await for (final chunk in stream) {
      if (chunk.blobId != null) {
        currentBlobId = chunk.blobId;
        currentBuilder = BytesBuilder();
      }
      currentBuilder?.add(chunk.bytes);
      if (chunk.last && currentBlobId != null && currentBuilder != null) {
        final raw = currentBuilder.takeBytes();
        final cipher = _cipher;
        // Yield before ChaCha20 decrypt — symmetric reason to the
        // upload path: decrypting a 700KB blob is sync CPU on the
        // main JS thread.
        await Future<void>.delayed(Duration.zero);
        result[currentBlobId] = cipher != null
            ? await cipher.decrypt(raw)
            : raw;
        currentBlobId = null;
        currentBuilder = null;
      }
    }
    return result;
  }

  @override
  Future<void> upload(
    List<(Uint8List bytes, String blobId)> blobs, {
    RpcContext? context,
  }) async {
    if (blobs.isEmpty) return;
    // upload is a client-stream, so the unary RpcRetryInterceptor can't replay
    // it — retry here. `_toBulkChunks` rebuilds the stream from the in-memory
    // list each attempt and content-addressed uploads are idempotent, so a
    // re-attempt is safe. Backs off on the server's RESOURCE_EXHAUSTED rate
    // limit (parallel startup uploads) and UNAVAILABLE.
    final sentIds = blobs.map((b) => b.$2).toSet();
    for (var attempt = 0; ; attempt++) {
      try {
        final resp =
            await _caller.upload(_toBulkChunks(blobs, context), context: context);
        // Durability check: the server acks the ids it actually stored. If
        // any sent blob is missing from the ack, the upload silently dropped
        // it (rate-limit mid-stream, dedup edge, lost frame) — treat as a
        // retryable failure rather than reporting success. Without this a
        // manifest can be committed while its content chunk never landed,
        // leaving a referenced-but-absent blob that no re-upload heals.
        final acked = resp.blobIds.toSet();
        final notAcked = sentIds.difference(acked);
        if (notAcked.isEmpty) return;
        if (attempt >= _uploadMaxAttempts - 1) {
          final sample = notAcked
              .take(3)
              .map((h) => h.length <= 8 ? h : h.substring(0, 8))
              .join(',');
          throw StateError(
            'blob upload not acknowledged: ${notAcked.length}/${sentIds.length} '
            'missing from server ack (e.g. $sample)',
          );
        }
        context?.cancellationToken?.throwIfCancelled();
        await Future<void>.delayed(_uploadBackoff.delayFor(attempt));
      } on RpcStatusException catch (e) {
        // The first client-stream frame after a fresh WebSocket connect
        // occasionally reaches the server without its blobId/vaultId
        // metadata, which the responder rejects as INTERNAL(13) "First chunk
        // must carry blobId and vaultId". It's thrown before any blob is
        // stored, and `_toBulkChunks` rebuilds the stream from the in-memory
        // list, so re-sending is safe and idempotent — retry it like the
        // backpressure codes instead of failing the upload.
        final retryable = e.statusCode == RpcStatus.resourceExhausted ||
            e.statusCode == RpcStatus.unavailable ||
            (e.statusCode == RpcStatus.internal &&
                e.message.contains('First chunk must carry'));
        if (!retryable || attempt >= _uploadMaxAttempts - 1) rethrow;
        context?.cancellationToken?.throwIfCancelled();
        await Future<void>.delayed(_uploadBackoff.delayFor(attempt));
      }
    }
  }

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    if (blobIds.isEmpty) return {};
    final resp = await _caller.bulkExists(
      BulkExistsBlobRequest(vaultId: vaultId, blobIds: blobIds),
      context: context,
    );
    return resp.presentIds.toSet();
  }

  static const _uploadMaxAttempts = 5;
  static const _uploadBackoff = ExponentialBackoff(
    baseDelay: Duration(milliseconds: 200),
    maxDelay: Duration(seconds: 5),
  );

  @override
  Future<void> deleteMany(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    if (blobIds.isEmpty) return;
    await _caller.bulkDelete(
      BulkDeleteBlobsRequest(vaultId: vaultId, blobIds: blobIds),
      context: context,
    );
  }

  Stream<BlobChunk> _toBulkChunks(
    List<(Uint8List bytes, String blobId)> blobs,
    RpcContext? context,
  ) async* {
    for (final (rawBytes, blobId) in blobs) {
      // Cooperative cancellation check between blobs — lets a typing
      // event abort multi-blob batches before encrypt + yield burn CPU.
      context?.cancellationToken?.throwIfCancelled();
      // Yield before each ChaCha20 encrypt — encrypting a 700KB blob
      // on dart2js is ~100-300ms of pure synchronous CPU. Without this
      // yield uploading multiple blobs in one call freezes Obsidian
      // for the whole batch.
      await Future<void>.delayed(Duration.zero);
      final cipher = _cipher;
      final data = cipher != null ? await cipher.encrypt(rawBytes) : rawBytes;
      yield* _toChunks(data, blobId);
    }
  }

  Stream<BlobChunk> _toChunks(Uint8List bytes, String blobId) async* {
    // Always yield at least one chunk to carry blobId/vaultId metadata.
    // An empty stream causes the server to throw before returning a response,
    // which the RPC framework doesn't propagate — resulting in a 30s timeout.
    if (bytes.isEmpty) {
      yield BlobChunk(
        bytes: Uint8List(0),
        offset: 0,
        last: true,
        blobId: blobId,
        vaultId: vaultId,
      );
      return;
    }
    var offset = 0;
    var first = true;
    while (offset < bytes.length) {
      final end = (offset + _chunkSize).clamp(0, bytes.length);
      yield BlobChunk(
        bytes: bytes.sublist(offset, end),
        offset: offset,
        last: end == bytes.length,
        blobId: first ? blobId : null,
        vaultId: first ? vaultId : null,
        totalLength: first ? bytes.length : null,
      );
      offset = end;
      first = false;
    }
  }
}
