import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart' show RpcContext;
import 'package:rpc_data/rpc_data.dart';

/// Runs every call to an [IDataClient] one at a time.
///
/// A SQLite connection cannot hold two transactions. Two callers that overlap
/// on one connection produce `cannot start a transaction within a transaction`
/// on the second BEGIN, and then a stream of SQL-logic errors on COMMIT as the
/// two unwind over each other.
///
/// This used to be survivable by accident. Before rpc_dart `0bbad10c` the
/// adapter's transaction body was never awaited, so COMMIT ran at the body's
/// first await and "transactions" never actually held — overlapping callers
/// interleaved harmlessly because there was nothing to conflict with. Making
/// transactions real fixed atomicity and, in the same stroke, turned every
/// concurrent writer into a genuine collision.
///
/// The engine has several stores — file state, Fugue trees, frontmatter, stat
/// signatures — and a host typically shares the same client with settings sync
/// on top. They are separate objects over ONE connection, so no store can fix
/// this for itself; the queue has to sit where the connection does. Wrap at
/// the point the client is constructed and hand the wrapper to everything.
///
/// Reads are serialised too, deliberately. They look harmless, but a read can
/// create a collection table on its way past, and that is DDL inside a
/// transaction like any other. Serialising costs little that was real:
/// concurrent calls to one SQLite connection were never running in parallel,
/// they were only queued somewhere less safe.
///
/// The two streaming methods pass straight through. They are long-lived by
/// nature — holding the queue for the life of a change subscription would
/// deadlock everything behind it.
class SerialisedDataClient implements IDataClient {
  SerialisedDataClient(this._inner);

  final IDataClient _inner;

