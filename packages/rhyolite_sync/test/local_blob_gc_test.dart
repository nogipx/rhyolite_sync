import 'dart:typed_data';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/src/local/local_blob_store.dart';
import 'package:rhyolite_sync/src/sync_v3/file_state.dart';
import 'package:rhyolite_sync/src/sync_v3/file_state_store.dart';
import 'package:rhyolite_sync/src/sync_v3/local_blob_gc.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

const _v = 'vault-1';

FileState _state(String fileId, {required String blobRef}) => FileState(
      fileId: fileId,
      path: '$fileId.md',
      blobRef: blobRef,
      sizeBytes: 1,
      hlc: Hlc(1, 0, 'A'),
    );

Future<void> _seedBlob(LocalBlobStore blobs, String id, List<int> bytes) =>
    blobs.write(Uint8List.fromList(bytes), id, vaultId: _v);

void main() {
  late IDataClient dataClient;
  late FileStateStore store;
  late LocalBlobStore blobs;
  late LocalBlobGc gc;

  setUp(() async {
    final env = await DataServiceFactory.inMemory();
    addTearDown(env.dispose);
    dataClient = env.client;
    store = FileStateStore(client: dataClient, vaultId: _v);
    await store.load();
    blobs = LocalBlobStore(InMemoryBlobRepository());
    gc = LocalBlobGc(store: store, blobStore: blobs, vaultId: _v);
  });

  test('keeps blobs referenced by current file_state', () async {
    await _seedBlob(blobs, 'blob-current', [1]);
    store.upsert(_state('f1', blobRef: 'blob-current'));

    final r = await gc();
    expect(r.scanned, 1);
    expect(r.deleted, 0);
    expect(await blobs.read('blob-current', vaultId: _v), isNotNull);
  });

  test('keeps blobs referenced by lastSyncedBlobRef (3-way merge base)',
      () async {
    await _seedBlob(blobs, 'blob-base', [2]);
    await _seedBlob(blobs, 'blob-current', [3]);
    store.upsert(_state('f1', blobRef: 'blob-current'));
    // lastSyncedBlobRef points at a different blob — the base we keep
    // around for a possible next 3-way merge.
    store.recordSyncedBlobRef('f1', 'blob-base');

    final r = await gc();
    expect(r.scanned, 2);
    expect(r.deleted, 0,
        reason: 'both current and base must stay alive');
  });

  test('deletes orphans not referenced by any file_state or base', () async {
    await _seedBlob(blobs, 'blob-current', [1]);
    await _seedBlob(blobs, 'blob-orphan-A', [4]);
    await _seedBlob(blobs, 'blob-orphan-B', [5]);
    store.upsert(_state('f1', blobRef: 'blob-current'));

    final r = await gc();
    expect(r.scanned, 3);
    expect(r.deleted, 2);
    expect(await blobs.read('blob-current', vaultId: _v), isNotNull);
    expect(await blobs.read('blob-orphan-A', vaultId: _v), isNull);
    expect(await blobs.read('blob-orphan-B', vaultId: _v), isNull);
  });

  test('handles empty store gracefully', () async {
    final r = await gc();
    expect(r.scanned, 0);
    expect(r.deleted, 0);
  });

  test('handles empty blob cache gracefully', () async {
    store.upsert(_state('f1', blobRef: 'no-such-blob'));
    final r = await gc();
    expect(r.scanned, 0);
    expect(r.deleted, 0);
  });

  test('idempotent: second run after first deletes nothing', () async {
    await _seedBlob(blobs, 'blob-keep', [1]);
    await _seedBlob(blobs, 'blob-drop', [2]);
    store.upsert(_state('f1', blobRef: 'blob-keep'));

    final first = await gc();
    expect(first.deleted, 1);

    final second = await gc();
    expect(second.scanned, 1);
    expect(second.deleted, 0);
  });
}
