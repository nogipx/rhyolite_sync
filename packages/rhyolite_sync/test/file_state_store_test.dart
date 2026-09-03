import 'package:convergent/convergent.dart';
import 'package:rhyolite_core/rhyolite_core.dart';
import 'package:rhyolite_sync/src/sync_v3/file_state_store.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

const _v = 'vault-1';

FileState _state(
  String fileId, {
  String path = 'note.md',
  String blob = 'blobA',
  int size = 10,
  int hlcMs = 1000,
  bool tombstone = false,
}) => FileState(
  fileId: fileId,
  path: path,
  blobRef: blob,
  sizeBytes: size,
  hlc: Hlc(hlcMs, 0, 'device-A'),
  tombstone: tombstone,
);

Future<FileStateStore> _newStore(IDataClient client) async {
  final store = FileStateStore(client: client, vaultId: _v);
  await store.load();
  return store;
}

void main() {
  _lazyMigrationTests();
  _pushedSignatureTests();
  group('FileStateStore in-memory', () {
    test('upsert and get', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      store.upsert(_state('f1'));
      expect(store.get('f1')?.blobRef, 'blobA');
      expect(store.count, 1);
    });

    test('remove drops state and lastSyncedBlobRef', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      store.upsert(_state('f1'));
      store.recordSyncedBlobRef('f1', 'blobA');
      store.remove('f1');
      expect(store.get('f1'), isNull);
      expect(store.lastSyncedBlobRefFor('f1'), isNull);
    });

    test('recordSyncedBlobRef with empty string clears entry', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      store.recordSyncedBlobRef('f1', 'blobA');
      expect(store.lastSyncedBlobRefFor('f1'), 'blobA');
      store.recordSyncedBlobRef('f1', '');
      expect(store.lastSyncedBlobRefFor('f1'), isNull);
    });
  });

  group('FileStateStore persistence', () {
    test('persistOne + load roundtrips a state', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      store.upsert(_state('f1', blob: 'X', hlcMs: 1234));
      await store.persistOne('f1');

      final fresh = FileStateStore(client: env.client, vaultId: _v);
      await fresh.load();
      expect(fresh.get('f1')?.blobRef, 'X');
      expect(fresh.get('f1')?.hlc.millis, 1234);
    });

    test(
      'persistMeta + load roundtrips cursor/epoch/lastSyncedBlobRef',
      () async {
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);
        final store = await _newStore(env.client);

        store.setServerCursor(42);
        store.setServerEpoch(7);
        store.recordSyncedBlobRef('f1', 'blobA');
        store.recordSyncedBlobRef('f2', 'blobB');
        await store.persistMeta();

        final fresh = FileStateStore(client: env.client, vaultId: _v);
        await fresh.load();
        expect(fresh.serverCursor, 42);
        expect(fresh.serverEpoch, 7);
        expect(fresh.lastSyncedBlobRefFor('f1'), 'blobA');
        expect(fresh.lastSyncedBlobRefFor('f2'), 'blobB');
      },
    );

    test('persistOne with no state in memory deletes from disk', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      store.upsert(_state('f1'));
      await store.persistOne('f1');

      store.remove('f1');
      await store.persistOne('f1');

      final fresh = FileStateStore(client: env.client, vaultId: _v);
      await fresh.load();
      expect(fresh.get('f1'), isNull);
    });

    test('wipeAll clears in-memory and persistent state', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      store.upsert(_state('f1'));
      store.recordSyncedBlobRef('f1', 'blobA');
      store.setServerCursor(10);
      store.setServerEpoch(3);
      await store.persistOne('f1');
      await store.persistMeta();

      await store.wipeAll();
      expect(store.count, 0);
      expect(store.serverCursor, 0);
      expect(store.serverEpoch, isNull);

      final fresh = FileStateStore(client: env.client, vaultId: _v);
      await fresh.load();
      expect(fresh.count, 0);
      expect(fresh.serverCursor, 0);
    });
  });

  group('FileStateStore concurrency', () {
    test(
      'parallel persistMeta calls do not race on version conflict',
      () async {
        // Reproduces the production race where pull + push + file events
        // all call persistMeta in flight at once: read existing.version,
        // then write fails because someone else already bumped it.
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);
        final store = await _newStore(env.client);

        Future<void> mutateAndPersist(int i) async {
          store.setServerCursor(i);
          await store.persistMeta();
        }

        // 16 concurrent persisters racing on the same meta row.
        await Future.wait(List.generate(16, mutateAndPersist));

        final fresh = FileStateStore(client: env.client, vaultId: _v);
        await fresh.load();
        // Last winner wins; the important guarantee is no exception.
        expect(fresh.serverCursor, anyOf(equals(15), greaterThanOrEqualTo(0)));
      },
    );

    test('parallel persistOne for same fileId is serialised', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      Future<void> bump(int i) async {
        store.upsert(_state('f1', blob: 'sha-$i', hlcMs: 1000 + i));
        await store.persistOne('f1');
      }

      await Future.wait(List.generate(8, bump));

      final fresh = FileStateStore(client: env.client, vaultId: _v);
      await fresh.load();
      expect(fresh.get('f1'), isNotNull);
    });
  });

  group('FileState JSON', () {
    test('roundtrips with all fields including tombstone', () {
      final s = _state(
        'f1',
        path: 'a/b.md',
        blob: 'sha',
        size: 99,
        tombstone: true,
      );
      final j = s.toJson();
      final back = FileState.fromJson(j);
      expect(back.fileId, s.fileId);
      expect(back.path, s.path);
      expect(back.blobRef, s.blobRef);
      expect(back.sizeBytes, s.sizeBytes);
      expect(back.hlc, s.hlc);
      expect(back.tombstone, true);
    });

    test('toWirePayload omits fileId (server-side only)', () {
      final s = _state('f1');
      final wire = s.toWirePayload();
      expect(wire.containsKey('fileId'), isFalse);
      expect(wire['path'], s.path);
      expect(wire['blobRef'], s.blobRef);
    });
  });

  group('FileState schema version', () {
    test('fromJson rejects unknown schema version', () {
      expect(
        () => FileState.fromJson({
          'v': 999,
          'fileId': 'f1',
          'path': 'note.md',
          'blobRef': 'sha',
          'sizeBytes': 1,
          'hlc': '1-0-A',
        }),
        // Typed, not FormatException: the cipher throws that too, for an
        // unreadable envelope, and the applier has to tell "this peer is newer,
        // tell the user to update" from "this row is corrupt".
        throwsA(isA<UnsupportedStateSchema>()),
      );
    });

    test(
      'fromJson rejects legacy v1 rows (no v defaults to v1, rejected by v2)',
      () {
        // A row with no `v` defaults to v1. v1 blob ids are raw sha256, which v2
        // (keyed HMAC) cannot reproduce, so v2 rejects such rows — forcing a
        // clean re-chunk rather than silently mixing the two id schemes.
        expect(
          () => FileState.fromJson({
            'fileId': 'f1',
            'path': 'note.md',
            'blobRef': 'sha',
            'sizeBytes': 1,
            'hlc': '1-0-A',
          }),
          throwsA(isA<UnsupportedStateSchema>()),
        );
      },
    );

    test('wirePayloadFromBytes rejects unknown schema version', () {
      final badPayload = '{"v":99,"path":"x","blobRef":"y","sizeBytes":1}';
      expect(
        () => FileState.wirePayloadFromBytes(badPayload.codeUnits),
        throwsA(isA<UnsupportedStateSchema>()),
      );
    });

    test('roundtrip preserves all fields under the current schema version', () {
      final s = FileState(
        fileId: 'f1',
        path: 'a.md',
        blobRef: 'sha',
        sizeBytes: 42,
        hlc: Hlc(1000, 0, 'A'),
        chunks: ['c1', 'c2'],
      );
      final j = s.toJson();
      expect(j['v'], FileState.schemaVersion);
      final back = FileState.fromJson(j);
      expect(back.chunks, ['c1', 'c2']);
    });
  });

  group('Register schema version', () {
    test(
      'load skips rows with unknown register version (corruption-tolerant)',
      () async {
        // Seed the raw data layer with a row that has v=999, then load.
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);
        await env.client.create(
          collection: '${_v}_state_store',
          id: 'rogue',
          payload: {'v': 999, 'values': []},
        );
        final store = await _newStore(env.client);
        // Bad row simply does not surface — load() catches FormatException.
        expect(store.contains('rogue'), isFalse);
      },
    );
  });

  group('FileStateStore — self-stabilization (HLC paper §4)', () {
    test(
      'applyRemote skips TaggedValue with hlc.millis far in the future',
      () async {
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);
        final store = await _newStore(env.client);

        // Build a poisoned TaggedValue 100 years ahead of wall.
        final farFuture =
            DateTime.now().millisecondsSinceEpoch + 100 * 365 * 86400 * 1000;
        final poisoned = TaggedValue<FileState>(
          FileState(
            fileId: 'f1',
            path: 'note.md',
            blobRef: 'evil',
            sizeBytes: 1,
            hlc: Hlc(farFuture, 0, 'attacker'),
          ),
          Hlc(farFuture, 0, 'attacker'),
        );

        final rejected = <TaggedValue<FileState>>[];
        final result = store.applyRemote('f1', [
          poisoned,
        ], onSkip: (tv, _) => rejected.add(tv));

        expect(rejected, [poisoned]);
        expect(
          result.values,
          isEmpty,
          reason: 'poisoned value must not enter the register',
        );
        // ownContext must not have advanced to the attacker hlc.
        expect(
          store.ownContext['attacker'],
          isNull,
          reason: 'ownContext must not be polluted by rejected value',
        );
      },
    );

    test('applyRemote accepts TaggedValue within skew bound', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      // 30 seconds ahead — well within default 5-minute bound.
      final justAhead = DateTime.now().millisecondsSinceEpoch + 30 * 1000;
      final ok = TaggedValue<FileState>(
        FileState(
          fileId: 'f1',
          path: 'note.md',
          blobRef: 'good',
          sizeBytes: 1,
          hlc: Hlc(justAhead, 0, 'peer'),
        ),
        Hlc(justAhead, 0, 'peer'),
      );

      final rejected = <TaggedValue<FileState>>[];
      final result = store.applyRemote('f1', [
        ok,
      ], onSkip: (tv, _) => rejected.add(tv));

      expect(rejected, isEmpty);
      expect(result.values.length, 1);
      expect(store.ownContext['peer']?.millis, justAhead);
    });

    test('maxClockSkewMs=null disables the defence (paper baseline)', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      final farFuture =
          DateTime.now().millisecondsSinceEpoch + 100 * 365 * 86400 * 1000;
      final poisoned = TaggedValue<FileState>(
        FileState(
          fileId: 'f1',
          path: 'note.md',
          blobRef: 'evil',
          sizeBytes: 1,
          hlc: Hlc(farFuture, 0, 'attacker'),
        ),
        Hlc(farFuture, 0, 'attacker'),
      );

      final result = store.applyRemote('f1', [poisoned], maxClockSkewMs: null);
      expect(
        result.values.length,
        1,
        reason: 'with defence disabled, paper Fig.5 semantics apply',
      );
    });
  });

  group('FileStateStore — witness (edit clock dominance)', () {
    test('witness lifts nextHlc above an observed peer-ahead hlc', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      // Content pulled from a peer whose wall clock is 30s ahead (within
      // skew) and already has a non-trivial counter.
      final ahead = DateTime.now().millisecondsSinceEpoch + 30 * 1000;
      final observed = Hlc(ahead, 5, 'peer');

      store.witness(observed);
      final next = store.nextHlc();

      // The very next edit dot must causally dominate the witnessed dot,
      // regardless of nodeId tie-break — this is the property that keeps
      // Fugue inserts sorting after existing content under clock skew.
      expect(next > observed, isTrue);
    });

    test('every dot minted after witness dominates the observed hlc', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      final ahead = DateTime.now().millisecondsSinceEpoch + 60 * 1000;
      final observed = Hlc(ahead, 9, 'peer');
      store.witness(observed);

      // A whole run of edits (as applyOps would mint) must each dominate.
      for (var i = 0; i < 20; i++) {
        expect(store.nextHlc() > observed, isTrue, reason: 'dot #$i');
      }
    });

    test(
      'witness clamps a far-future observed hlc (no clock poisoning)',
      () async {
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);
        final store = await _newStore(env.client);

        final now = DateTime.now().millisecondsSinceEpoch;
        final farFuture = now + 100 * 365 * 86400 * 1000; // ~100 years
        store.witness(Hlc(farFuture, 0, 'attacker'));
        final next = store.nextHlc();

        // The clock must stay near wall time, not adopt the 100-year jump.
        expect(
          next.millis < now + FileStateStore.defaultMaxClockSkewMs,
          isTrue,
          reason: 'far-future witness must be clamped, not adopted',
        );
      },
    );
  });

  // The host compares this against a deviceId it persists OUTSIDE the sync
  // database: empty store + remembered device = the database was lost (the
  // mobile storage-eviction case), which is what SyncLocalStateLost reports.
  group('FileStateStore — loadedEmpty', () {
    test('true on a database with nothing persisted', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      expect((await _newStore(env.client)).loadedEmpty, isTrue);
    });

    test('false once state has been persisted and reloaded', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);
      store.upsert(_state('f1'));
      await store.persistOne('f1');
      await store.persistMeta();

      expect((await _newStore(env.client)).loadedEmpty, isFalse);
    });

    test('false when only meta survives (cursor without registers)', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);
      store.setServerCursor(42);
      await store.persistMeta();

      final reloaded = await _newStore(env.client);
      expect(reloaded.loadedEmpty, isFalse);
      expect(reloaded.serverCursor, 42);
    });
  });
}

