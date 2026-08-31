import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

void main() {
  _blobRefEvidence();
  group('StatSigStore', () {
    test('set/get and persistence across a reload', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final s = StatSigStore(client: env.client, vaultId: 'v');
      await s.load();
      expect(s.get('f1'), isNull);

      s.set('f1', 111, 222);
      expect(s.get('f1'), (mtimeMs: 111, sizeBytes: 222, blobRef: null));
      await s.flushPending();

      // A fresh instance sees the persisted signature.
      final s2 = StatSigStore(client: env.client, vaultId: 'v');
      await s2.load();
      expect(s2.get('f1'), (mtimeMs: 111, sizeBytes: 222, blobRef: null));
    });

    test('update overwrites, remove clears (persisted)', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);

      final s = StatSigStore(client: env.client, vaultId: 'v');
      await s.load();
      s.set('f1', 1, 1);
      s.set('f1', 2, 9);
      expect(s.get('f1'), (mtimeMs: 2, sizeBytes: 9, blobRef: null));
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

void _blobRefEvidence() {
  group('the blob a signature is evidence for', () {
    test(
      'survives a reload, and a row written without one stays unproven',
      () async {
        // The distinction the field exists for. A signature that matches proves
        // "this file has not changed since we last looked"; only the blobRef
        // turns that into "this file holds THAT content". A reader that
        // conflated the two would skip writing a peer's newer version over a
        // stale local copy, and lose an edit without a sound.
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);

        final s = StatSigStore(client: env.client, vaultId: 'v');
        await s.load();
        s.set('withRef', 5, 6, blobRef: 'blob-a');
        s.set('withoutRef', 5, 6);
        await s.flushPending();

        final reloaded = StatSigStore(client: env.client, vaultId: 'v');
        await reloaded.load();
        expect(reloaded.get('withRef')?.blobRef, 'blob-a');
        // Rows written before this field existed decode the same way, and mean
        // "cannot prove anything" rather than "proves nothing is there".
        expect(reloaded.get('withoutRef')?.blobRef, isNull);
        expect(reloaded.get('withoutRef')?.mtimeMs, 5);
      },
    );

    test(
      'a new blob under an unchanged mtime and size still updates',
      () async {
        // The no-op guard used to compare mtime and size only. A note edited
        // back to the same length would then keep pointing at the blob it no
        // longer holds — which is exactly the false evidence this field is here
        // to prevent.
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);

        final s = StatSigStore(client: env.client, vaultId: 'v');
        await s.load();
        s.set('f', 5, 6, blobRef: 'blob-a');
        s.set('f', 5, 6, blobRef: 'blob-b');
        expect(s.get('f')?.blobRef, 'blob-b');
        await s.flushPending();

        final reloaded = StatSigStore(client: env.client, vaultId: 'v');
        await reloaded.load();
        expect(reloaded.get('f')?.blobRef, 'blob-b');
      },
    );
  });
}
