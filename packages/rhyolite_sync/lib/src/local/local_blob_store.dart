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

  Future<void> deleteBlobs(List<String> blobIds, {required String vaultId}) =>
      _repo.deleteMany(_collection(vaultId), blobIds);

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

  /// Which of [blobIds] this device holds.
  ///
  /// Asks about the ids in question instead of enumerating the vault: the
  /// caller probes in batches, and listing everything for each batch turns a
  /// verification pass into a walk of the whole local cache per slice.
  Future<Set<String>> existing(
    List<String> blobIds, {
    required String vaultId,
  }) async {
    if (blobIds.isEmpty) return <String>{};
    final found = await _repo.headMany(_collection(vaultId), blobIds);
    return found.keys.toSet();
  }

  /// All blob ids in the local cache for [vaultId]. Used by the local
  /// blob cache garbage collector to find candidates for deletion.
  Future<List<String>> listBlobIds({required String vaultId}) async => [
        for (final entry in await listBlobSizes(vaultId: vaultId)) entry.id,
      ];

  /// Every blob in the local cache with the size it occupies.
  ///
  /// Reads descriptors, never bodies — the size is a column, so weighing the
  /// whole cache costs a listing rather than a full read of every chunk. That
  /// is the difference between an overview the UI can open on demand and one
  /// that stalls a phone on a gigabyte of attachments.
  Future<List<({String id, int sizeBytes})>> listBlobSizes({
    required String vaultId,
  }) async {
    final collection = _collection(vaultId);
    final out = <({String id, int sizeBytes})>[];
    String? cursor;
    while (true) {
      final response = await _repo.listBlobs(
        ListBlobsRequest(collection: collection, cursor: cursor),
      );
      for (final d in response.items) {
        out.add((id: d.id, sizeBytes: d.length));
      }
      cursor = response.nextCursor;
      if (cursor == null) break;
    }
    return out;
  }
}