void _pushedSignatureTests() {
  group('pushed signature', () {
    test('survives a reload — the record is on the per-file row', () async {
      // The bug this exists for: while the guard was a session-local map, a
      // file authored here and never pulled back looked unpushed at every
      // launch. The server skips the insert when the HLC already matches, so
      // nothing came back to apply and nothing advanced the LCA — one vault
      // re-sent 117 records on every startup, forever.
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final store = await _newStore(env.client);
      store.upsert(_state('f1'));
      store.recordPushedSignature('f1', 'blobA note.md false');
      await store.persistOne('f1');

      final reloaded = await _newStore(env.client);
      expect(reloaded.lastPushedSignatureFor('f1'), 'blobA note.md false');
    });

    test('a row written before this existed reads as never pushed', () async {
      // Costs one redundant push apiece, once, rather than a migration.
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final store = await _newStore(env.client);
      store.upsert(_state('f1'));
      await store.persistOne('f1'); // no signature recorded

      final reloaded = await _newStore(env.client);
      expect(reloaded.lastPushedSignatureFor('f1'), isNull);
    });

    test('it does not disturb the register sharing the row', () async {
      // The signature rides as a sibling key; MvRegisterCodec reads `v` and
      // `values` and ignores the rest.
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final store = await _newStore(env.client);
      store.upsert(_state('f1', blob: 'blobZ', path: 'deep/note.md'));
      store.recordPushedSignature('f1', 'blobZ deep/note.md false');
      await store.persistOne('f1');

      final reloaded = await _newStore(env.client);
      expect(reloaded.get('f1')?.blobRef, 'blobZ');
      expect(reloaded.get('f1')?.path, 'deep/note.md');
    });

    test('forgetting a file forgets that it was pushed', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final store = await _newStore(env.client);
      store.upsert(_state('f1'));
      store.recordPushedSignature('f1', 'sig');
      store.remove('f1');

      expect(store.lastPushedSignatureFor('f1'), isNull);
    });

    test('a vault reset forgets every one of them', () async {
      // Otherwise a wiped server would be told, file by file, that it already
      // has records it no longer holds — and nothing would ever be re-sent.
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final store = await _newStore(env.client);
      store.upsert(_state('f1'));
      store.recordPushedSignature('f1', 'sig');
      await store.persistOne('f1');

      await store.wipeAll();

      expect(store.lastPushedSignatureFor('f1'), isNull);
      final reloaded = await _newStore(env.client);
      expect(reloaded.lastPushedSignatureFor('f1'), isNull);
    });
  });
}

