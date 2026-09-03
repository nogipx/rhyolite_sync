@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:rhyolite_client_obsidian/src/engine/gated_database.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob_sqlite/rpc_blob_sqlite.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The two writers GatedDatabase hands out are on the connection's one gate.
//
// `gated_database_guard_test.dart` says nobody outside the owner can reach the
// raw handle. That is a rule about text, and it would pass just as happily over
// a GatedDatabase whose own factory built the blob repository ungated — which
// is the shape that shipped: a correct queue inside the data client, a second
// writer six lines below it, and a vault that banked nothing for two days.
//
// Both tests were checked against that shape — the factory rebuilt with a
// second `ConnectionGate()` for the blob repository — and both went red. The
// second returns the field error verbatim: `cannot start a transaction within a
// transaction` on BEGIN inside `SqliteBlobRepository.writeBlob`.
//
// Worth knowing if this is ever rewritten: the collision needs the data client
// to be gated. Ungate BOTH and 40 interleaved bulk writes pass — serialising
// one side is what makes its transactions actually hold open long enough for
// the other to land inside one. So the load half only detects the defect that
// really shipped, which is why the identity half is here too: it is true or
// false regardless of scale.
// ---------------------------------------------------------------------------

/// Fixed so nothing here depends on wall time.
final _epoch = DateTime.utc(2026);

void main() {
  test('both writers queue on the connection gate, not on their own', () async {
    final conn = await openInMemoryDb();
    addTearDown(conn.close);

    final gated = GatedDatabase.wrap(conn);

    final data = gated.dataClient;
    final blobs = gated.blobRepository;

    expect(
      data,
      isA<SerialisedDataClient>(),
      reason: 'an unwrapped data client is one writer past the gate',
    );
    expect(
      blobs,
      isA<GatedBlobRepository>(),
      reason:
          'this is the one that was missed: the blob store takes the '
          'transaction slot synchronously and cannot wait for it',
    );
    expect(
      identical((data as SerialisedDataClient).gate, gated.gate),
      isTrue,
      reason: 'a gate of its own serialises its own callers and nobody else',
    );
    expect(
      identical((blobs as GatedBlobRepository).gate, gated.gate),
      isTrue,
      reason: 'a gate of its own serialises its own callers and nobody else',
    );
  });

  test('and serialising costs order, not writes', () async {
    final conn = await openInMemoryDb();
    addTearDown(conn.close);

    final gated = GatedDatabase.wrap(conn);
    await gated.dataClient.create(
      collection: 'states',
      id: 'warmup',
      payload: const {},
    );
    await gated.blobRepository.ensureCollection('chunks');

    // Interleaved, then all awaited together: whatever order the gate imposes,
    // everything issued has to land.
    const rounds = 20;
    const batch = 8;
    await Future.wait(<Future<void>>[
      for (var i = 0; i < rounds; i++) ...[
        gated.dataClient.bulkUpsert(
          records: [
            for (var j = 0; j < batch; j++)
              DataRecord(
                collection: 'states',
                id: 'state-$i-$j',
                payload: {'n': i * batch + j},
                version: 1,
                createdAt: _epoch,
                updatedAt: _epoch,
              ),
          ],
        ),
        gated.blobRepository.writeBlob(
          BlobWriteRequest(
            collection: 'chunks',
            id: 'chunk-$i',
            bytes: Stream.value(Uint8List.fromList([i & 0xFF])),
          ),
        ),
      ],
    ]);

    final states = await gated.dataClient.getMany(
      collection: 'states',
      ids: [
        for (var i = 0; i < rounds; i++)
          for (var j = 0; j < batch; j++) 'state-$i-$j',
      ],
    );
    expect(states.length, rounds * batch);
    expect(
      await gated.blobRepository.headBlob('chunks', 'chunk-0'),
      isNotNull,
      reason: 'a blob queued behind a data transaction must still be written',
    );
  });

  test('compacting returns the space a delete only freed inside the file',
      () async {
    final conn = await openInMemoryDb();
    addTearDown(conn.close);
    final gated = GatedDatabase.wrap(conn);

    // Enough rows that the file grows well past its initial pages.
    final blobs = gated.blobRepository;
    await blobs.ensureCollection('chunks');
    final payload = Uint8List(64 * 1024);
    for (var i = 0; i < 64; i++) {
      await blobs.writeBlob(
        BlobWriteRequest(
          collection: 'chunks',
          id: 'blob-$i',
          bytes: Stream.value(payload),
        ),
      );
    }
    final grown = await gated.describe();

    for (var i = 0; i < 64; i++) {
      await blobs.deleteBlob('chunks', 'blob-$i');
    }

    // Deleting is what returns pages to the freelist and makes writes work
    // again. It is NOT what returns them to the filesystem, and reading the
    // difference between those two is the whole reason this exists.
    final freed = await gated.describe();
    expect(freed, contains('reusable='));
    expect(
      freed,
      isNot(contains('reusable=0 pages')),
      reason: 'the delete must have freed pages inside the file',
    );

    final r = await gated.compact();
    expect(r.beforeBytes, isNotNull);
    expect(r.afterBytes, isNotNull);
    expect(
      r.afterBytes!,
      lessThan(r.beforeBytes!),
      reason: 'compaction is the only thing that shrinks the file, and a '
          'plugin that takes twenty seconds to open is paying for the size '
          'rather than the contents',
    );
    expect(grown, isNotEmpty);
  });

  test('the leftover change journal is dropped, because VACUUM would keep it',
      () async {
    final conn = await openInMemoryDb();
    addTearDown(conn.close);
    final gated = GatedDatabase.wrap(conn);

    // A build that wrote a journal left one behind. Recreated by hand, since
    // this build no longer produces one.
    conn.database.execute(
      'CREATE TABLE IF NOT EXISTS "s_change_journal" ('
      'sequence INTEGER PRIMARY KEY AUTOINCREMENT, collection TEXT NOT NULL, '
      'record_id TEXT NOT NULL, change_type TEXT NOT NULL, payload TEXT NULL, '
      'version INTEGER NOT NULL, occurred_at INTEGER NOT NULL)',
    );
    for (var i = 0; i < 200; i++) {
      conn.database.execute(
        'INSERT INTO "s_change_journal" '
        '(collection, record_id, change_type, payload, version, occurred_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        ['c', 'r-$i', 'updated', 'x' * 512, i, i],
      );
    }
    expect(
      conn.database
          .select('SELECT name FROM sqlite_master WHERE name = ?', [
            's_change_journal',
          ])
          .isNotEmpty,
      isTrue,
    );

    await gated.dropLegacyChangeJournal();

    expect(
      conn.database
          .select('SELECT name FROM sqlite_master WHERE name = ?', [
            's_change_journal',
          ]),
      isEmpty,
      reason: 'switching journals stops new rows and deletes none of the old '
          'ones; compaction would have packed them and returned nothing',
    );

    // And again, on a database that no longer has one.
    await gated.dropLegacyChangeJournal();
  });
}
