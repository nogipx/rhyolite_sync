import 'dart:convert';
import 'dart:typed_data';

import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rhyolite_sync/src/sync_v3/disk_reconciler.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

const _vaultPath = '/vault';
const _vaultId = '00000000-0000-4000-8000-000000000001';

class _MemRemote implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  @override
  Future<Set<String>> exists(List<String> blobIds, {RpcContext? context}) async =>
      {for (final id in blobIds) if (store.containsKey(id)) id};

  @override
  Future<void> upload(List<(Uint8List, String)> blobs, {RpcContext? context}) async {
    for (final (bytes, id) in blobs) {
      store[id] = bytes;
    }
  }

  @override
  Future<Map<String, Uint8List>> download(List<String> blobIds, {RpcContext? context}) async {
    return {
      for (final id in blobIds)
        if (store.containsKey(id)) id: store[id]!,
    };
  }

  @override
  Future<void> deleteMany(List<String> blobIds, {RpcContext? context}) async {
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
  final List<String> suppressed = [];

  @override
  Stream<FileChangeEvent> get changes => const Stream.empty();

  @override
  Stream<String> get typing => const Stream.empty();

  @override
  void suppress(
    String path, {
    int count = 1,
    Duration holdFor = const Duration(seconds: 2),
  }) {
    suppressed.add(path);
  }

  @override
  void unsuppress(String path) {}
}

typedef _Fixture = ({
  DiskReconciler reconciler,
  FileStateStore store,
  FugueStore fugueStore,
  _MemIo io,
  _NoopChangeProvider changes,
  LocalBlobStore localBlobs,
  _MemRemote remote,
  List<SyncEngineEvent> events,
  String Function(String) fileIdFor,
});

