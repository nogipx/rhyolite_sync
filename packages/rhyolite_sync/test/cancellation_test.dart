/// Cancellation-token plumbing through the client-side blob/sync stack.
///
/// Covers the three commit-point invariants:
///   1. ChunkedBlobIO honors the token between chunks and before
///      delegating to IBlobStorage.
///   2. DiskReconciler does not persist anything when cancel fires
///      mid-upload — the file stays "dirty on disk" so a re-run picks
///      it up.
///   3. The IBlobStorage shim properly forwards the context.
import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/sync_v3/disk_reconciler.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

const _vaultPath = '/vault';
const _vaultId = '00000000-0000-4000-8000-000000000099';

class _MemRemote implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  @override
  Future<Set<String>> exists(List<String> blobIds, {RpcContext? context}) async =>
      {for (final id in blobIds) if (store.containsKey(id)) id};
  int uploads = 0;
  int downloads = 0;

  /// If set, called immediately before each upload — used by tests to
  /// trigger cancellation mid-call.
  void Function()? onBeforeUpload;

  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    RpcContext? context,
  }) async {
    onBeforeUpload?.call();
    context?.cancellationToken?.throwIfCancelled();
    uploads++;
    for (final (bytes, id) in blobs) {
      store[id] = bytes;
    }
  }

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    downloads++;
    context?.cancellationToken?.throwIfCancelled();
    return {
      for (final id in blobIds)
        if (store.containsKey(id)) id: store[id]!,
    };
  }

  @override
  Future<void> deleteMany(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    for (final id in blobIds) {
      store.remove(id);
    }
  }
}

class _MemIo implements IPlatformIO {
  final Map<String, Uint8List> files = {};

  @override
  Future<bool> fileExists(String absolutePath) async =>
      files.containsKey(absolutePath);
  @override
  Future<bool> dirExists(String absolutePath) async => true;
  @override
  Future<Uint8List> readFile(String absolutePath) async {
    final b = files[absolutePath];
    if (b == null) throw StateError('no file at $absolutePath');
    return b;
  }
  @override
  Future<void> writeFile(String absolutePath, Uint8List bytes) async {
    files[absolutePath] = bytes;
  }
  @override
  Future<void> deleteFile(String absolutePath) async {
    files.remove(absolutePath);
  }
  @override
  Future<void> moveFile(String from, String to) async {
    final b = files.remove(from);
    if (b != null) files[to] = b;
  }
  @override
  Future<void> deleteEmptyDirsUpTo(String dirPath, String stopAt) async {}
  @override
  Future<List<String>> listFiles(String absoluteDirPath) async =>
      files.keys.where((p) => p.startsWith(absoluteDirPath)).toList();
  @override
  Future<FileStatInfo?> statFile(String absolutePath) async {
    final b = files[absolutePath];
    if (b == null) return null;
    return FileStatInfo(mtimeMs: 0, sizeBytes: b.length);
  }
}

class _NoopChangeProvider implements IChangeProvider {
  @override
  Stream<FileChangeEvent> get changes => const Stream.empty();
  @override
  Stream<String> get typing => const Stream.empty();
  @override
  void suppress(
    String path, {
    int count = 1,
    Duration holdFor = const Duration(seconds: 2),
  }) {}
  @override
  void unsuppress(String path) {}
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('ChunkedBlobIO cancellation', () {
    test('upload throws when token is already cancelled', () async {
      final remote = _MemRemote();
      final local = LocalBlobStore(InMemoryBlobRepository());
      final io = ChunkedBlobIO(
        blobStore: local,
        remoteBlobStorage: remote,
        vaultId: _vaultId,
      );

      final token = RpcCancellationToken()..cancel('test');
      await expectLater(
        () => io.upload(
          _bytes('hello'),
          const {},
          context: RpcContext.withCancellation(token),
        ),
        throwsA(isA<RpcCancelledException>()),
      );
      expect(remote.uploads, 0);
    });

    test('upload throws when token cancels mid-flight (before remote)',
        () async {
      final remote = _MemRemote();
      final local = LocalBlobStore(InMemoryBlobRepository());
      final io = ChunkedBlobIO(
        blobStore: local,
        remoteBlobStorage: remote,
        vaultId: _vaultId,
      );

      final token = RpcCancellationToken();
      remote.onBeforeUpload = () => token.cancel('mid-flight');

      await expectLater(
        () => io.upload(
          _bytes('hello world'),
          const {},
          context: RpcContext.withCancellation(token),
        ),
        throwsA(isA<RpcCancelledException>()),
      );
      expect(remote.uploads, 0,
          reason: 'remote.upload must throw before counting the call');
    });

    test('download throws when token already cancelled', () async {
      final remote = _MemRemote();
      final local = LocalBlobStore(InMemoryBlobRepository());
      final io = ChunkedBlobIO(
        blobStore: local,
        remoteBlobStorage: remote,
        vaultId: _vaultId,
      );
      final token = RpcCancellationToken()..cancel('test');
      await expectLater(
        () => io.download(
          'whatever',
          context: RpcContext.withCancellation(token),
        ),
        throwsA(isA<RpcCancelledException>()),
      );
    });
  });

