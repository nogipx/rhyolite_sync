import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob_sqlite/rpc_blob_sqlite.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// One SQLite connection, two components that write to it.
//
// This is the plugin's wiring, not a reconstruction of it: the data client and
// the blob store are built from the same DatabaseConnection, exactly as
// plugin.dart does. The previous attempt at this test built the data client
// with `SqliteDataStorageAdapter.memory()`, which makes its own connection —
// so it could prove the serialising wrapper worked and could not see the other
// writer at all. That is how the collision shipped.
//
// The connection holds one transaction slot. The data layer holds it across
// awaits; the blob store takes it synchronously. Overlap gives "cannot start a
// transaction within a transaction" on BEGIN, and SQL-logic errors on COMMIT as
// the two unwind over each other.
// ---------------------------------------------------------------------------

Future<Uint8List> _blob(int n) async => Uint8List.fromList(List.filled(n, 7));

void main() {
  late DatabaseConnection conn;

  setUp(() async {
    conn = await openInMemoryDb();
  });

  tearDown(() => conn.close());

  test('VALIDATES THE DIAGNOSIS: ungated, the two collide', () async {
    // Not a test of our code — of the premise the gate rests on. If it ever
    // goes green, the libraries underneath changed and the gate may be
    // redundant.
    final data = IDataClient.repository(
      repository: SqliteDataRepository(
        storage: SqliteDataStorageAdapter.connection(conn),
      ),
    );
    final blobs = SqliteBlobRepository.db(conn.database, enableWal: false);

    // Each failure is caught where it happens: Future.wait reports the first
    // and lets the rest escape as unhandled async errors, which fails the test
    // for the wrong reason.
    final errors = <Object>[];
    Future<void> guard(Future<Object?> f) async {
      try {
        await f;
      } catch (e) {
        errors.add(e);
      }
    }

    await Future.wait([
      for (var i = 0; i < 8; i++)
        guard(data.create(collection: 'states', payload: {'n': i})),
      for (var i = 0; i < 8; i++)
        guard(
          blobs.writeBlob(
            BlobWriteRequest(
              collection: 'blobs',
              id: 'b$i',
              bytes: Stream.value(await _blob(64)),
              length: 64,
            ),
          ),
        ),
    ]);
    final caught = errors.isEmpty ? null : errors.first;

    expect(
      caught,
      isNotNull,
      reason:
          'two writers on one connection must collide — this is what the gate '
          'exists to prevent, and the reason it cannot live inside either one',
    );
  });

  test('gated, both land', () async {
    final gate = ConnectionGate();
    final data = SerialisedDataClient(
      IDataClient.repository(
        repository: SqliteDataRepository(
          storage: SqliteDataStorageAdapter.connection(conn),
        ),
      ),
      gate: gate,
    );
    final blobs = GatedBlobRepository(
      SqliteBlobRepository.db(conn.database, enableWal: false),
      gate: gate,
    );

    await Future.wait([
      for (var i = 0; i < 8; i++)
        data.create(collection: 'states', payload: {'n': i}),
      for (var i = 0; i < 8; i++)
        blobs.writeBlob(
          BlobWriteRequest(
            collection: 'blobs',
            id: 'b$i',
            bytes: Stream.value(await _blob(64)),
            length: 64,
          ),
        ),
    ]);

    final states = await data.list(collection: 'states');
    expect(states.records, hasLength(8));
    for (var i = 0; i < 8; i++) {
      final read = await blobs.readBlob(
        BlobReadRequest(collection: 'blobs', id: 'b$i'),
      );
      expect(read, isNotNull, reason: 'blob b$i must have survived the mix');
    }
  });

  test('one gate per connection, or it is not a gate', () async {
    // Two gates over one connection is the same as none: each serialises its
    // own callers and neither knows about the other. Stated as a test because
    // the mistake is invisible — everything compiles and most of it works.
    final data = SerialisedDataClient(
      IDataClient.repository(
        repository: SqliteDataRepository(
          storage: SqliteDataStorageAdapter.connection(conn),
        ),
      ),
      gate: ConnectionGate(),
    );
    final blobs = GatedBlobRepository(
      SqliteBlobRepository.db(conn.database, enableWal: false),
      gate: ConnectionGate(),
    );

    // Each failure is caught where it happens: Future.wait reports the first
    // and lets the rest escape as unhandled async errors, which fails the test
    // for the wrong reason.
    final errors = <Object>[];
    Future<void> guard(Future<Object?> f) async {
      try {
        await f;
      } catch (e) {
        errors.add(e);
      }
    }

    await Future.wait([
      for (var i = 0; i < 8; i++)
        guard(data.create(collection: 'states', payload: {'n': i})),
      for (var i = 0; i < 8; i++)
        guard(
          blobs.writeBlob(
            BlobWriteRequest(
              collection: 'blobs',
              id: 'b$i',
              bytes: Stream.value(await _blob(64)),
              length: 64,
            ),
          ),
        ),
    ]);
    final caught = errors.isEmpty ? null : errors.first;
    expect(caught, isNotNull);
  });
}
