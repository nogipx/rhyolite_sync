import 'dart:typed_data';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/src/local/local_blob_store.dart';
import 'package:rhyolite_sync/src/sync_v3/file_state.dart';
import 'package:rhyolite_sync/src/sync_v3/file_state_store.dart';
import 'package:rhyolite_sync/src/sync_v3/local_blob_gc.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
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

  test(
    'drops a lastSyncedBlobRef blob that is no longer current content',
    () async {
      await _seedBlob(blobs, 'blob-base', [2]);
      await _seedBlob(blobs, 'blob-current', [3]);
      store.upsert(_state('f1', blobRef: 'blob-current'));
      store.recordSyncedBlobRef('f1', 'blob-base');

      final r = await gc();
      expect(r.scanned, 2);
      // The LCA is compared as a hash and its bytes are never read (the 3-way
      // merge that once needed them is gone), so keeping a second copy of every
      // file that has ever changed is pure waste.
      expect(r.deleted, 1);
      expect(await blobs.read('blob-current', vaultId: _v), isNotNull);
      expect(await blobs.read('blob-base', vaultId: _v), isNull);
    },
  );

  test(
    'keeps a lastSyncedBlobRef blob that is still some file\'s content',
    () async {
      await _seedBlob(blobs, 'blob-shared', [7]);
      store.upsert(_state('f1', blobRef: 'blob-shared'));
      store.recordSyncedBlobRef('f1', 'blob-shared');

      final r = await gc();
      expect(r.deleted, 0);
      expect(await blobs.read('blob-shared', vaultId: _v), isNotNull);
    },
  );

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

  group('regenerable blobs', () {
    FileState binary(String id, {required List<String> chunks, String? path}) =>
        FileState(
          fileId: id,
          path: path ?? 'att/$id.bin',
          blobRef: 'manifest-$id',
          sizeBytes: 1,
          hlc: Hlc(1, 0, 'A'),
          chunks: chunks,
        );

    test('drops the chunks of a file that can rebuild them', () async {
      await _seedBlob(blobs, 'manifest-a', [1]);
      await _seedBlob(blobs, 'chunk-a', [2]);
      store.upsert(binary('a', chunks: ['chunk-a']));

      final r = await LocalBlobGc(
        store: store,
        blobStore: blobs,
        vaultId: _v,
        isRegenerable: (_) async => true,
      )();

      expect(r.deleted, 2, reason: 'the manifest is derivable too');
      expect(await blobs.listBlobIds(vaultId: _v), isEmpty);
    });

    test('keeps them when the file cannot rebuild them', () async {
      await _seedBlob(blobs, 'manifest-a', [1]);
      await _seedBlob(blobs, 'chunk-a', [2]);
      store.upsert(binary('a', chunks: ['chunk-a']));

      final r = await LocalBlobGc(
        store: store,
        blobStore: blobs,
        vaultId: _v,
        isRegenerable: (_) async => false,
      )();

      expect(r.deleted, 0);
    });

    test(
      'a chunk shared with a file that cannot rebuild it survives',
      () async {
        // Content addressing means one chunk can belong to several files. The
        // deciding vote is the owner that still needs it kept.
        await _seedBlob(blobs, 'manifest-a', [1]);
        await _seedBlob(blobs, 'manifest-b', [1]);
        await _seedBlob(blobs, 'shared', [2]);
        store.upsert(binary('a', chunks: ['shared']));
        store.upsert(binary('b', chunks: ['shared']));

        await LocalBlobGc(
          store: store,
          blobStore: blobs,
          vaultId: _v,
          // Only 'a' is on disk.
          isRegenerable: (state) async => state.fileId == 'a',
        )();

        final left = await blobs.listBlobIds(vaultId: _v);
        expect(
          left,
          contains('shared'),
          reason: "b still needs it, and b's copy is the only one left",
        );
        expect(left, contains('manifest-b'));
        expect(left, isNot(contains('manifest-a')));
      },
    );

    test('a sibling sync claim outranks regenerability', () async {
      await _seedBlob(blobs, 'manifest-a', [1]);
      await _seedBlob(blobs, 'chunk-a', [2]);
      store.upsert(binary('a', chunks: ['chunk-a']));

      await LocalBlobGc(
        store: store,
        blobStore: blobs,
        vaultId: _v,
        externalLiveIds: () => {'chunk-a'},
        isRegenerable: (_) async => true,
      )();

      final left = await blobs.listBlobIds(vaultId: _v);
      expect(
        left,
        ['chunk-a'],
        reason:
            'the settings sync stores its blobs here too, and no file '
            'on disk can rebuild those',
      );
    });

    test('a contested file keeps every version\'s blobs', () async {
      // Two live values share one fileId and one path. Disk holds the winner;
      // the loser's bytes exist only here, and the conflict copy that should
      // preserve them reads from this cache. Evicting them as "the file is on
      // disk" would delete the one copy of the version nobody has.
      await _seedBlob(blobs, 'winner-chunk', [1]);
      await _seedBlob(blobs, 'loser-chunk', [2]);
      final winner = FileState(
        fileId: 'contested',
        path: 'att/photo.png',
        blobRef: 'manifest-w',
        sizeBytes: 1,
        hlc: Hlc(2, 0, 'A'),
        chunks: const ['winner-chunk'],
      );
      final loser = FileState(
        fileId: 'contested',
        path: 'att/photo.png',
        blobRef: 'manifest-l',
        sizeBytes: 1,
        hlc: Hlc(2, 0, 'B'),
        chunks: const ['loser-chunk'],
      );
      store.applyLocal(winner);
      store.applyRemote('contested', [TaggedValue(loser, loser.hlc)]);
      expect(
        store.hasConflict('contested'),
        isTrue,
        reason: 'the fixture must really be in conflict',
      );

      // The engine refuses on conflict; here we model a predicate that cannot
      // tell the two values apart, which is exactly what a path+signature
      // check does.
      await LocalBlobGc(
        store: store,
        blobStore: blobs,
        vaultId: _v,
        isRegenerable: (s) async => !store.hasConflict(s.fileId),
      )();

      final left = await blobs.listBlobIds(vaultId: _v);
      expect(left, containsAll(['winner-chunk', 'loser-chunk']));
    });

    test('without the predicate nothing referenced is dropped', () async {
      await _seedBlob(blobs, 'manifest-a', [1]);
      await _seedBlob(blobs, 'chunk-a', [2]);
      store.upsert(binary('a', chunks: ['chunk-a']));

      final r = await LocalBlobGc(
        store: store,
        blobStore: blobs,
        vaultId: _v,
      )();

      expect(r.deleted, 0, reason: 'the behaviour that shipped before this');
    });

    test('orphans are still collected regardless', () async {
      await _seedBlob(blobs, 'nobody', [9]);

      final r = await LocalBlobGc(
        store: store,
        blobStore: blobs,
        vaultId: _v,
        isRegenerable: (_) async => true,
      )();

      expect(r.deleted, 1);
    });
  });

  group('scoped to what a pull staged', () {
    test(
      'an orphan outside the candidates is left for the full sweep',
      () async {
        // The point of scoping is cost, not reach: a pull pays for its own
        // leftovers, and the startup sweep still collects everything else.
        await _seedBlob(blobs, 'just-pulled', [1]);
        await _seedBlob(blobs, 'old-orphan', [2]);

        final scoped = await gc(candidates: {'just-pulled'});
        expect(scoped.deleted, 1);
        expect(
          await blobs.read('old-orphan', vaultId: _v),
          isNotNull,
          reason: 'an id nobody asked about must not be touched',
        );

        expect((await gc()).deleted, 1, reason: 'the full sweep still gets it');
      },
    );

    test(
      'a candidate pinned by a file that cannot rebuild it survives',
      () async {
        // Chunks are content-addressed and shared. A pull staging one that some
        // other file depends on must not delete it just because the pulled file
        // no longer needs it.
        await _seedBlob(blobs, 'shared', [3]);
        store.upsert(_state('keeper', blobRef: 'shared'));

        final r = await LocalBlobGc(
          store: store,
          blobStore: blobs,
          vaultId: _v,
          isRegenerable: (_) async => false,
        )(candidates: {'shared'});

        expect(r.deleted, 0);
        expect(await blobs.read('shared', vaultId: _v), isNotNull);
      },
    );

    test('an empty candidate set does no work at all', () async {
      await _seedBlob(blobs, 'orphan', [4]);
      final r = await gc(candidates: const {});
      expect(r.deleted, 0);
      expect(await blobs.read('orphan', vaultId: _v), isNotNull);
    });
  });

  group('cancellation', () {
    test('aborting during the state walk deletes NOTHING', () async {
      // Stopping mid-walk leaves the pinned set half built, and acting on it
      // would delete a blob merely because its owner had not been reached
      // yet. The sweep must forfeit the whole pass instead.
      await _seedBlob(blobs, 'orphan', [5]);
      store.upsert(_state('f1', blobRef: 'other'));

      final token = RpcCancellationToken()..cancel('user is typing');
      final r = await LocalBlobGc(
        store: store,
        blobStore: blobs,
        vaultId: _v,
        isRegenerable: (_) async => true,
      )(context: RpcContext.withCancellation(token));

      expect(r.skipped, isTrue);
      expect(r.deleted, 0);
      expect(
        await blobs.read('orphan', vaultId: _v),
        isNotNull,
        reason: 'a half-built pinned set must never authorise a delete',
      );
    });
  });
}
