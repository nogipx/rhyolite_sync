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

  group('resuming across preemption', () {
    test('carried confirmations are not re-probed', () async {
      final store = await _newStore();
      final remote = _MemRemote();
      final local = _newLocalStore();

      for (var i = 0; i < 10; i++) {
        remote.store['c$i'] = Uint8List.fromList([i]);
      }
      store.applyLocal(FileState(
        fileId: 'f1',
        path: 'a.md',
        blobRef: 'c0',
        sizeBytes: 4,
        hlc: store.nextHlc(),
        chunks: [for (var i = 1; i < 10; i++) 'c$i'],
      ));

      // First pass confirms everything.
      final carried = <String>{};
      final first = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
        existsBatch: 4,
        confirmedPresent: carried,
      )();
      expect(first.isClean, isTrue);
      final callsAfterFirst = remote.existsCalls;
      expect(callsAfterFirst, greaterThan(0));
      expect(carried, hasLength(10));

      // A second pass — what a re-scheduled run after preemption does — asks
      // the server nothing, because every id is already confirmed.
      final second = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
        existsBatch: 4,
        confirmedPresent: carried,
      )();
      expect(second.isClean, isTrue);
      expect(second.referenced, 10);
      expect(remote.existsCalls, callsAfterFirst,
          reason: 'no id should be probed twice');
    });

    test('missing ids are re-probed, so a heal elsewhere is picked up',
        () async {
      final store = await _newStore();
      final remote = _MemRemote();
      final local = _newLocalStore();

      remote.store['present'] = Uint8List.fromList([1]);
      remote.store['gone'] = Uint8List.fromList([2]);
      remote.hideFromExists.add('gone');
      store.applyLocal(FileState(
        fileId: 'f1',
        path: 'a.md',
        blobRef: 'present',
        sizeBytes: 4,
        hlc: store.nextHlc(),
        chunks: const ['gone'],
      ));

      final carried = <String>{};
      final first = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
        confirmedPresent: carried,
      )();
      expect(first.missing, 1);
      expect(carried, {'present'},
          reason: 'a missing id must never be recorded as confirmed');

      // Another device healed it; the next pass sees that.
      remote.hideFromExists.remove('gone');
      final second = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
        confirmedPresent: carried,
      )();
      expect(second.isClean, isTrue);
    });

    test('without a carried set each run probes from scratch', () async {
      final store = await _newStore();
      final remote = _MemRemote();
      final local = _newLocalStore();
      remote.store['c0'] = Uint8List.fromList([0]);
      store.applyLocal(FileState(
        fileId: 'f1',
        path: 'a.md',
        blobRef: 'c0',
        sizeBytes: 4,
        hlc: store.nextHlc(),
      ));

      Future<void> run() => VerifyBlobsUseCase(
            store: store,
            blobStorage: remote,
            localBlobStore: local,
            vaultId: _vaultId,
          )().then((_) {});

      await run();
      await run();
      expect(remote.existsCalls, 2);
    });
  });

  group('VerifyBlobsUseCase — healing from disk', () {
    test('a chunk absent from the cache is regenerated from the file',
        () async {
      final store = await _newStore();
      final remote = _MemRemote();
      final local = _newLocalStore();

      const manifest = 'm-disk';
      const chunk = 'c-disk';
      final chunkBytes = Uint8List.fromList([1, 2, 3, 4]);
      remote.store[manifest] = Uint8List.fromList([9]);
      remote.hideFromExists.add(chunk); // lost server-side, and not cached

      store.applyLocal(FileState(
        fileId: 'f-disk',
        path: 'att/photo.bin',
        blobRef: manifest,
        sizeBytes: 4,
        hlc: store.nextHlc(),
        chunks: const [chunk],
      ));

      final asked = <String, Set<String>>{};
      final result = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
        recoverBytes: (path, wanted) async {
          asked[path] = wanted;
          return {chunk: chunkBytes};
        },
      )();

      expect(result.unhealable, 0);
      expect(result.reuploaded, 1);
      expect(remote.store[chunk], chunkBytes,
          reason: 'the file on disk is as good a source as the cache was');
      expect(asked, {'att/photo.bin': {chunk}},
          reason: 'only the ids actually missing are asked for');
    });

    test('bytes that no longer hash to the wanted id heal nothing', () async {
      // The file changed since. A recovery that cannot produce the id simply
      // returns without it — which is why this needs no freshness check.
      final store = await _newStore();
      final remote = _MemRemote();
      final local = _newLocalStore();

      const chunk = 'c-stale';
      remote.store['m-stale'] = Uint8List.fromList([9]);
      remote.hideFromExists.add(chunk);
      store.applyLocal(FileState(
        fileId: 'f-stale',
        path: 'att/edited.bin',
        blobRef: 'm-stale',
        sizeBytes: 4,
        hlc: store.nextHlc(),
        chunks: const [chunk],
      ));

      final result = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
        // The rewritten file produces entirely different ids.
        recoverBytes: (_, __) async => {'c-other': Uint8List(4)},
      )();

      expect(result.unhealable, 1);
      expect(result.reuploaded, 0);
      expect(remote.store.containsKey('c-other'), isFalse,
          reason: 'nothing may be uploaded under an id it does not hash to');
    });

    test('one file is asked once, for all of its missing chunks', () async {
      final store = await _newStore();
      final remote = _MemRemote();
      final local = _newLocalStore();

      remote.store['m-multi'] = Uint8List.fromList([9]);
      for (final c in ['c1', 'c2', 'c3']) {
        remote.hideFromExists.add(c);
      }
      store.applyLocal(FileState(
        fileId: 'f-multi',
        path: 'att/big.bin',
        blobRef: 'm-multi',
        sizeBytes: 12,
        hlc: store.nextHlc(),
        chunks: const ['c1', 'c2', 'c3'],
      ));

      var calls = 0;
      final result = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
        recoverBytes: (_, wanted) async {
          calls++;
          return {for (final id in wanted) id: Uint8List(4)};
        },
      )();

      expect(calls, 1, reason: 'reading and chunking a file per chunk is the '
          'difference between a pass and a stall on a large attachment');
      expect(result.reuploaded, 3);
    });

    test('the cache still wins when it has the bytes', () async {
      final store = await _newStore();
      final remote = _MemRemote();
      final local = _newLocalStore();

      const chunk = 'c-cached';
      final cached = Uint8List.fromList([5, 5]);
      await local.write(cached, chunk, vaultId: _vaultId);
      remote.store['m-cached'] = Uint8List.fromList([9]);
      remote.hideFromExists.add(chunk);
      store.applyLocal(FileState(
        fileId: 'f-cached',
        path: 'att/c.bin',
        blobRef: 'm-cached',
        sizeBytes: 2,
        hlc: store.nextHlc(),
        chunks: const [chunk],
      ));

      var diskCalls = 0;
      await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
        recoverBytes: (_, __) async {
          diskCalls++;
          return const {};
        },
      )();

      expect(diskCalls, 0, reason: 'no reason to re-read a file we already hold');
      expect(remote.store[chunk], cached);
    });

    test('without a disk source the old cache-only behaviour stands', () async {
      final store = await _newStore();
      final remote = _MemRemote();
      final local = _newLocalStore();

      remote.store['m-none'] = Uint8List.fromList([9]);
      remote.hideFromExists.add('c-none');
      store.applyLocal(FileState(
        fileId: 'f-none',
        path: 'att/x.bin',
        blobRef: 'm-none',
        sizeBytes: 1,
        hlc: store.nextHlc(),
        chunks: const ['c-none'],
      ));

      final result = await VerifyBlobsUseCase(
        store: store,
        blobStorage: remote,
        localBlobStore: local,
        vaultId: _vaultId,
      )();

      expect(result.unhealable, 1);
    });
  });
}