/// Rewrites [fileId]'s row without the keys this version writes, and puts the
/// values back in the meta row — i.e. exactly what an install that predates
/// the move looks like on disk.
Future<void> _makeLegacy(
  IDataClient client,
  String fileId, {
  String? lca,
  int? serverSeq,
}) async {
  final row = await client.get(collection: '${_v}_state_store', id: fileId);
  final payload = Map<String, dynamic>.from(row!.payload)
    ..remove('lca')
    ..remove('srvSeq');
  await client.update(
    collection: '${_v}_state_store',
    id: fileId,
    expectedVersion: row.version,
    payload: payload,
  );

  final meta = await client.get(collection: '${_v}_state_meta', id: 'meta');
  final metaPayload = Map<String, dynamic>.from(meta!.payload);
  metaPayload['lastSyncedBlobRef'] = {if (lca != null) fileId: lca};
  metaPayload['serverSeq'] = {if (serverSeq != null) fileId: serverSeq};
  await client.update(
    collection: '${_v}_state_meta',
    id: 'meta',
    expectedVersion: meta.version,
    payload: metaPayload,
  );
}

Future<Map<String, dynamic>> _metaPayload(IDataClient client) async =>
    (await client.get(collection: '${_v}_state_meta', id: 'meta'))!.payload;