Future<_Fixture> _newFixture({int? Function()? maxFileSizeBytes}) async {
  final env = await DataServiceFactory.inMemory();
  addTearDown(env.dispose);

  final store = FileStateStore(client: env.client, vaultId: _vaultId);
  await store.load();
  final fugueStore = FugueStore(client: env.client, vaultId: _vaultId);
  await fugueStore.load();

  final io = _MemIo();
  final changes = _NoopChangeProvider();
  final localBlobs = LocalBlobStore(InMemoryBlobRepository());
  final remote = _MemRemote();

  String fileIdFor(String relPath) => const Uuid().v5(_vaultId, relPath);

  ChunkedBlobIO? builder() => ChunkedBlobIO(
    blobStore: localBlobs,
    remoteBlobStorage: remote,
    vaultId: _vaultId,
  );

  final events = <SyncEngineEvent>[];

  final reconciler = DiskReconciler(
    vaultPath: _vaultPath,
    vaultId: _vaultId,
    io: io,
    blobStore: localBlobs,
    changeProvider: changes,
    store: store,
    fugueStore: fugueStore,
    chunkedIOBuilder: builder,
    knownChunks: () => {
      for (final s in store.allValuesFlat) ...s.chunks,
    },
    fileIdFor: fileIdFor,
    emit: events.add,
    maxFileSizeBytes: maxFileSizeBytes,
  );

  return (
    reconciler: reconciler,
    store: store,
    fugueStore: fugueStore,
    io: io,
    changes: changes,
    localBlobs: localBlobs,
    remote: remote,
    events: events,
    fileIdFor: fileIdFor,
  );
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('DiskReconciler — size admission', () {
    test('a file over the per-file limit is skipped and surfaced, not uploaded',
        () async {
      final f = await _newFixture(maxFileSizeBytes: () => 100);
      f.io.files['$_vaultPath/big.bin'] = Uint8List(500); // 500 > 100

      final changed = await f.reconciler.reconcileWithDisk('big.bin');

      expect(changed, isFalse, reason: 'over-limit file produces no state');
      expect(f.store.get(f.fileIdFor('big.bin')), isNull,
          reason: 'no FileState is created for a blocked file');
      expect(f.remote.store, isEmpty, reason: 'nothing was uploaded');
      final blocked = f.events.whereType<SyncFileSizeBlocked>().toList();
      expect(blocked, hasLength(1));
      expect(blocked.single.path, 'big.bin');
      expect(blocked.single.sizeBytes, 500);
      expect(blocked.single.limitBytes, 100);
    });

    test('a file under the limit syncs normally', () async {
      final f = await _newFixture(maxFileSizeBytes: () => 1000);
      f.io.files['$_vaultPath/ok.bin'] = _bytes('small');
      final changed = await f.reconciler.reconcileWithDisk('ok.bin');
      expect(changed, isTrue);
      expect(f.store.get(f.fileIdFor('ok.bin')), isNotNull);
      expect(f.events.whereType<SyncFileSizeBlocked>(), isEmpty);
    });

    test('deleting a blocked file emits SyncFileSizeUnblocked once', () async {
      final f = await _newFixture(maxFileSizeBytes: () => 100);
      f.io.files['$_vaultPath/big.bin'] = Uint8List(500);
      await f.reconciler.reconcileWithDisk('big.bin'); // blocked
      expect(f.events.whereType<SyncFileSizeBlocked>(), hasLength(1));

      f.io.files.remove('$_vaultPath/big.bin'); // deleted from disk
      await f.reconciler.reconcileWithDisk('big.bin');

      final unblocked = f.events.whereType<SyncFileSizeUnblocked>().toList();
      expect(unblocked, hasLength(1));
      expect(unblocked.single.path, 'big.bin');
    });

    test('a blocked file shrinking under the limit unblocks and syncs',
        () async {
      final f = await _newFixture(maxFileSizeBytes: () => 100);
      f.io.files['$_vaultPath/big.bin'] = Uint8List(500);
      await f.reconciler.reconcileWithDisk('big.bin'); // blocked

      f.io.files['$_vaultPath/big.bin'] = _bytes('now small');
      final changed = await f.reconciler.reconcileWithDisk('big.bin');

      expect(f.events.whereType<SyncFileSizeUnblocked>(), hasLength(1));
      expect(changed, isTrue);
      expect(f.store.get(f.fileIdFor('big.bin')), isNotNull);
    });

    test('a never-blocked file never emits SyncFileSizeUnblocked', () async {
      final f = await _newFixture(maxFileSizeBytes: () => 1000);
      f.io.files['$_vaultPath/ok.bin'] = _bytes('small');
      await f.reconciler.reconcileWithDisk('ok.bin');
      // reconcile again (no change) — still no spurious unblock event
      await f.reconciler.reconcileWithDisk('ok.bin');
      expect(f.events.whereType<SyncFileSizeUnblocked>(), isEmpty);
    });
  });

  group('DiskReconciler — binary reconcile', () {
    test('new binary file on disk -> creates FileState with manifest', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/image.bin'] = _bytes('binary content');

      final changed = await f.reconciler.reconcileWithDisk('image.bin');

      expect(changed, isTrue);
      final fileId = f.fileIdFor('image.bin');
      final state = f.store.get(fileId)!;
      expect(state.tombstone, isFalse);
      expect(state.path, 'image.bin');
      expect(state.blobRef, isNotEmpty);
      expect(state.sizeBytes, 14);
    });

    test('binary file no-op -> no state change', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/image.bin'] = _bytes('binary content');
      await f.reconciler.reconcileWithDisk('image.bin');
      final firstHlc = f.store.get(f.fileIdFor('image.bin'))!.hlc;

      final changed = await f.reconciler.reconcileWithDisk('image.bin');

      expect(changed, isFalse);
      expect(f.store.get(f.fileIdFor('image.bin'))!.hlc, firstHlc);
    });

    test('binary file deleted -> tombstone', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/image.bin'] = _bytes('binary content');
      await f.reconciler.reconcileWithDisk('image.bin');
      f.io.files.remove('$_vaultPath/image.bin');

      final changed = await f.reconciler.reconcileWithDisk('image.bin');

      expect(changed, isTrue);
      final state = f.store.get(f.fileIdFor('image.bin'))!;
      expect(state.tombstone, isTrue);
      expect(state.blobRef, isEmpty);
    });

    test('disk-missing for unknown file -> no state created', () async {
      final f = await _newFixture();
      final changed = await f.reconciler.reconcileWithDisk('ghost.bin');
      expect(changed, isFalse);
      expect(f.store.get(f.fileIdFor('ghost.bin')), isNull);
    });
  });

  group('DiskReconciler — text reconcile', () {
    test('new text file -> Sequence cached + FileState created', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('hello world');

      final changed = await f.reconciler.reconcileWithDisk('note.md');

      expect(changed, isTrue);
      final fileId = f.fileIdFor('note.md');
      expect(f.store.get(fileId), isNotNull);
      final seq = await f.fugueStore.get(fileId);
      expect(seq, isNotNull);
      expect(seq!.values.join(), 'hello world');
    });

    test('text file no-op -> no state change', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('hello');
      await f.reconciler.reconcileWithDisk('note.md');
      final firstHlc = f.store.get(f.fileIdFor('note.md'))!.hlc;

      final changed = await f.reconciler.reconcileWithDisk('note.md');

      expect(changed, isFalse);
      expect(f.store.get(f.fileIdFor('note.md'))!.hlc, firstHlc);
    });

    test('text edit -> new Sequence merged onto old', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('hello');
      await f.reconciler.reconcileWithDisk('note.md');

      f.io.files['$_vaultPath/note.md'] = _bytes('hello world');
      final changed = await f.reconciler.reconcileWithDisk('note.md');

      expect(changed, isTrue);
      final seq = (await f.fugueStore.get(f.fileIdFor('note.md')))!;
      expect(seq.values.join(), 'hello world');
    });

    test('edit against peer-ahead content lands at the requested index',
        () async {
      // Regression for the clock-skew misplacement: a peer whose clock ran
      // ahead authored the existing content, so its dots carry LARGER
      // counters than a fresh local edit would. Combined with a tombstoned
      // gap this misroutes the insert unless the reconciler first lifts the
      // local Fugue clock above the content (store.observeDots).
      final f = await _newFixture();
      final fileId = f.fileIdFor('note.md');

      // Adversarial base authored with far-ahead counters: visible "ba",
      // where 't' is a tombstoned right-side element between 'b' and 'a'.
      final peer = LamportClock('peer', 1000000);
      final base = Fugue<String>();
      base.insert(0, 'a', peer.tick()); // "a"
      base.insert(0, 'b', peer.tick()); // "ba"
      base.insert(1, 't', peer.tick()); // "bta"
      base.delete(1); // tombstone 't' -> 'b' has a tombstoned right
      expect(base.values.join(), 'ba');

      f.fugueStore.set(fileId, base);
      await f.fugueStore.persistOne(fileId);

      // Local user inserts "XYZ" between b and a.
      f.io.files['$_vaultPath/note.md'] = _bytes('bXYZa');
      await f.reconciler.reconcileWithDisk('note.md');

      final seq = (await f.fugueStore.get(fileId))!;
      expect(seq.values.join(), 'bXYZa',
          reason: 'edit must land at the requested index despite '
              'peer-ahead content ids');
    });

    test('text file deleted -> tombstone + fugueStore.remove', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('hello');
      await f.reconciler.reconcileWithDisk('note.md');
      f.io.files.remove('$_vaultPath/note.md');

      final changed = await f.reconciler.reconcileWithDisk('note.md');

      expect(changed, isTrue);
      expect(f.store.get(f.fileIdFor('note.md'))!.tombstone, isTrue);
      expect(await f.fugueStore.get(f.fileIdFor('note.md')), isNull);
    });

    test('empty new file -> skipped, no state created, no push', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/empty.md'] = _bytes('');

      final changed = await f.reconciler.reconcileWithDisk('empty.md');
      expect(changed, isFalse);
      expect(f.store.get(f.fileIdFor('empty.md')), isNull);

      // Re-reconciling an empty file stays a no-op.
      final changed2 = await f.reconciler.reconcileWithDisk('empty.md');
      expect(changed2, isFalse);
      expect(f.store.get(f.fileIdFor('empty.md')), isNull);
    });

    test('empty file that later gains content -> syncs', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('');
      expect(await f.reconciler.reconcileWithDisk('note.md'), isFalse);
      expect(f.store.get(f.fileIdFor('note.md')), isNull);

      f.io.files['$_vaultPath/note.md'] = _bytes('hello');
      expect(await f.reconciler.reconcileWithDisk('note.md'), isTrue);
      final state = f.store.get(f.fileIdFor('note.md'));
      expect(state, isNotNull);
      expect(state!.tombstone, isFalse);
    });
  });

  group('DiskReconciler — writeFileToDisk', () {
    test('already-synced ref -> short-circuit, nothing written', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('hello');
      await f.reconciler.reconcileWithDisk('note.md');
      final fileId = f.fileIdFor('note.md');
      final state = f.store.get(fileId)!;
      f.store.recordSyncedBlobRef(fileId, state.blobRef);
      f.io.files.remove('$_vaultPath/note.md');
      f.events.clear();

      await f.reconciler.writeFileToDisk(state);

      expect(f.io.files.containsKey('$_vaultPath/note.md'), isFalse);
      expect(f.events, isEmpty);
    });

    test('bytes-identical on disk -> no write, no emit', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('hello');
      await f.reconciler.reconcileWithDisk('note.md');
      final state = f.store.get(f.fileIdFor('note.md'))!;
      f.events.clear();
      f.changes.suppressed.clear();

      await f.reconciler.writeFileToDisk(state);

      expect(f.changes.suppressed, isEmpty);
      expect(
        f.events.whereType<SyncFilePulled>(),
        isEmpty,
      );
    });

    test(
      'projects Fugue blob to plain text on disk, caches Sequence',
      () async {
        final src = await _newFixture();
        src.io.files['$_vaultPath/note.md'] = _bytes('hello world');
        await src.reconciler.reconcileWithDisk('note.md');
        final state = src.store.get(src.fileIdFor('note.md'))!;

        // Simulate a fresh device pulling the same state — empty
        // fugueStore, empty io. writeFileToDisk should download the
        // Fugue blob, decode it, cache the Sequence, and write the
        // projected text.
        final dst = await _newFixture();
        // Copy remote blobs across so the download has data to serve.
        dst.remote.store.addAll(src.remote.store);

        await dst.reconciler.writeFileToDisk(state);

        final fileId = dst.fileIdFor('note.md');
        expect(await dst.fugueStore.get(fileId), isNotNull);
        expect(
          utf8.decode(dst.io.files['$_vaultPath/note.md']!),
          'hello world',
        );
        expect(dst.changes.suppressed, contains('note.md'));
      },
    );

    test('emits SyncFilePulled when bytes actually written', () async {
      final src = await _newFixture();
      src.io.files['$_vaultPath/img.bin'] = _bytes('binary');
      await src.reconciler.reconcileWithDisk('img.bin');
      final state = src.store.get(src.fileIdFor('img.bin'))!;

      final dst = await _newFixture();
      dst.remote.store.addAll(src.remote.store);

      await dst.reconciler.writeFileToDisk(state);

      expect(dst.events.whereType<SyncFilePulled>(), hasLength(1));
      expect(dst.io.files['$_vaultPath/img.bin'], isNotNull);
    });
  });

  group('DiskReconciler — loadOrSeedSequence', () {
    test('cached Sequence wins over disk', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('hello');
      await f.reconciler.reconcileWithDisk('note.md');
      final fileId = f.fileIdFor('note.md');
      final cached = await f.fugueStore.get(fileId);

      final seq = await f.reconciler.loadOrSeedSequence(fileId, 'note.md');

      expect(identical(seq, cached), isTrue);
    });

    test('no prior state -> empty Sequence', () async {
      final f = await _newFixture();
      final seq = await f.reconciler.loadOrSeedSequence(
        f.fileIdFor('new.md'),
        'new.md',
      );
      expect(seq.elementCount, 0);
    });

    test(
      'seeds from plain-text blob deterministically '
      'when fugueStore is empty',
      () async {
        // src device writes a plain-text blob (no Fugue) and pushes.
        // We simulate this by reconciling a text file then *deleting*
        // the cached fugue entry — leaving the blob in remote storage
        // and a FileState pointing at it, but no local Sequence.
        final f = await _newFixture();
        f.io.files['$_vaultPath/note.md'] = _bytes('hello');
        await f.reconciler.reconcileWithDisk('note.md');
        final fileId = f.fileIdFor('note.md');
        await f.fugueStore.remove(fileId);

        final seq = await f.reconciler.loadOrSeedSequence(fileId, 'note.md');

        // The reconciler tried to seed by downloading the FileState's
        // blob, which is a Fugue manifest in our test. tryDecodeFugueBlob
        // should succeed -> we get the Sequence back equivalent to
        // "hello".
        expect(seq.values.join(), 'hello');
      },
    );
  });
}
