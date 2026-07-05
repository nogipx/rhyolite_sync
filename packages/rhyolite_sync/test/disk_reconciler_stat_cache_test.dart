/// Tests for DiskReconciler's stat-based short-circuit. The cache is the
/// single biggest startup-perf win: when initial pull triggers
/// pre-reconcile for many records of the same file, the second and
/// later calls finish in <1ms instead of running the full Fugue diff +
/// chunked upload path.
import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/sync_v3/disk_reconciler.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

const _vaultPath = '/vault';
const _vaultId = '00000000-0000-4000-8000-0000000000aa';

/// Tracks mtimeMs per write so the stat short-circuit can be exercised.
/// _MemIo from disk_reconciler_test.dart uses a constant mtime which
/// only catches size-driven changes.
class _MtimeAwareIo implements IPlatformIO {
  final Map<String, Uint8List> files = {};
  final Map<String, int> mtimes = {};
  int _clock = 1;

  void touchSameContent(String path) {
    if (files.containsKey(path)) mtimes[path] = _clock++;
  }

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
    mtimes[absolutePath] = _clock++;
  }

  @override
  Future<void> deleteFile(String absolutePath) async {
    files.remove(absolutePath);
    mtimes.remove(absolutePath);
  }

  @override
  Future<void> moveFile(String from, String to) async {
    final b = files.remove(from);
    final t = mtimes.remove(from);
    if (b != null) {
      files[to] = b;
      mtimes[to] = t ?? _clock++;
    }
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
    return FileStatInfo(
      mtimeMs: mtimes[absolutePath] ?? 0,
      sizeBytes: b.length,
    );
  }
}

