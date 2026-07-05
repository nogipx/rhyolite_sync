import 'dart:typed_data';

import 'package:rpc_blob/rpc_blob.dart';

class LocalBlobStore {
  LocalBlobStore(this._repo);

  final IBlobRepository _repo;

  String _collection(String vaultId) => '${vaultId}_blobs';

  Future<void> write(
    Uint8List bytes,
    String blobId, {
    required String vaultId,
  }) async {
    await _repo.writeBlob(
      BlobWriteRequest(
        collection: _collection(vaultId),
        id: blobId,
        bytes: Stream.value(bytes),
        length: bytes.length,
      ),
    );
  }

  Future<void> deleteBlobs(List<String> blobIds, {required String vaultId}) async {
    final collection = _collection(vaultId);
    for (final blobId in blobIds) {
      await _repo.deleteBlob(collection, blobId);
    }
  }

  Future<Uint8List?> read(String blobId, {required String vaultId}) async {
    final result = await _repo.readBlob(
      BlobReadRequest(collection: _collection(vaultId), id: blobId),
    );
    if (result == null) return null;
    final builder = BytesBuilder();
    await for (final chunk in result.bytes) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Drop the whole cache for [vaultId]. Called from triggerReset so
  /// that a "wipe + re-upload" doesn't leave stale local blobs lingering
  /// after the server's blob collection has already been dropped.
  Future<void> wipeAll({required String vaultId}) async {
    await _repo.deleteCollection(_collection(vaultId));
  }

  /// All blob ids in the local cache for [vaultId]. Used by the local
  /// blob cache garbage collector to find candidates for deletion.
  Future<List<String>> listBlobIds({required String vaultId}) async {
    final collection = _collection(vaultId);
    final ids = <String>[];
    String? cursor;
    while (true) {
      final response = await _repo.listBlobs(
        ListBlobsRequest(collection: collection, cursor: cursor),
      );
      ids.addAll(response.items.map((d) => d.id));
      cursor = response.nextCursor;
      if (cursor == null) break;
    }
    return ids;
  }
}
