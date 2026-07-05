import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// SHA-256 of zero bytes. An empty file always has this blob ID.
/// Its content is trivially known, so we can reconstruct it without the store.
const _emptySha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// Bridges [LocalBlobStore] (which requires vaultId per call)
/// to the [IBlobStorage] interface (which is vaultId-agnostic).
class LocalBlobStorageAdapter implements IBlobStorage {
  LocalBlobStorageAdapter(this._store, this._vaultId);

  final LocalBlobStore _store;
  final String _vaultId;

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    final result = <String, Uint8List>{};
    for (final blobId in blobIds) {
      var bytes = await _store.read(blobId, vaultId: _vaultId);
      if (bytes == null) {
        if (blobId == _emptySha256) {
          // Empty file: content is deterministically known.
          // Self-heal by writing it to the store so future reads succeed.
          await _store.write(Uint8List(0), blobId, vaultId: _vaultId);
          bytes = Uint8List(0);
        } else {
          // Blob genuinely missing — skip. PushUseCase will skip the
          // corresponding ChangeRecord and leave it unsynced for retry.
          continue;
        }
      }
      result[blobId] = bytes;
    }
    return result;
  }

  @override
  Future<void> upload(
    List<(Uint8List bytes, String blobId)> blobs, {
    RpcContext? context,
  }) async {
    for (final (bytes, blobId) in blobs) {
      await _store.write(bytes, blobId, vaultId: _vaultId);
    }
  }

  @override
  Future<void> deleteMany(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    if (blobIds.isEmpty) return;
    await _store.deleteBlobs(blobIds, vaultId: _vaultId);
  }

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    if (blobIds.isEmpty) return {};
    final local = (await _store.listBlobIds(vaultId: _vaultId)).toSet();
    final present = <String>{};
    for (final id in blobIds) {
      // Empty-file blob is reconstructable without the store, so always present.
      if (id == _emptySha256 || local.contains(id)) present.add(id);
    }
    return present;
  }
}
