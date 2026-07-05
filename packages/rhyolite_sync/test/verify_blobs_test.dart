import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

const _vaultId = 'v-verify';

/// In-memory [IBlobStorage] whose presence set can be made to lie about a
/// chunk (simulating a silently-lost upload).
class _MemRemote implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  /// Ids the server pretends not to have even if [store] holds them.
  final Set<String> hideFromExists = {};

  /// Ids the server silently drops on upload (stored=false, but ack omits).
  final Set<String> dropOnUpload = {};

  /// Number of exists() calls made — asserts batching.
  int existsCalls = 0;

  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    covariant Object? context,
  }) async {
    for (final (bytes, id) in blobs) {
      if (dropOnUpload.contains(id)) continue;
      store[id] = bytes;
    }
  }

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    covariant Object? context,
  }) async =>
      {for (final id in blobIds) if (store.containsKey(id)) id: store[id]!};

  @override
  Future<void> deleteMany(
    List<String> blobIds, {
    covariant Object? context,
  }) async {
    for (final id in blobIds) {
      store.remove(id);
    }
  }

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    covariant Object? context,
  }) async {
    existsCalls++;
    return {
      for (final id in blobIds)
        if (store.containsKey(id) && !hideFromExists.contains(id)) id,
    };
  }
}

Future<FileStateStore> _newStore() async {
  final env = await DataServiceFactory.inMemory();
  final store = FileStateStore(client: env.client, vaultId: _vaultId);
  await store.load();
  return store;
}

LocalBlobStore _newLocalStore() => LocalBlobStore(InMemoryBlobRepository());

void main() {
  group('VerifyBlobsUseCase', () {
    test('re-uploads a referenced chunk absent on server but cached locally',
        () async {
      final store = await _newStore();
      final remote = _MemRemote();
      final local = _newLocalStore();

      const manifest = 'manifest-hash';
      const chunk = 'chunk-hash';
      final chunkBytes = Uint8List.fromList([1, 2, 3, 4]);

      // Server has the manifest but is missing the content chunk (the orphan).
      remote.store[manifest] = Uint8List.fromList([9]);
      remote.hideFromExists.add(chunk);
      // Local cache still holds the chunk bytes (content alive on this device).
      await local.write(chunkBytes, chunk, vaultId: _vaultId);

      store.applyLocal(FileState(
        fileId: 'f1',
        path: 'a.md',
        blobRef: manifest,
        sizeBytes: 4,
        hlc: store.nextHlc(),
        chunks: const [chunk],
      ));

      final result = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
      )();

      expect(result.referenced, 2);
      expect(result.missing, 1);
      expect(result.reuploaded, 1);
      expect(result.unhealable, 0);
      // The chunk is now durably on the server with the original bytes.
      expect(remote.store[chunk], chunkBytes);
    });

    test('reports unhealable when missing blob is not in the local cache',
        () async {
      final store = await _newStore();
      final remote = _MemRemote();
      final local = _newLocalStore();

      const manifest = 'm2';
      const chunk = 'c2';
      remote.store[manifest] = Uint8List.fromList([7]);
      remote.hideFromExists.add(chunk); // missing on server, absent locally

      store.applyLocal(FileState(
        fileId: 'f2',
        path: 'b.md',
        blobRef: manifest,
        sizeBytes: 1,
        hlc: store.nextHlc(),
        chunks: const [chunk],
      ));

      final result = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
      )();

      expect(result.missing, 1);
      expect(result.reuploaded, 0);
      expect(result.unhealable, 1);
    });

    test('clean vault: nothing re-uploaded', () async {
      final store = await _newStore();
      final remote = _MemRemote();
      final local = _newLocalStore();

      const manifest = 'm3';
      const chunk = 'c3';
      remote.store[manifest] = Uint8List.fromList([1]);
      remote.store[chunk] = Uint8List.fromList([2]);

      store.applyLocal(FileState(
        fileId: 'f3',
        path: 'c.md',
        blobRef: manifest,
        sizeBytes: 1,
        hlc: store.nextHlc(),
        chunks: const [chunk],
      ));

      final result = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
      )();

      expect(result.isClean, isTrue);
      expect(result.reuploaded, 0);
    });

    test('probes existence in batches and merges results', () async {
      final store = await _newStore();
      final remote = _MemRemote();
      final local = _newLocalStore();

      // 5 files = 10 referenced ids (manifest + chunk each). All present.
      for (var i = 0; i < 5; i++) {
        final m = 'm-$i';
        final c = 'c-$i';
        remote.store[m] = Uint8List.fromList([i]);
        remote.store[c] = Uint8List.fromList([i, i]);
        store.applyLocal(FileState(
          fileId: 'f-$i',
          path: '$i.md',
          blobRef: m,
          sizeBytes: 2,
          hlc: store.nextHlc(),
          chunks: [c],
        ));
      }

      final result = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
        existsBatch: 4,
      )();

      expect(result.referenced, 10);
      expect(result.isClean, isTrue);
      // 10 ids / batch 4 => 3 exists() calls.
      expect(remote.existsCalls, 3);
    });

    test('tombstoned states contribute no referenced blobs', () async {
      final store = await _newStore();
      final remote = _MemRemote();
      final local = _newLocalStore();

      store.applyLocal(FileState(
        fileId: 'f4',
        path: 'd.md',
        blobRef: '',
        sizeBytes: 0,
        hlc: store.nextHlc(),
        tombstone: true,
        chunks: const [],
      ));

      final result = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
      )();

      expect(result.referenced, 0);
      expect(result.isClean, isTrue);
    });
  });
}
