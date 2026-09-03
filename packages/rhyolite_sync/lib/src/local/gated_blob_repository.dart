import 'package:rpc_blob/rpc_blob.dart';

import 'connection_gate.dart';

/// Puts blob writes on the same queue as everything else using the connection.
///
/// The blob store's transactions are SYNCHRONOUS — `BEGIN`, work, `COMMIT`
/// with no await between — which is a virtue, not the problem: once it holds
/// the slot it finishes without yielding. What it cannot do is wait, and the
/// data layer holds the slot across awaits. So the waiting happens here,
/// before the call, and the synchronous body runs while the gate is held.
///
/// Every method is gated, including the reads: a read can create a collection
/// table on the way past, and that is DDL inside a transaction.
class GatedBlobRepository implements IBlobRepository {
  GatedBlobRepository(this._inner, {required ConnectionGate gate})
    : _gate = gate;

  final IBlobRepository _inner;
  final ConnectionGate _gate;

  /// The gate this repository queues on. Public for the same reason as
  /// `SerialisedDataClient.gate`: sharing is checkable by identity.
  ConnectionGate get gate => _gate;

  @override
  Future<BlobWriteResult> writeBlob(BlobWriteRequest request) =>
      _gate.run(() => _inner.writeBlob(request));

  @override
  Future<BlobReadResult?> readBlob(BlobReadRequest request) =>
      _gate.run(() => _inner.readBlob(request));

  @override
  Future<BlobDescriptor?> headBlob(String collection, String id) =>
      _gate.run(() => _inner.headBlob(collection, id));

  @override
  Future<Map<String, BlobDescriptor>> headMany(
    String collection,
    List<String> ids,
  ) => _gate.run(() => _inner.headMany(collection, ids));

  @override
  Future<bool> deleteBlob(
    String collection,
    String id, {
    int? expectedVersion,
  }) => _gate.run(
    () => _inner.deleteBlob(collection, id, expectedVersion: expectedVersion),
  );

  @override
  Future<Set<String>> deleteMany(String collection, List<String> ids) =>
      _gate.run(() => _inner.deleteMany(collection, ids));

  @override
  Future<bool> deleteCollection(String collection) =>
      _gate.run(() => _inner.deleteCollection(collection));

  @override
  Future<void> ensureCollection(String collection) =>
      _gate.run(() => _inner.ensureCollection(collection));

  @override
  Future<List<String>> listCollections() =>
      _gate.run(() => _inner.listCollections());

  @override
  Future<ListBlobsResponse> listBlobs(ListBlobsRequest request) =>
      _gate.run(() => _inner.listBlobs(request));

  @override
  Future<int?> collectionSize(String collection) =>
      _gate.run(() => _inner.collectionSize(collection));

  @override
  Future<void> dispose() => _inner.dispose();
}
