import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// In-memory [IBlobStorage] built for fault-injection tests.
///
/// It intentionally exposes its backing [store] so a test can mutate stored
/// bytes in place (simulate a corrupt blob) and observe exactly what was
/// uploaded ([uploadedBatches]). [afterUpload] fires AFTER a batch has been
/// durably stored — the seam a cancellation test uses to fire between the
/// chunk upload and the manifest upload.
class FakeBlobStorage implements IBlobStorage {
  /// blobId -> stored bytes. Public so tests can corrupt entries directly.
  final Map<String, Uint8List> store = {};

  /// Ids of every batch passed to [upload], in call order. Lets a resume test
  /// assert that only the manifest (not the already-present chunks) is re-sent.
  final List<List<String>> uploadedBatches = [];

  int downloadCalls = 0;

  /// Invoked once per [upload] call, AFTER the batch is stored, with the ids
  /// just written. A test cancels a token here to land the cancellation
  /// strictly between the chunk upload and the manifest upload.
  void Function(List<String> ids)? afterUpload;

  @override
  Future<void> upload(
    List<(Uint8List bytes, String blobId)> blobs, {
    RpcContext? context,
  }) async {
    context?.cancellationToken?.throwIfCancelled();
    final ids = <String>[];
    for (final (bytes, id) in blobs) {
      store[id] = bytes;
      ids.add(id);
    }
    uploadedBatches.add(ids);
    afterUpload?.call(ids);
  }

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    downloadCalls++;
    context?.cancellationToken?.throwIfCancelled();
    return {
      for (final id in blobIds)
        if (store.containsKey(id)) id: store[id]!,
    };
  }

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    RpcContext? context,
  }) async =>
      {for (final id in blobIds) if (store.containsKey(id)) id};

  @override
  Future<void> deleteMany(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    for (final id in blobIds) {
      store.remove(id);
    }
  }
}

/// Overwrites `store[id]` with bytes of the SAME length but different content
/// (every byte flipped). Returns the corrupted bytes. Models a backend that
/// hands back the wrong blob under a content-address without changing its size.
Uint8List corruptSameLength(Map<String, Uint8List> store, String id) {
  final original = store[id];
  if (original == null) {
    throw ArgumentError('no blob stored under id "$id" to corrupt');
  }
  final garbage = Uint8List(original.length);
  for (var i = 0; i < original.length; i++) {
    garbage[i] = original[i] ^ 0xFF; // length preserved, every byte differs
  }
  store[id] = garbage;
  return garbage;
}
