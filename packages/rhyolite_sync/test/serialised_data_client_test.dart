import 'dart:async';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart' show RpcContext;
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Against a REAL SQLite connection, not a fake.
//
// The defect being pinned is a property of SQLite itself — one connection
// cannot hold two transactions — so a fake repository would happily accept the
// concurrency that breaks in production and prove nothing. `rpc_data_sqlite` is
// a dev dependency for exactly this test; the package itself stays free of it.
//
// Reported by a user on 3.16.2: 118 SqliteExceptions, twenty of them literally
// `cannot start a transaction within a transaction` on BEGIN, and the rest
// SQL-logic errors on COMMIT as the collided transactions unwound over each
// other. The startup diff had begun persisting each upload group from four
// concurrent workers, and one connection cannot take that.
// ---------------------------------------------------------------------------

Future<IDataClient> rawSqliteClient() async {
  final adapter = await SqliteDataStorageAdapter.memory();
  return IDataClient.repository(
    repository: SqliteDataRepository(storage: adapter),
  );
}

void main() {
  group('concurrent writes on one SQLite connection', () {
    test('VALIDATES THE DIAGNOSIS: unserialised, they fail', () async {
      // Not a test of our code — a test of the premise the fix rests on. If
      // this ever starts passing, the library underneath has changed and the
      // wrapper below may no longer be needed.
      final client = await rawSqliteClient();

      Object? caught;
      try {
        await Future.wait([
          client.create(collection: 'c', payload: const {'n': 1}),
          client.create(collection: 'c', payload: const {'n': 2}),
        ]);
      } catch (e) {
        caught = e;
      }

      expect(
        caught,
        isNotNull,
        reason:
            'two overlapping writes on one connection must fail — this is '
            'the behaviour the serialising client exists to prevent',
      );
    });

    test('serialised, the same writes both land', () async {
      final client = SerialisedDataClient(await rawSqliteClient());

      await Future.wait([
        client.create(collection: 'c', payload: const {'n': 1}),
        client.create(collection: 'c', payload: const {'n': 2}),
      ]);

      final rows = await client.list(collection: 'c');
      expect(rows.records, hasLength(2));
    });

    test('a heavy interleaving of writes and reads survives', () async {
      // Closer to what the startup diff does: four workers each writing a row
      // and reading it back, which is `_writeWithRetry`'s get-then-update in
      // miniature.
      //
      // Survives the canary — each worker's read staggers its next write
      // enough that the four rarely overlap — so this pins that the wrapper
      // does not BREAK the realistic shape, not that it fixes it. The two
      // tests around it are what pin the concurrency.
      final client = SerialisedDataClient(await rawSqliteClient());

      await Future.wait([
        for (var worker = 0; worker < 4; worker++)
          Future(() async {
            for (var i = 0; i < 10; i++) {
              final id = 'w$worker-$i';
              await client.create(
                collection: 'files',
                id: id,
                payload: {'n': i},
              );
              final back = await client.get(collection: 'files', id: id);
              expect(back, isNotNull);
            }
          }),
      ]);

      final rows = await client.list(
        collection: 'files',
        options: const QueryOptions(limit: 1000),
      );
      expect(rows.records, hasLength(40));
    });
  });

  group('the queue itself', () {
    test('one call runs at a time', () async {
      final probe = _OverlapProbe();
      final client = SerialisedDataClient(probe);

      await Future.wait([
        for (var i = 0; i < 8; i++)
          client.create(collection: 'c', payload: {'n': i}),
      ]);

      expect(probe.maxConcurrent, 1);
      expect(probe.calls, 8);
    });

    test('a failure does not wedge the queue behind it', () async {
      // The tail chains on completion INCLUDING failure. Chaining on success
      // alone would let one refused write stop the vault syncing until a
      // restart, which is a worse fault than the one being fixed.
      final probe = _OverlapProbe(failOn: {0});
      final client = SerialisedDataClient(probe);

      await expectLater(
        client.create(collection: 'c', payload: const {'n': 0}),
        throwsA(isA<StateError>()),
      );
      await client.create(collection: 'c', payload: const {'n': 1});

      expect(probe.calls, 2);
    });

    test(
      'a body that throws synchronously is a rejection, not a hang',
      () async {
        // Without Future.sync the throw escapes the queue callback, the
        // completer never settles, and the caller waits on a future that cannot
        // ever complete — a hang is worse than the collision being prevented.
        final client = SerialisedDataClient(_SyncThrowingClient());

        await expectLater(
          client
              .get(collection: 'c', id: 'x')
              .timeout(
                const Duration(seconds: 2),
                onTimeout: () => throw StateError('HUNG'),
              ),
          throwsA(isA<ArgumentError>()),
        );

        // And the queue is still usable afterwards.
        await expectLater(
          client.get(collection: 'c', id: 'y'),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('order is preserved', () async {
      final probe = _OverlapProbe();
      final client = SerialisedDataClient(probe);

      await Future.wait([
        for (var i = 0; i < 5; i++)
          client.create(collection: 'c', payload: {'n': i}),
      ]);

      expect(probe.order, [0, 1, 2, 3, 4]);
    });

    test('a change subscription is not queued', () async {
      // It outlives every call around it; putting it in the queue would stop
      // the engine dead the first time anything watched a collection.
      final probe = _OverlapProbe();
      final client = SerialisedDataClient(probe);

      final events = client.watchChanges(collection: 'c');
      expect(events, isNotNull);
      // The queue is still free.
      await client.create(collection: 'c', payload: const {'n': 1});
      expect(probe.calls, 1);
    });
  });
}

/// Throws before its first await, which is the case `Future.sync` covers.
class _SyncThrowingClient implements IDataClient {
  @override
  Future<DataRecord?> get({
    required String collection,
    required String id,
    RpcContext? context,
  }) => throw ArgumentError('synchronous refusal');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} not used by this test',
  );
}

/// Records how many calls were in flight at once, and in what order.
class _OverlapProbe implements IDataClient {
  _OverlapProbe({this.failOn = const {}});

  final Set<int> failOn;
  int calls = 0;
  int _inFlight = 0;
  int maxConcurrent = 0;
  final List<int> order = [];

  @override
  Future<DataRecord> create({
    required String collection,
    required Map<String, dynamic> payload,
    String? id,
    RpcContext? context,
  }) async {
    final n = payload['n'] as int;
    final index = calls++;
    _inFlight++;
    if (_inFlight > maxConcurrent) maxConcurrent = _inFlight;
    // Two turns, so an unserialised caller has room to overlap.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    order.add(n);
    _inFlight--;
    if (failOn.contains(index)) throw StateError('refused $index');
    final now = DateTime.fromMillisecondsSinceEpoch(0);
    return DataRecord(
      id: id ?? '$n',
      collection: collection,
      payload: payload,
      version: 1,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Stream<DataChangeEvent> watchChanges({
    required String collection,
    String? cursor,
    RpcContext? context,
  }) => const Stream<DataChangeEvent>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} not used by this test',
  );
}