  group('DiskReconciler cancellation', () {
    Future<({
      DiskReconciler reconciler,
      FileStateStore store,
      FugueStore fugueStore,
      _MemIo io,
      _MemRemote remote,
    })> newFixture() async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = FileStateStore(client: env.client, vaultId: _vaultId);
      await store.load();
      final fugueStore = FugueStore(client: env.client, vaultId: _vaultId);
      await fugueStore.load();
      final io = _MemIo();
      final localBlobs = LocalBlobStore(InMemoryBlobRepository());
      final remote = _MemRemote();
      String fileIdFor(String p) => const Uuid().v5(_vaultId, p);
      ChunkedBlobIO? builder() => ChunkedBlobIO(
            blobStore: localBlobs,
            remoteBlobStorage: remote,
            vaultId: _vaultId,
          );
      final reconciler = DiskReconciler(
        vaultPath: _vaultPath,
        vaultId: _vaultId,
        io: io,
        blobStore: localBlobs,
        changeProvider: _NoopChangeProvider(),
        store: store,
        fugueStore: fugueStore,
        chunkedIOBuilder: builder,
        knownChunks: () => {
          for (final s in store.allValuesFlat) ...s.chunks,
        },
        fileIdFor: fileIdFor,
        emit: (_) {},
      );
      return (
        reconciler: reconciler,
        store: store,
        fugueStore: fugueStore,
        io: io,
        remote: remote,
      );
    }

    test('binary reconcile cancellation -> nothing persisted', () async {
      final f = await newFixture();
      f.io.files['$_vaultPath/img.bin'] = _bytes('binary blob content');

      final token = RpcCancellationToken();
      // Cancel at the moment remote.upload would be called, BEFORE any
      // FileState persistence.
      f.remote.onBeforeUpload = () => token.cancel('user typing');

      await expectLater(
        () => f.reconciler.reconcileWithDisk(
          'img.bin',
          context: RpcContext.withCancellation(token),
        ),
        throwsA(isA<RpcCancelledException>()),
      );

      final fileId = const Uuid().v5(_vaultId, 'img.bin');
      expect(f.store.get(fileId), isNull,
          reason: 'FileState must NOT be written when upload is cancelled');
      expect(f.remote.uploads, 0);
    });

    test('text reconcile cancellation -> fugueStore + FileState untouched',
        () async {
      final f = await newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('hello world');

      final token = RpcCancellationToken();
      f.remote.onBeforeUpload = () => token.cancel('user typing');

      await expectLater(
        () => f.reconciler.reconcileWithDisk(
          'note.md',
          context: RpcContext.withCancellation(token),
        ),
        throwsA(isA<RpcCancelledException>()),
      );

      final fileId = const Uuid().v5(_vaultId, 'note.md');
      expect(f.store.get(fileId), isNull,
          reason: 'FileState must NOT be written when upload is cancelled');
      expect(await f.fugueStore.get(fileId), isNull,
          reason: 'Sequence must NOT be cached when upload is cancelled');
    });

    test(
      're-reconciling after cancellation picks the file up cleanly',
      () async {
        final f = await newFixture();
        f.io.files['$_vaultPath/note.md'] = _bytes('hello world');

        final cancelledToken = RpcCancellationToken();
        f.remote.onBeforeUpload = () => cancelledToken.cancel('typing');
        await expectLater(
          () => f.reconciler.reconcileWithDisk(
            'note.md',
            context: RpcContext.withCancellation(cancelledToken),
          ),
          throwsA(isA<RpcCancelledException>()),
        );

        // Now retry without a cancellation hook — should succeed.
        f.remote.onBeforeUpload = null;
        final changed = await f.reconciler.reconcileWithDisk('note.md');
        expect(changed, isTrue);
        final fileId = const Uuid().v5(_vaultId, 'note.md');
        expect(f.store.get(fileId), isNotNull);
        expect((await f.fugueStore.get(fileId))?.values.join(), 'hello world');
      },
    );
  });
}