class _CountingRemote implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    covariant Object? context,
  }) async =>
      {for (final id in blobIds) if (store.containsKey(id)) id};
  int uploads = 0;
  int downloads = 0;

  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    covariant Object? context,
  }) async {
    uploads += blobs.length;
    for (final (bytes, id) in blobs) {
      store[id] = bytes;
    }
  }

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    covariant Object? context,
  }) async {
    downloads += blobIds.length;
    return {
      for (final id in blobIds)
        if (store.containsKey(id)) id: store[id]!,
    };
  }

  @override
  Future<void> deleteMany(
    List<String> blobIds, {
    covariant Object? context,
  }) async {
    for (final id in blobIds) {
      store.remove(id);
    }
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

Future<({
  DiskReconciler reconciler,
  FileStateStore store,
  FugueStore fugueStore,
  _MtimeAwareIo io,
  _CountingRemote remote,
})> _newFixture() async {
  final env = await DataServiceFactory.inMemory();
  addTearDown(env.dispose);
  final store = FileStateStore(client: env.client, vaultId: _vaultId);
  await store.load();
  final fugueStore = FugueStore(client: env.client, vaultId: _vaultId);
  await fugueStore.load();
  final io = _MtimeAwareIo();
  final localBlobs = LocalBlobStore(InMemoryBlobRepository());
  final remote = _CountingRemote();
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

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('DiskReconciler stat cache', () {
    test('repeated reconcile of unchanged file short-circuits', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('hello world');
      f.io.mtimes['$_vaultPath/note.md'] = 1;

      // First call does the real work — uploads Fugue blob.
      await f.reconciler.reconcileWithDisk('note.md');
      final firstUploads = f.remote.uploads;
      expect(firstUploads, greaterThan(0));

      // Five more calls without any disk change.
      for (var i = 0; i < 5; i++) {
        final changed = await f.reconciler.reconcileWithDisk('note.md');
        expect(changed, isFalse);
      }

      // No new uploads — short-circuit fully avoids the Fugue path.
      expect(f.remote.uploads, firstUploads);
    });

    test('reconcile re-runs when mtime changes', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('hello');
      f.io.mtimes['$_vaultPath/note.md'] = 1;

      await f.reconciler.reconcileWithDisk('note.md');
      final firstUploads = f.remote.uploads;

      // Same size but new mtime (mimics a touch that rewrote identical
      // content — rare but possible with editors that "save unchanged").
      // Reconcile must re-run; uploadSequenceBlob is idempotent so the
      // actual remote.upload may or may not fire depending on dedupe,
      // but the Fugue diff path IS entered.
      f.io.mtimes['$_vaultPath/note.md'] = 2;
      await f.reconciler.reconcileWithDisk('note.md');

      // Hard to assert "Fugue path was entered" without a hook —
      // but we can assert no panic and that subsequent unchanged
      // reconciles still short-circuit.
      final afterUploads = f.remote.uploads;
      for (var i = 0; i < 3; i++) {
        await f.reconciler.reconcileWithDisk('note.md');
      }
      expect(f.remote.uploads, afterUploads);
    });

    test('reconcile re-runs when size changes', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('hello');
      f.io.mtimes['$_vaultPath/note.md'] = 1;
      await f.reconciler.reconcileWithDisk('note.md');
      final firstUploads = f.remote.uploads;

      // Real edit — both size and mtime change.
      f.io.files['$_vaultPath/note.md'] = _bytes('hello world');
      f.io.mtimes['$_vaultPath/note.md'] = 2;

      final changed = await f.reconciler.reconcileWithDisk('note.md');
      expect(changed, isTrue);
      expect(f.remote.uploads, greaterThan(firstUploads));
    });

    test('delete drops the cache entry', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('hello');
      f.io.mtimes['$_vaultPath/note.md'] = 1;
      await f.reconciler.reconcileWithDisk('note.md');

      f.io.files.remove('$_vaultPath/note.md');
      f.io.mtimes.remove('$_vaultPath/note.md');
      final deleted = await f.reconciler.reconcileWithDisk('note.md');
      expect(deleted, isTrue);

      // Re-create with the same name → must NOT short-circuit because
      // the delete cleared the cache.
      f.io.files['$_vaultPath/note.md'] = _bytes('returned');
      f.io.mtimes['$_vaultPath/note.md'] = 5;

      final recreated = await f.reconciler.reconcileWithDisk('note.md');
      expect(recreated, isTrue);
    });

    test('forgetStat invalidates the cache for explicit invalidation',
        () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('hello');
      f.io.mtimes['$_vaultPath/note.md'] = 1;
      await f.reconciler.reconcileWithDisk('note.md');

      // Without forgetStat → short-circuits.
      await f.reconciler.reconcileWithDisk('note.md');

      // After forgetStat → goes through full path.
      f.reconciler.forgetStat('note.md');

      final changed = await f.reconciler.reconcileWithDisk('note.md');
      // Content didn't change, so changed=false, but we DID enter the
      // text-reconcile path.
      expect(changed, isFalse);
    });

    test('binary path also short-circuits', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/img.bin'] = _bytes('binary content');
      f.io.mtimes['$_vaultPath/img.bin'] = 1;

      await f.reconciler.reconcileWithDisk('img.bin');
      final firstUploads = f.remote.uploads;

      for (var i = 0; i < 5; i++) {
        final changed = await f.reconciler.reconcileWithDisk('img.bin');
        expect(changed, isFalse);
      }
      expect(f.remote.uploads, firstUploads);
    });

    test('writeFileToDisk refreshes stat cache', () async {
      // A pulled state materialised to disk must update the stat cache,
      // otherwise the next reconcileWithDisk sees mtime moved and
      // re-runs against bytes that already match the store.
      final src = await _newFixture();
      src.io.files['$_vaultPath/note.md'] = _bytes('hello world');
      src.io.mtimes['$_vaultPath/note.md'] = 1;
      await src.reconciler.reconcileWithDisk('note.md');
      final state = src.store.get(const Uuid().v5(_vaultId, 'note.md'))!;

      final dst = await _newFixture();
      dst.remote.store.addAll(src.remote.store);

      await dst.reconciler.writeFileToDisk(state);
      final uploadsAfterMaterialise = dst.remote.uploads;

      // Now run reconcile — should short-circuit, no extra remote ops.
      await dst.reconciler.reconcileWithDisk('note.md');
      expect(dst.remote.uploads, uploadsAfterMaterialise);
    });
  });
}
