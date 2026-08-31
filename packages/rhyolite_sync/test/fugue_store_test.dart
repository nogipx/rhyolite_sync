import 'dart:convert';
import 'dart:typed_data';

import 'package:convergent/fugue.dart';
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

Fugue<String> _seedABCD() => FugueTextSync.seedFromText('abcd');

// Fugue has no value `==`; compare through the deterministic wire codec.
List<int> _blob(Fugue<String> f) => FugueStore.encodeBlob(f).toList();

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
      expect(
        _blob((await b.get('f1'))!),
        _blob((await a.get('f1'))!),
        reason: 'reloaded tree must equal originally persisted one',
      );
    });

    test('persistOne with null entry deletes the persisted row', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final a = await _newStore(env.client);
      a.set('f1', _seedABCD());
      await a.persistOne('f1');

      // Removing from the cache + persistOne should drop the row.
      a.set('f1', Fugue<String>()); // cleared but still cached
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

    test('load skips corrupt rows without failing the whole load', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      // Plant one good row and one with a payload the codec can't read.
      await env.client.create(
        collection: '${_vault}_fugue_store',
        id: 'good',
        payload: FugueStore.encodeForBlob(_seedABCD()) as Map<String, dynamic>,
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

  group('FugueStore payload encoding', () {
    // A realistic note: Cyrillic, where the old encoding was at its worst —
    // every character cost a quoted, comma-separated JSON entry of 5 bytes.
    String _note() => List.generate(
      120,
      (i) => 'Строка $i — заметка про синхронизацию и разрешение конфликтов.\n',
    ).join();

    test('a row written before the switch is still read', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      // encodeForBlob IS the old local format — plant one row in it.
      await env.client.create(
        collection: '${_vault}_fugue_store',
        id: 'legacy',
        payload: FugueStore.encodeForBlob(_seedABCD()) as Map<String, dynamic>,
      );

      final store = await _newStore(env.client);
      expect(
        (await store.get('legacy'))?.values.join(),
        'abcd',
        reason: 'upgrading must not orphan every tree already on disk',
      );
    });

    test(
      'a legacy row rewrites itself in the compact form once edited',
      () async {
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);
        await env.client.create(
          collection: '${_vault}_fugue_store',
          id: 'legacy',
          payload:
              FugueStore.encodeForBlob(_seedABCD()) as Map<String, dynamic>,
        );

        final store = await _newStore(env.client);
        final loaded = (await store.get('legacy'))!;
        store.set('legacy', loaded);
        await store.persistOne('legacy');

        final row = await env.client.get(
          collection: '${_vault}_fugue_store',
          id: 'legacy',
        );
        expect(row!.payload['enc'], 'fz1');
        expect(
          row.payload.containsKey('b'),
          isFalse,
          reason: 'the JSON block array must be gone, not merely ignored',
        );

        // And the rewritten row still decodes to the same tree.
        final fresh = await _newStore(env.client);
        expect((await fresh.get('legacy'))?.values.join(), 'abcd');
      },
    );

    test(
      'the compact row is materially smaller than the JSON it replaced',
      () async {
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);
        final store = await _newStore(env.client);

        final text = _note();
        final tree = FugueTextSync.seedFromText(text);
        store.set('big', tree);
        await store.persistOne('big');

        // Both measured the way sqlite stores them: jsonEncode into a TEXT
        // column. That is the number that lands on the user's disk.
        final legacy = utf8
            .encode(jsonEncode(FugueStore.encodeForBlob(tree)))
            .length;
        final row = await env.client.get(
          collection: '${_vault}_fugue_store',
          id: 'big',
        );
        final compact = utf8.encode(jsonEncode(row!.payload)).length;
        final plain = utf8.encode(text).length;

        // ignore: avoid_print
        print(
          'text=${plain}B  legacy=${legacy}B (${(legacy / plain).toStringAsFixed(1)}x)  '
          'compact=${compact}B (${(compact / plain).toStringAsFixed(1)}x)  '
          'saved=${(100 - compact / legacy * 100).toStringAsFixed(0)}%',
        );

        expect(
          compact,
          lessThan(legacy),
          reason: 'the whole point of the change',
        );
        expect(
          compact / legacy,
          lessThan(0.75),
          reason:
              'base64 over the binary codec should beat JSON by a lot, '
              'not by a rounding error — if this regresses, the store went '
              'back to writing JSON somewhere',
        );
      },
    );
  });

  group('FugueStore wire codec', () {
    test('encodeForBlob → decodeFromBlob round-trips the tree (JSON)', () {
      final original = FugueTextSync.seedFromText('round trip');
      final encoded = FugueStore.encodeForBlob(original);
      final restored = FugueStore.decodeFromBlob(encoded);
      expect(_blob(restored), _blob(original));
      expect(restored.values, original.values);
    });

    test('encodeBlob → tryDecodeBlob round-trips the tree (binary)', () {
      final original = FugueTextSync.seedFromText('round trip');
      final restored = FugueStore.tryDecodeBlob(
        FugueStore.encodeBlob(original),
      );
      expect(restored, isNotNull);
      expect(restored!.values.join(), 'round trip');
      expect(_blob(restored), _blob(original));
    });

    test('tryDecodeBlob rejects non-magic bytes, isLegacy flags old blobs', () {
      // Plain text is neither a new-format blob nor a legacy Sequence blob.
      final plain = Uint8List.fromList('just some text'.codeUnits);
      expect(FugueStore.tryDecodeBlob(plain), isNull);
      expect(FugueStore.isLegacySequenceBlob(plain), isFalse);

      // A legacy JSON Sequence envelope is positively detected.
      final legacy = Uint8List.fromList(utf8.encode('{"v":1,"chars":[]}'));
      expect(FugueStore.tryDecodeBlob(legacy), isNull);
      expect(FugueStore.isLegacySequenceBlob(legacy), isTrue);
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
      expect(b.count, 2, reason: 'load() must discover persisted fileIds');
      expect(
        b.stats.cached,
        0,
        reason: 'load() must NOT decode any sequence upfront',
      );
      expect(
        b.peek('f1'),
        isNull,
        reason: 'no Sequence in cache before first get()',
      );
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
      expect(
        b.peek('f1'),
        isNotNull,
        reason: 'first get() must populate the cache',
      );
      expect(b.stats.cached, 1);
    });

    test('get() of unknown fileId is a fast null without sqlite hit', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final a = await _newStore(env.client);
      a.set('f1', _seedABCD());
      await a.persistOne('f1');

      final b = await _newStore(env.client);
      expect(
        await b.get('ghost'),
        isNull,
        reason: 'unknown fileId returns null without loading anything',
      );
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
      expect(
        store.peek('f2'),
        isNull,
        reason: 'least-recently-used entry must be evicted',
      );
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
      expect(
        b.peek('f1'),
        isNull,
        reason: 'peek does not trigger sqlite load even for known fileId',
      );
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
