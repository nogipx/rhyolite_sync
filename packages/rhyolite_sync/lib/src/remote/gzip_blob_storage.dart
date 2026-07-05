import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:rpc_dart/rpc_dart.dart';

import 'i_blob_storage.dart';

/// Wraps any [IBlobStorage] with always-on gzip on upload + auto-detect
/// decompress on download.
///
/// Write path: every blob is gzipped before being passed to [inner].
/// No size check, no flag — uniform single path. The gzip overhead for
/// already-incompressible data (PDF, JPEG, encrypted blobs further down
/// the chain) is ~18 bytes per blob; for highly redundant payloads
/// (Fugue tree JSON, plain text) the win is 3–5×.
///
/// Read path: try gzip-decode; on any decoder failure fall through and
/// return the bytes unchanged. This makes the decorator backwards
/// compatible with any blob already on the server that was uploaded
/// before this layer existed — gzip has a magic header (`1f 8b`) and a
/// CRC32 trailer, so a non-gzip payload reliably fails the decoder
/// instead of silently producing wrong bytes.
///
/// Position in the chain: gzip MUST sit above encryption. Encrypted
/// data is high-entropy and gzip can't compress it; gzip on plain
/// bytes, then encrypt the result, then send.
///
///   ChunkedBlobIO → BlobTransferHub → **GzipBlobStorage** →
///   EncryptedBlobStorage (or backend that encrypts internally) → wire
class GzipBlobStorage implements IBlobStorage {
  const GzipBlobStorage({required this.inner});

  final IBlobStorage inner;

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    final raw = await inner.download(blobIds, context: context);
    final result = <String, Uint8List>{};
    for (final entry in raw.entries) {
      context?.cancellationToken?.throwIfCancelled();
      result[entry.key] = _maybeDecompress(entry.value);
    }
    return result;
  }

  @override
  Future<void> upload(
    List<(Uint8List bytes, String blobId)> blobs, {
    RpcContext? context,
  }) async {
    final compressed = <(Uint8List, String)>[];
    for (final (bytes, blobId) in blobs) {
      context?.cancellationToken?.throwIfCancelled();
      compressed.add((_compress(bytes), blobId));
    }
    await inner.upload(compressed, context: context);
  }

  @override
  Future<void> deleteMany(
    List<String> blobIds, {
    RpcContext? context,
  }) =>
      inner.deleteMany(blobIds, context: context);

  // Ids are content hashes of the plain bytes, unaffected by gzip —
  // presence is a pure passthrough.
  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    RpcContext? context,
  }) =>
      inner.exists(blobIds, context: context);

  Uint8List _compress(Uint8List bytes) {
    final encoded = GZipEncoder().encode(bytes);
    return Uint8List.fromList(encoded);
  }

  Uint8List _maybeDecompress(Uint8List bytes) {
    try {
      final decoded = GZipDecoder().decodeBytes(bytes);
      return Uint8List.fromList(decoded);
    } catch (_) {
      // Not a gzip stream — bytes predate this decorator. Pass through.
      return bytes;
    }
  }
}
