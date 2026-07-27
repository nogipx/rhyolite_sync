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

  group('sibling live set (settings sync shares this cache)', () {
    LocalBlobGc gcWith(Set<String>? Function() external) => LocalBlobGc(
          store: store,
          blobStore: blobs,
          vaultId: _v,
          externalLiveIds: external,
        );

    test('keeps blobs claimed by the sibling', () async {
      // Plugin-code blobs live in this same cache under the same vaultId, but
      // no file_state references them. Without the sibling live set they look
      // exactly like orphans and get evicted right after being written.
      await _seedBlob(blobs, 'plugin-manifest', [1]);
      await _seedBlob(blobs, 'plugin-chunk', [2]);

      final r = await gcWith(() => {'plugin-manifest', 'plugin-chunk'})();
      expect(r.deleted, 0);
      expect(await blobs.read('plugin-chunk', vaultId: _v), isNotNull);
    });

    test('still deletes what neither side claims', () async {
      await _seedBlob(blobs, 'plugin-chunk', [1]);
      await _seedBlob(blobs, 'stale-plugin-chunk', [2]);

      // A plugin update drops the old version from the sibling's live set —
      // this is how the previous version leaves the local cache.
      final r = await gcWith(() => {'plugin-chunk'})();
      expect(r.deleted, 1);
      expect(await blobs.read('plugin-chunk', vaultId: _v), isNotNull);
      expect(await blobs.read('stale-plugin-chunk', vaultId: _v), isNull);
    });

    test('null means not ready and skips the sweep entirely', () async {
      await _seedBlob(blobs, 'plugin-chunk', [1]);
      await _seedBlob(blobs, 'real-orphan', [2]);

      final r = await gcWith(() => null)();
      expect(r.skipped, isTrue);
      expect(r.deleted, 0);
      // Even a genuine orphan survives: an incomplete live set must never
      // delete anything. The next sweep, once the sibling has loaded, gets it.
      expect(await blobs.read('real-orphan', vaultId: _v), isNotNull);
    });

    test('an empty sibling set is an answer, not a refusal', () async {
      // Settings sync off: leftovers from when it was on are collectable.
      await _seedBlob(blobs, 'leftover-plugin-chunk', [1]);

      final r = await gcWith(() => const <String>{})();
      expect(r.skipped, isFalse);
      expect(r.deleted, 1);
    });

    test('no provider at all behaves exactly as before', () async {
      await _seedBlob(blobs, 'orphan', [1]);
      final r = await gc();
      expect(r.skipped, isFalse);
      expect(r.deleted, 1);
    });
  });
}
