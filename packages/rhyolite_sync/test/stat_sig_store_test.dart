import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

void main() {
  group('StatSigStore', () {
    test('set/get and persistence across a reload', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final s = StatSigStore(client: env.client, vaultId: 'v');
      await s.load();
      expect(s.get('f1'), isNull);

      s.set('f1', 111, 222);
      expect(s.get('f1'), (mtimeMs: 111, sizeBytes: 222));
      await s.flushPending();

      // A fresh instance sees the persisted signature.
      final s2 = StatSigStore(client: env.client, vaultId: 'v');
      await s2.load();
      expect(s2.get('f1'), (mtimeMs: 111, sizeBytes: 222));
    });

    test('update overwrites, remove clears (persisted)', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final s = StatSigStore(client: env.client, vaultId: 'v');
      await s.load();
      s.set('f1', 1, 1);
      s.set('f1', 2, 9);
      expect(s.get('f1'), (mtimeMs: 2, sizeBytes: 9));
      s.remove('f1');
      expect(s.get('f1'), isNull);
      await s.flushPending();

      final s2 = StatSigStore(client: env.client, vaultId: 'v');
      await s2.load();
      expect(s2.get('f1'), isNull);
    });

    test('vaults are isolated', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final a = StatSigStore(client: env.client, vaultId: 'a');
      final b = StatSigStore(client: env.client, vaultId: 'b');
      await a.load();
      await b.load();
      a.set('f1', 5, 5);
      await a.flushPending();
      await b.load();
      expect(b.get('f1'), isNull, reason: 'sig in vault a must not leak to b');
    });
  });
}
