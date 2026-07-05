import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_store.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_text_sync.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

const _vault = 'vault-fg';

Future<FugueStore> _newStore(IDataClient client, {int cacheMax = 50}) async {
  final store = FugueStore(client: client, vaultId: _vault, cacheMax: cacheMax);
  await store.load();
  return store;
}

Sequence<String> _seedABCD() => FugueTextSync.seedFromText('abcd');

void main() {
  group('FugueStore in-memory', () {
    test('set + get round-trip', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      store.set('f1', _seedABCD());
      expect((await store.get('f1'))?.values.join(), 'abcd');
      expect(store.count, 1);
      expect(store.fileIds, ['f1']);
    });

    test('remove drops cached entry', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      store.set('f1', _seedABCD());
      await store.persistOne('f1');
      await store.remove('f1');
      expect(await store.get('f1'), isNull);
      expect(store.count, 0);
    });

    test('multiple files coexist independently', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client);

      store.set('f1', FugueTextSync.seedFromText('hello'));
      store.set('f2', FugueTextSync.seedFromText('world'));
      expect((await store.get('f1'))?.values.join(), 'hello');
      expect((await store.get('f2'))?.values.join(), 'world');
    });
  });

  group('FugueStore persistence', () {
    test('persistOne survives reload via new store instance', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final a = await _newStore(env.client);
      a.set('f1', _seedABCD());
      await a.persistOne('f1');

      final b = await _newStore(env.client);
      expect((await b.get('f1'))?.values.join(), 'abcd');
      expect(await b.get('f1'), await a.get('f1'),
          reason: 'reloaded sequence must equal originally persisted one');
    });

    test('persistOne with null entry deletes the persisted row', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final a = await _newStore(env.client);
      a.set('f1', _seedABCD());
      await a.persistOne('f1');

      // Removing from the cache + persistOne should drop the row.
      a.set('f1', Sequence<String>.empty()); // cleared but still cached
      await a.remove('f1');

      final b = await _newStore(env.client);
      expect(await b.get('f1'), isNull);
    });

    test('wipeAll clears both memory and persistence', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final a = await _newStore(env.client);
      a.set('f1', _seedABCD());
      await a.persistOne('f1');
      await a.wipeAll();

      final b = await _newStore(env.client);
      expect(b.count, 0);
    });

    test('load skips corrupt rows without failing the whole load',
        () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      // Plant one good row and one with a payload the codec can't read.
      await env.client.create(
        collection: '${_vault}_fugue_store',
        id: 'good',
        payload: FugueStore.encodeForBlob(_seedABCD())
            as Map<String, dynamic>,
      );
      await env.client.create(
        collection: '${_vault}_fugue_store',
        id: 'bad',
        payload: <String, dynamic>{'v': 99, 'garbage': true},
      );

      final store = await _newStore(env.client);
      expect((await store.get('good'))?.values.join(), 'abcd');
      expect(await store.get('bad'), isNull);
    });
  });

  group('FugueStore wire codec', () {
    test('encodeForBlob → decodeFromBlob round-trips the sequence', () {
      final original = FugueTextSync.seedFromText('round trip');
      final encoded = FugueStore.encodeForBlob(original);
      final restored = FugueStore.decodeFromBlob(encoded);
      expect(restored, original);
      expect(restored.values, original.values);
    });
  });

  group('FugueStore lazy load + LRU', () {
    test('load() learns fileIds without decoding sequences', () async {
      // Seed the store via one instance, persist, then open a new
      // instance and verify load() populated knownFileIds but did NOT
      // pre-decode the sequence into the cache.
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final a = await _newStore(env.client);
      a.set('f1', _seedABCD());
      a.set('f2', FugueTextSync.seedFromText('hello'));
      await a.persistOne('f1');
      await a.persistOne('f2');

      final b = await _newStore(env.client);
      expect(b.count, 2,
          reason: 'load() must discover persisted fileIds');
      expect(b.stats.cached, 0,
          reason: 'load() must NOT decode any sequence upfront');
      expect(b.peek('f1'), isNull,
          reason: 'no Sequence in cache before first get()');
    });

    test('get() lazy-decodes from sqlite and caches', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final a = await _newStore(env.client);
      a.set('f1', _seedABCD());
      await a.persistOne('f1');

      final b = await _newStore(env.client);
      expect(b.peek('f1'), isNull);

      final seq = await b.get('f1');
      expect(seq?.values.join(), 'abcd');
      expect(b.peek('f1'), isNotNull,
          reason: 'first get() must populate the cache');
      expect(b.stats.cached, 1);
    });

    test('get() of unknown fileId is a fast null without sqlite hit',
        () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final a = await _newStore(env.client);
      a.set('f1', _seedABCD());
      await a.persistOne('f1');

      final b = await _newStore(env.client);
      expect(await b.get('ghost'), isNull,
          reason: 'unknown fileId returns null without loading anything');
      expect(b.stats.cached, 0);
    });

    test('LRU evicts oldest when cache full', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client, cacheMax: 3);

      store.set('f1', FugueTextSync.seedFromText('one'));
      store.set('f2', FugueTextSync.seedFromText('two'));
      store.set('f3', FugueTextSync.seedFromText('three'));
      expect(store.stats.cached, 3);

      // Touch f1 so it's the most-recently-used.
      expect(store.peek('f1')?.values.join(), 'one');

      // Add a fourth — f2 should be evicted (least recently used).
      store.set('f4', FugueTextSync.seedFromText('four'));
      expect(store.stats.cached, 3);
      expect(store.peek('f2'), isNull,
          reason: 'least-recently-used entry must be evicted');
      expect(store.peek('f1'), isNotNull);
      expect(store.peek('f3'), isNotNull);
      expect(store.peek('f4'), isNotNull);
    });

    test('evicted entries reload from sqlite on next get()', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = await _newStore(env.client, cacheMax: 2);

      store.set('f1', _seedABCD());
      await store.persistOne('f1');
      store.set('f2', FugueTextSync.seedFromText('two'));
      await store.persistOne('f2');
      store.set('f3', FugueTextSync.seedFromText('three'));
      await store.persistOne('f3');

      // f1 evicted by f3.
      expect(store.peek('f1'), isNull);

      // get() reloads from sqlite.
      final reloaded = await store.get('f1');
      expect(reloaded?.values.join(), 'abcd');
      expect(store.peek('f1'), isNotNull);
    });

    test('peek does not load from sqlite', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final a = await _newStore(env.client);
      a.set('f1', _seedABCD());
      await a.persistOne('f1');

      final b = await _newStore(env.client);
      expect(b.peek('f1'), isNull,
          reason: 'peek does not trigger sqlite load even for known fileId');
    });

    test('fileIds includes lazy-loaded entries', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final a = await _newStore(env.client);
      a.set('a', _seedABCD());
      a.set('b', FugueTextSync.seedFromText('b'));
      await a.persistOne('a');
      await a.persistOne('b');

      final b = await _newStore(env.client);
      expect(b.fileIds.toSet(), {'a', 'b'});
    });
  });
}