  /// Tail of the queue: a token saying "the previous call has finished", not
  /// its result.
  ///
  /// The `onError` that flattens it is deliberate and loses nothing. The
  /// caller's own error arrives through [Completer.completeError] below; this
  /// derived future exists only for sequencing, and if it were allowed to
  /// carry the error it would be a future nobody awaits for its value — an
  /// unhandled error per failed call, which is the same orphaning that a
  /// disposed transfer hub used to produce.
  Future<void> _tail = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() body) {
    final completer = Completer<T>();
    final previous = _tail;
    _tail = completer.future.then<void>((_) {}, onError: (_) {});
    previous.whenComplete(() {
      // `Future.sync`, not a bare call: a body that throws SYNCHRONOUSLY would
      // otherwise throw out of this callback, leaving the completer to hang
      // forever — the caller would wait on a future that can never settle,
      // which is worse than the collision being prevented. This turns it into
      // a rejection the caller actually receives.
      Future<T>.sync(
        body,
      ).then(completer.complete, onError: completer.completeError);
    });
    return completer.future;
  }

  // --- reads ---------------------------------------------------------------

  @override
  Future<DataRecord?> get({
    required String collection,
    required String id,
    RpcContext? context,
  }) => _serial(
    () => _inner.get(collection: collection, id: id, context: context),
  );

  @override
  Future<List<DataRecord>> getMany({
    required String collection,
    required List<String> ids,
    RpcContext? context,
  }) => _serial(
    () => _inner.getMany(collection: collection, ids: ids, context: context),
  );

  @override
  Future<ListRecordsResponse> list({
    required String collection,
    RecordFilter? filter,
    SortOrder? sort,
    QueryOptions options = const QueryOptions(),
    RpcContext? context,
  }) => _serial(
    () => _inner.list(
      collection: collection,
      filter: filter,
      sort: sort,
      options: options,
      context: context,
    ),
  );

  @override
  Future<List<String>> listCollections({RpcContext? context}) =>
      _serial(() => _inner.listCollections(context: context));

  @override
  Future<List<DataRecord>> listAllRecords({
    required String collection,
    RecordFilter? filter,
    SortOrder? sort,
    RpcContext? context,
  }) => _serial(
    () => _inner.listAllRecords(
      collection: collection,
      filter: filter,
      sort: sort,
      context: context,
    ),
  );

  @override
  Future<SearchRecordsResponse> search({
    required String collection,
    required String query,
    RecordFilter? filter,
    QueryOptions options = const QueryOptions(),
    RpcContext? context,
  }) => _serial(
    () => _inner.search(
      collection: collection,
      query: query,
      filter: filter,
      options: options,
      context: context,
    ),
  );

  @override
  Future<ExportSnapshotResponse> exportSnapshot({
    required String collection,
    RpcContext? context,
  }) => _serial(
    () => _inner.exportSnapshot(collection: collection, context: context),
  );

  @override
  Future<ListSchemasResponse> listSchemas({RpcContext? context}) =>
      _serial(() => _inner.listSchemas(context: context));

  @override
  Future<GetSchemaResponse> getSchema({
    required String collection,
    RpcContext? context,
  }) =>
      _serial(() => _inner.getSchema(collection: collection, context: context));

  // --- writes --------------------------------------------------------------

  @override
  Future<DataRecord> create({
    required String collection,
    required Map<String, dynamic> payload,
    String? id,
    RpcContext? context,
  }) => _serial(
    () => _inner.create(
      collection: collection,
      payload: payload,
      id: id,
      context: context,
    ),
  );

  @override
  Future<DataRecord> update({
    required String collection,
    required String id,
    required int expectedVersion,
    required Map<String, dynamic> payload,
    RpcContext? context,
  }) => _serial(
    () => _inner.update(
      collection: collection,
      id: id,
      expectedVersion: expectedVersion,
      payload: payload,
      context: context,
    ),
  );

  @override
  Future<DataRecord> patch({
    required String collection,
    required String id,
    required int expectedVersion,
    required RecordPatch patch,
    RpcContext? context,
  }) => _serial(
    () => _inner.patch(
      collection: collection,
      id: id,
      expectedVersion: expectedVersion,
      patch: patch,
      context: context,
    ),
  );

  @override
  Future<bool> delete({
    required String collection,
    required String id,
    int? expectedVersion,
    RpcContext? context,
  }) => _serial(
    () => _inner.delete(
      collection: collection,
      id: id,
      expectedVersion: expectedVersion,
      context: context,
    ),
  );

  @override
  Future<bool> deleteCollection({
    required String collection,
    RpcContext? context,
  }) => _serial(
    () => _inner.deleteCollection(collection: collection, context: context),
  );

  @override
  Future<List<DataRecord>> bulkUpsert({
    required Iterable<DataRecord> records,
    RpcContext? context,
  }) => _serial(() => _inner.bulkUpsert(records: records, context: context));

  @override
  Future<List<DataRecord>> bulkUpsertStream({
    required Stream<DataRecord> records,
    RpcContext? context,
  }) => _serial(
    () => _inner.bulkUpsertStream(records: records, context: context),
  );

  @override
  Future<int> bulkDelete({
    required String collection,
    required List<String> ids,
    RpcContext? context,
  }) => _serial(
    () => _inner.bulkDelete(collection: collection, ids: ids, context: context),
  );

  @override
  Future<ImportDatabaseResponse> importDatabase({
    required Stream<Uint8List> payload,
    bool replaceExisting = true,
    int resumeAfterChunk = -1,
    RpcContext? context,
  }) => _serial(
    () => _inner.importDatabase(
      payload: payload,
      replaceExisting: replaceExisting,
      resumeAfterChunk: resumeAfterChunk,
      context: context,
    ),
  );

  @override
  Future<CollectionIndex> createCollectionIndex({
    required String collection,
    required String path,
    String? indexName,
    RpcContext? context,
  }) => _serial(
    () => _inner.createCollectionIndex(
      collection: collection,
      path: path,
      indexName: indexName,
      context: context,
    ),
  );

  @override
  Future<bool> deleteCollectionIndex({
    required String collection,
    required String path,
    String? indexName,
    RpcContext? context,
  }) => _serial(
    () => _inner.deleteCollectionIndex(
      collection: collection,
      path: path,
      indexName: indexName,
      context: context,
    ),
  );

  @override
  Future<SetSchemaPolicyResponse> setSchemaPolicy({
    required String collection,
    required bool enabled,
    required bool requireValidation,
    RpcContext? context,
  }) => _serial(
    () => _inner.setSchemaPolicy(
      collection: collection,
      enabled: enabled,
      requireValidation: requireValidation,
      context: context,
    ),
  );

  // --- pass-through --------------------------------------------------------

  /// Long-lived by nature: holding the queue for the life of a subscription
  /// would deadlock every call behind it.
  @override
  Stream<DataChangeEvent> watchChanges({
    required String collection,
    String? cursor,
    RpcContext? context,
  }) => _inner.watchChanges(
    collection: collection,
    cursor: cursor,
    context: context,
  );

  @override
  Stream<Uint8List> exportDatabase({RpcContext? context}) =>
      _inner.exportDatabase(context: context);

  /// Not queued: closing is a teardown, and making it wait behind work that
  /// may itself be stuck is how a shutdown hangs.
  @override
  Future<void> close() => _inner.close();
}
