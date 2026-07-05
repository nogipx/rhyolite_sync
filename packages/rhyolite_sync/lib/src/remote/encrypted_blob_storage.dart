import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Wraps any [IBlobStorage] with optional encrypt-on-upload / decrypt-on-download.
///
/// When [cipher] is null, data passes through unchanged.
class EncryptedBlobStorage implements IBlobStorage {
  const EncryptedBlobStorage({
    required this.inner,
    required this.cipher,
  });

  final IBlobStorage inner;
  final IVaultCipher? cipher;

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    final raw = await inner.download(blobIds, context: context);
    final c = cipher;
    if (c == null) return raw;
    final result = <String, Uint8List>{};
    for (final entry in raw.entries) {
      context?.cancellationToken?.throwIfCancelled();
      result[entry.key] = await c.decrypt(entry.value);
    }
    return result;
  }

  @override
  Future<void> upload(
    List<(Uint8List bytes, String blobId)> blobs, {
    RpcContext? context,
  }) async {
    final c = cipher;
    if (c == null) {
      await inner.upload(blobs, context: context);
      return;
    }
    final encrypted = <(Uint8List, String)>[];
    for (final (bytes, blobId) in blobs) {
      context?.cancellationToken?.throwIfCancelled();
      encrypted.add((await c.encrypt(bytes), blobId));
    }
    await inner.upload(encrypted, context: context);
  }

  @override
  Future<void> deleteMany(
    List<String> blobIds, {
    RpcContext? context,
  }) =>
      inner.deleteMany(blobIds, context: context);

  // Blob ids are content hashes of the plain bytes, unchanged by
  // encryption — presence is a pure passthrough.
  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    RpcContext? context,
  }) =>
      inner.exists(blobIds, context: context);
}
