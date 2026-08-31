/// Re-uploading to a freshly connected backend is not the same job as
/// verifying an established one, and it was being done by the verify pass.
///
/// The differences show up exactly when the backend is empty — which is the
/// only time the button is pressed.
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

const _vaultId = '00000000-0000-4000-8000-0000000000cc';

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

/// Records the ORDER in which blobs were offered, so a test can assert that
/// no manifest went up before the chunks it names.
class _RecordingRemote implements IBlobStorage {
  final List<List<String>> calls = [];
  final Set<String> stored = {};
  int existsCalls = 0;

  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    RpcContext? context,
  }) async {
    calls.add(blobs.map((b) => b.$2).toList());
    stored.addAll(blobs.map((b) => b.$2));
  }

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    existsCalls++;
    return {
      for (final id in blobIds)
        if (stored.contains(id)) id,
    };
  }

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async => {};

  @override
  Future<void> deleteMany(List<String> blobIds, {RpcContext? context}) async {}
}

/// The order in which [id] first appears across all upload calls.
int _positionOf(_RecordingRemote remote, String id) {
  var i = 0;
  for (final call in remote.calls) {
    for (final blob in call) {
      if (blob == id) return i;
      i++;
    }
  }
  return -1;
}

Future<FileStateStore> _storeWith(
  IDataClient client,
  List<({String path, String manifest, List<String> chunks})> files,
) async {
  final store = FileStateStore(client: client, vaultId: _vaultId);
  await store.load();
  for (final f in files) {
    store.applyLocal(
      FileState(
        fileId: f.path,
        path: f.path,
        blobRef: f.manifest,
        chunks: f.chunks,
        sizeBytes: 1,
        hlc: store.nextHlc(),
      ),
    );
  }
  return store;
}

