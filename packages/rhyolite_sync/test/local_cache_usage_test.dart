import 'dart:typed_data';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

const _vaultId = '00000000-0000-4000-8000-0000000000dd';

Future<({FileStateStore store, LocalBlobStore blobs})> _fixture() async {
  final env = await DataServiceFactory.inMemory();
  addTearDown(env.dispose);
  final store = FileStateStore(client: env.client, vaultId: _vaultId);
  await store.load();
  return (store: store, blobs: LocalBlobStore(InMemoryBlobRepository()));
}

Uint8List _bytes(int n) => Uint8List(n);

Future<void> _put(
  LocalBlobStore blobs,
  String id,
  int size,
) => blobs.write(_bytes(size), id, vaultId: _vaultId);

void _track(
  FileStateStore store,
  String path,
  List<String> chunks, {
  String blobRef = '',
  bool tombstone = false,
}) {
  store.upsert(FileState(
    fileId: path, // the id shape does not matter here, only the attribution
    path: path,
    blobRef: blobRef,
    sizeBytes: 0,
    hlc: store.nextHlc(),
    chunks: chunks,
    tombstone: tombstone,
  ));
}

void main() {
  group('LocalCacheUsageUseCase', () {
    test('attributes bytes to the file that references them', () async {
      final f = await _fixture();
      await _put(f.blobs, 'bin-chunk', 1000);
      await _put(f.blobs, 'txt-chunk', 300);
      _track(f.store, 'att/photo.png', ['bin-chunk']);
      _track(f.store, 'note.md', ['txt-chunk']);

      final usage = await LocalCacheUsageUseCase(
        store: f.store,
        blobStore: f.blobs,
        vaultId: _vaultId,
      )();

      expect(usage.totalBytes, 1300);
      expect(usage.blobCount, 2);
      expect(usage.binaryBytes, 1000);
      expect(usage.textBytes, 300);
      expect(usage.orphanBytes, 0);
    });

    test('a blob nothing references counts as reclaimable orphan', () async {
      final f = await _fixture();
      await _put(f.blobs, 'live', 100);
      await _put(f.blobs, 'stale', 700);
      _track(f.store, 'note.md', ['live']);

      final usage = await LocalCacheUsageUseCase(
        store: f.store,
        blobStore: f.blobs,
        vaultId: _vaultId,
      )();

      expect(usage.orphanBytes, 700);
      expect(usage.textBytes, 100);
    });

    test('a tombstoned file owns nothing — its bytes read as orphans',
        () async {
      final f = await _fixture();
      await _put(f.blobs, 'gone-chunk', 500);
      _track(f.store, 'deleted.png', ['gone-chunk'], tombstone: true);

      final usage = await LocalCacheUsageUseCase(
        store: f.store,
        blobStore: f.blobs,
        vaultId: _vaultId,
      )();

      expect(usage.orphanBytes, 500);
      expect(usage.binaryBytes, 0);
    });

    test('the force-binary policy decides which side a file counts on',
        () async {
      final f = await _fixture();
      await _put(f.blobs, 'data-chunk', 900);
      _track(f.store, 'data.json', ['data-chunk']);

      final byDefault = await LocalCacheUsageUseCase(
        store: f.store,
        blobStore: f.blobs,
        vaultId: _vaultId,
      )();
      expect(byDefault.textBytes, 900, reason: '.json is a text type by default');

      final forced = await LocalCacheUsageUseCase(
        store: f.store,
        blobStore: f.blobs,
        vaultId: _vaultId,
        forcedBinaryExtensions: const {'json'},
      )();
      expect(forced.binaryBytes, 900,
          reason: 'the vault policy must move it, or the report would '
              'disagree with what the engine actually does');
    });

    test('redundant bytes are only claimed for files really on disk',
        () async {
      final f = await _fixture();
      await _put(f.blobs, 'here-chunk', 1000);
      await _put(f.blobs, 'gone-chunk', 400);
      _track(f.store, 'att/here.png', ['here-chunk']);
      _track(f.store, 'att/gone.png', ['gone-chunk']);

      final blind = await LocalCacheUsageUseCase(
        store: f.store,
        blobStore: f.blobs,
        vaultId: _vaultId,
      )();
      expect(blind.redundantBinaryBytes, 0,
          reason: 'without a disk probe it must report nothing, not guess');

      final probed = await LocalCacheUsageUseCase(
        store: f.store,
        blobStore: f.blobs,
        vaultId: _vaultId,
        fileOnDisk: (p) async => p == 'att/here.png',
      )();
      expect(probed.binaryBytes, 1400);
      expect(probed.redundantBinaryBytes, 1000,
          reason: 'only the file that is actually on disk can be regenerated');
    });

    test('a chunk shared by two files is counted once', () async {
      final f = await _fixture();
      await _put(f.blobs, 'shared', 1000);
      _track(f.store, 'att/a.png', ['shared']);
      _track(f.store, 'att/b.png', ['shared']);

      final usage = await LocalCacheUsageUseCase(
        store: f.store,
        blobStore: f.blobs,
        vaultId: _vaultId,
        fileOnDisk: (_) async => true,
      )();

      expect(usage.totalBytes, 1000, reason: 'content addressing stores it once');
      expect(usage.binaryBytes, 1000);
      expect(usage.redundantBinaryBytes, 1000,
          reason: 'attributed to one owner, never double-counted');
    });
  });
}