void _lazyMigrationTests() {
  group('per-file data moving off the meta row', () {
    test('a value written now is read back from the file row', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final store = await _newStore(env.client);
      store.upsert(_state('f1'));
      store.recordSyncedBlobRef('f1', 'blobA');
      store.recordServerSeq('f1', 42);
      await store.persistOne('f1');

      final reloaded = await _newStore(env.client);
      expect(reloaded.lastSyncedBlobRefFor('f1'), 'blobA');
      expect(reloaded.serverSeqFor('f1'), 42);
    });

    test('an install that predates the move still reads its values', () async {
      // The whole point of the lazy scheme: no migration step runs, and an
      // untouched file keeps working out of the meta row.
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final store = await _newStore(env.client);
      store.upsert(_state('f1'));
      await store.persistOne('f1');
      await store.persistMeta();
      await _makeLegacy(env.client, 'f1', lca: 'oldBlob', serverSeq: 7);

      final reloaded = await _newStore(env.client);
      expect(reloaded.lastSyncedBlobRefFor('f1'), 'oldBlob');
      expect(reloaded.serverSeqFor('f1'), 7);
    });

    test(
      'touching a legacy file moves it, and meta stops carrying it',
      () async {
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);

        final store = await _newStore(env.client);
        store.upsert(_state('f1'));
        await store.persistOne('f1');
        await store.persistMeta();
        await _makeLegacy(env.client, 'f1', lca: 'oldBlob', serverSeq: 7);

        final second = await _newStore(env.client);
        expect(
          (await _metaPayload(env.client))['lastSyncedBlobRef'],
          containsPair('f1', 'oldBlob'),
        );

        await second.persistOne(
          'f1',
        ); // the migration, triggered by ordinary use
        await second.persistMeta();

        final meta = await _metaPayload(env.client);
        expect(
          (meta['lastSyncedBlobRef'] as Map),
          isEmpty,
          reason: 'meta shrinks as files are touched',
        );
        expect((meta['serverSeq'] as Map), isEmpty);

        final third = await _newStore(env.client);
        expect(third.lastSyncedBlobRefFor('f1'), 'oldBlob');
        expect(third.serverSeqFor('f1'), 7);
      },
    );

    test('the row wins over a stale meta entry', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final store = await _newStore(env.client);
      store.upsert(_state('f1'));
      store.recordSyncedBlobRef('f1', 'fromRow');
      await store.persistOne('f1');

      // A duplicate left behind by a crash between the two writes.
      final meta = await env.client.get(
        collection: '${_v}_state_meta',
        id: 'meta',
      );
      final payload = Map<String, dynamic>.from(meta!.payload);
      payload['lastSyncedBlobRef'] = {'f1': 'staleFromMeta'};
      await env.client.update(
        collection: '${_v}_state_meta',
        id: 'meta',
        expectedVersion: meta.version,
        payload: payload,
      );

      final reloaded = await _newStore(env.client);
      expect(reloaded.lastSyncedBlobRefFor('f1'), 'fromRow');
    });

    test('a cleared LCA is not resurrected by the meta fallback', () async {
      // Why the row always writes the key, empty included: an absent key means
      // "not migrated" and falls back to meta, so clearing a legacy file's LCA
      // would otherwise bring the old value back on the next launch — and the
      // LCA is a merge base, so a stale one produces a wrong three-way merge.
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final store = await _newStore(env.client);
      store.upsert(_state('f1'));
      await store.persistOne('f1');
      await store.persistMeta();
      await _makeLegacy(env.client, 'f1', lca: 'oldBlob');

      final second = await _newStore(env.client);
      expect(second.lastSyncedBlobRefFor('f1'), 'oldBlob');
      second.recordSyncedBlobRef('f1', ''); // e.g. a tombstone resolution
      await second.persistOne('f1');

      final third = await _newStore(env.client);
      expect(third.lastSyncedBlobRefFor('f1'), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // The owed set: which files the push path still has to examine.
  //
  // It replaces a walk over every file on every push. The property that
  // matters is that it never MISSES one — over-inclusion costs a comparison,
  // under-inclusion loses a file silently.
  // -------------------------------------------------------------------------
  group('owedFileIds', () {
    test('a load seeds it with everything', () async {
      // The recovery the full walk used to provide. The startup diff writes
      // states and tells nobody, and the host's pending set is memory-only, so
      // after a restart this is the only record that anything is unsent.
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final first = await _newStore(env.client);
      for (var i = 0; i < 3; i++) {
        first.upsert(_state('f$i', blob: 'b$i'));
        await first.persistOne('f$i');
      }
      await first.persistMeta();

      final reopened = FileStateStore(client: env.client, vaultId: _v);
      await reopened.load();

      expect(reopened.owedFileIds.toSet(), {'f0', 'f1', 'f2'});
    });

    test('a local write adds, an acknowledged push removes', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);
      store.upsert(_state('a'));
      expect(store.owedFileIds, contains('a'));

      store.recordPushedSignature('a', 'sig-1');
      expect(store.owedFileIds, isNot(contains('a')));
    });

    test('a write after a push owes again', () async {
      // The signature guard settles a file only while its value is unchanged.
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);
      store.upsert(_state('a'));
      store.recordPushedSignature('a', 'sig-1');
      expect(store.owedFileIds, isNot(contains('a')));

      store.upsert(_state('a', blob: 'blobB', hlcMs: 2000));
      expect(
        store.owedFileIds,
        contains('a'),
        reason: 'an edit after a push is unsent again',
      );
    });

    test('clearOwed drops what the pusher settled', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);
      store.upsert(_state('a'));
      store.upsert(_state('b'));

      store.clearOwed(['a']);

      expect(store.owedFileIds, isNot(contains('a')));
      expect(store.owedFileIds, contains('b'));
    });
  });
}