void main() {
  group('re-uploading to a backend that has nothing', () {
    late IDataClient client;

    setUp(() async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      client = env.client;
    });

    test('sends everything without asking the backend what it holds', () async {
      // Verify probes first, and on a backend just connected the answer is
      // "all of it is missing" — the whole exists sweep is round trips spent
      // learning that an empty bucket is empty.
      final store = await _storeWith(client, [
        (path: 'a.md', manifest: 'm-a', chunks: ['c-a1', 'c-a2']),
        (path: 'b.md', manifest: 'm-b', chunks: ['c-b1']),
      ]);
      final remote = _RecordingRemote();

      final result = await ReuploadStorageUseCase(
        store: store,
        blobStorage: remote,
        regenerate: (path, wanted) async => {
          for (final id in wanted) id: _bytes('$path/$id'),
        },
      )();

      expect(remote.existsCalls, 0, reason: 'nothing to probe on an empty one');
      expect(result.files, 2);
      expect(result.uploadedFiles, 2);
      expect(remote.stored, {'m-a', 'c-a1', 'c-a2', 'm-b', 'c-b1'});
      expect(result.unreproducible, 0);
    });

    test('no manifest goes up before the chunks it names', () async {
      // The reason this could not stay inside verify. Verify uploads missing
      // ids in id-set order, mixing manifests with chunks; a manifest visible
      // while a chunk it names is absent is the silent-loss failure, and on an
      // empty backend that is every file rather than an unlucky one.
      final store = await _storeWith(client, [
        (path: 'a.md', manifest: 'm-a', chunks: ['c-a1', 'c-a2']),
        (path: 'b.md', manifest: 'm-b', chunks: ['c-b1']),
        (path: 'c.md', manifest: 'm-c', chunks: ['c-c1']),
      ]);
      final remote = _RecordingRemote();

      await ReuploadStorageUseCase(
        store: store,
        blobStorage: remote,
        regenerate: (path, wanted) async => {
          for (final id in wanted) id: _bytes('$path/$id'),
        },
      )();

      for (final manifest in ['m-a', 'm-b', 'm-c']) {
        final at = _positionOf(remote, manifest);
        expect(at, greaterThanOrEqualTo(0), reason: '$manifest was not sent');
        for (final chunk in ['c-a1', 'c-a2', 'c-b1', 'c-c1']) {
          expect(
            _positionOf(remote, chunk),
            lessThan(at),
            reason: '$chunk must precede every manifest in its group',
          );
        }
      }
    });

    test(
      'a file this device cannot rebuild is named, not silently skipped',
      () async {
        // Content that only another device holds. Counted per FILE because that
        // is the unit a user can act on — "open the plugin on the laptop" is
        // advice, "142 unhealable blobs" is not.
        final store = await _storeWith(client, [
          (path: 'mine.md', manifest: 'm-mine', chunks: ['c-mine']),
          (path: 'theirs.md', manifest: 'm-theirs', chunks: ['c-theirs']),
        ]);
        final remote = _RecordingRemote();

        final result = await ReuploadStorageUseCase(
          store: store,
          blobStorage: remote,
          regenerate: (path, wanted) async => path == 'mine.md'
              ? {for (final id in wanted) id: _bytes(id)}
              : {},
        )();

        expect(result.unreproducible, 1);
        expect(result.unreproducibleSample, ['theirs.md']);
        expect(result.uploadedFiles, 1);
        expect(result.isComplete, isFalse);
      },
    );

    test(
      'loose chunks are not sent when the manifest cannot be rebuilt',
      () async {
        // A peer resolves content by manifest, so chunks without one are
        // unreachable: uploading them spends bandwidth to leave the file exactly
        // as missing as it was.
        final store = await _storeWith(client, [
          (path: 'partial.md', manifest: 'm-p', chunks: ['c-p1', 'c-p2']),
        ]);
        final remote = _RecordingRemote();

        final result = await ReuploadStorageUseCase(
          store: store,
          blobStorage: remote,
          // The chunks come back, the manifest does not.
          regenerate: (path, wanted) async => {
            for (final id in wanted)
              if (id != 'm-p') id: _bytes(id),
          },
        )();

        expect(remote.stored, isEmpty);
        expect(result.unreproducible, 1);
        expect(result.uploadedBlobs, 0);
      },
    );

    test('a tombstone is not re-uploaded', () async {
      final store = FileStateStore(client: client, vaultId: _vaultId);
      await store.load();
      store.applyLocal(
        FileState(
          fileId: 'gone.md',
          path: 'gone.md',
          blobRef: 'm-gone',
          chunks: const ['c-gone'],
          sizeBytes: 0,
          hlc: store.nextHlc(),
          tombstone: true,
        ),
      );
      final remote = _RecordingRemote();

      final result = await ReuploadStorageUseCase(
        store: store,
        blobStorage: remote,
        regenerate: (path, wanted) async => {
          for (final id in wanted) id: _bytes(id),
        },
      )();

      expect(result.files, 0);
      expect(remote.stored, isEmpty);
    });

    test('a regeneration that throws costs one file, not the pass', () async {
      final store = await _storeWith(client, [
        (path: 'bad.md', manifest: 'm-bad', chunks: ['c-bad']),
        (path: 'good.md', manifest: 'm-good', chunks: ['c-good']),
      ]);
      final remote = _RecordingRemote();

      final result = await ReuploadStorageUseCase(
        store: store,
        blobStorage: remote,
        regenerate: (path, wanted) async {
          if (path == 'bad.md') throw StateError('unreadable');
          return {for (final id in wanted) id: _bytes(id)};
        },
      )();

      expect(result.uploadedFiles, 1);
      expect(result.unreproducible, 1);
      expect(remote.stored, {'m-good', 'c-good'});
    });

    test('cancellation stops it without publishing a bare manifest', () async {
      // Cut during the chunk phase and no manifest was sent at all; cut during
      // the manifests and every chunk is already up. Neither leaves anything
      // published pointing at something absent.
      final store = await _storeWith(client, [
        for (var i = 0; i < 40; i++)
          (path: 'f$i.md', manifest: 'm-$i', chunks: ['c-$i']),
      ]);
      final remote = _RecordingRemote();
      final token = RpcCancellationToken();

      var seen = 0;
      final future = ReuploadStorageUseCase(
        store: store,
        blobStorage: remote,
        regenerate: (path, wanted) async {
          if (++seen == 5) token.cancel('test');
          return {for (final id in wanted) id: _bytes(id)};
        },
      )(context: RpcContext.withCancellation(token));

      await expectLater(future, throwsA(isA<RpcCancelledException>()));
      for (final id in remote.stored.where((s) => s.startsWith('m-'))) {
        expect(
          remote.stored,
          contains('c-${id.substring(2)}'),
          reason: 'a published manifest must have its chunk up first',
        );
      }
    });
  });
}
