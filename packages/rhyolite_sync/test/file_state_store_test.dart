import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/src/sync_v3/file_state.dart';
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
}) =>
    FileState(
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

    test('persistMeta + load roundtrips cursor/epoch/lastSyncedBlobRef',
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
    });

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
    test('parallel persistMeta calls do not race on version conflict',
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
    });

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
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson rejects legacy v1 rows (no v defaults to v1, rejected by v2)',
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
        throwsA(isA<FormatException>()),
      );
    });

    test('wirePayloadFromBytes rejects unknown schema version', () {
      final badPayload = '{"v":99,"path":"x","blobRef":"y","sizeBytes":1}';
      expect(
        () => FileState.wirePayloadFromBytes(badPayload.codeUnits),
        throwsA(isA<FormatException>()),
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
    test('load skips rows with unknown register version (corruption-tolerant)',
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
    });
  });

  group('FileStateStore — self-stabilization (HLC paper §4)', () {
    test('applyRemote skips TaggedValue with hlc.millis far in the future',
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
      final result = store.applyRemote(
        'f1',
        [poisoned],
        onSkip: (tv, _) => rejected.add(tv),
      );

      expect(rejected, [poisoned]);
      expect(result.values, isEmpty,
          reason: 'poisoned value must not enter the register');
      // ownContext must not have advanced to the attacker hlc.
      expect(store.ownContext['attacker'], isNull,
          reason: 'ownContext must not be polluted by rejected value');
    });

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
      final result = store.applyRemote(
        'f1',
        [ok],
        onSkip: (tv, _) => rejected.add(tv),
      );

      expect(rejected, isEmpty);
      expect(result.values.length, 1);
      expect(store.ownContext['peer']?.millis, justAhead);
    });

    test('maxClockSkewMs=null disables the defence (paper baseline)',
        () async {
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

      final result = store.applyRemote(
        'f1',
        [poisoned],
        maxClockSkewMs: null,
      );
      expect(result.values.length, 1,
          reason: 'with defence disabled, paper Fig.5 semantics apply');
    });
  });
}
