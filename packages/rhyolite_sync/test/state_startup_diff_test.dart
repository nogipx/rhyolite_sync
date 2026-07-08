/// Tests for the StartupDiff fast-path short-circuits. The previous
/// logic only skipped single-chunk files with sha-match, missing two
/// common cases:
///   * Empty files (chunks list is empty in the stored state) → always
///     pending → useless re-upload of a 0-byte blob every startup.
///   * Multi-chunk files (large binaries) → never a single-chunk match
///     → pending → useless re-upload of multi-megabyte blob every
///     startup.
import 'dart:typed_data';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/sync_v3/state_startup_diff.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

const _vaultPath = '/vault';
const _vaultId = '00000000-0000-4000-8000-0000000000bb';

class _MemRemote implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    covariant Object? context,
  }) async =>
      {for (final id in blobIds) if (store.containsKey(id)) id};
  int uploads = 0;

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
  }) async =>
      {
        for (final id in blobIds)
          if (store.containsKey(id)) id: store[id]!,
      };

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
    if (b == null) throw StateError('no file $absolutePath');
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
  Future<void> moveFile(String from, String to) async {}
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

Future<({
  StateStartupDiff diff,
  FileStateStore store,
  _MemIo io,
  _MemRemote remote,
  String Function(String) fileIdFor,
})> _newFixture({Uint8List? blobIdKey}) async {
  final env = await DataServiceFactory.inMemory();
  addTearDown(env.dispose);
  final store = FileStateStore(client: env.client, vaultId: _vaultId);
  await store.load();
  final io = _MemIo();
  final remote = _MemRemote();
  final blobStore = LocalBlobStore(InMemoryBlobRepository());
  String fileIdFor(String p) => const Uuid().v5(_vaultId, p);
  Hlc clock() {
    final next = store.nextHlc();
    return next;
  }
  final diff = StateStartupDiff(
    store: store,
    blobStore: blobStore,
    remoteBlobStorage: remote,
    io: io,
    vaultPath: _vaultPath,
    vaultId: _vaultId,
    nodeId: 'test-device',
    readClock: clock,
    writeClock: (_) {},
    blobIdKey: blobIdKey,
  );
  return (
    diff: diff,
    store: store,
    io: io,
    remote: remote,
    fileIdFor: fileIdFor,
  );
}

Uint8List _randomBytes(int length, int seed) {
  // Pseudorandom-looking but deterministic. Matters for the
  // multi-chunk test because ContentDefinedChunker boundaries depend
  // on byte values, so the seed picks a layout that splits into
  // multiple chunks for sizes above ~512 KB (minChunkSize default).
  final out = Uint8List(length);
  var s = seed;
  for (var i = 0; i < length; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    out[i] = s & 0xff;
  }
  return out;
}

void main() {
  group('StateStartupDiff fast-path skips', () {
    test('empty file with empty state → skipped, no upload', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/empty.md'] = Uint8List(0);
      f.store.upsert(FileState(
        fileId: f.fileIdFor('empty.md'),
        path: 'empty.md',
        blobRef: 'whatever',
        sizeBytes: 0,
        hlc: f.store.nextHlc(),
        chunks: const <String>[],
      ));

      final remoteBefore = f.remote.uploads;
      final result = await f.diff.call();
      expect(f.remote.uploads, remoteBefore,
          reason: 'empty file with sizeBytes=0 must NOT trigger upload');
      expect(result.modifiedFiles, 0);
    });

    test('large multi-chunk binary unchanged → skipped, no upload',
        () async {
      // Use the default ContentDefinedChunker (512KB min, 1MB avg, 4MB
      // max). A 3MB buffer with varied content typically splits into
      // 2-4 chunks.
      final f = await _newFixture();
      final big = _randomBytes(10 * 1024 * 1024, 42);
      f.io.files['$_vaultPath/file.bin'] = big;

      // Build the state the way reconciler would: actually chunk and
      // record the resulting hashes.
      final chunked = await ContentDefinedChunker()(big);
      final chunkHashes = chunked.manifest.chunks
          .map((c) => c.hash)
          .toList(growable: false);
      // Sanity: the seed above gives multi-chunk; without it this test
      // would not exercise the (c) branch.
      expect(chunkHashes.length, greaterThan(1));

      f.store.upsert(FileState(
        fileId: f.fileIdFor('file.bin'),
        path: 'file.bin',
        blobRef: 'manifest-hash',
        sizeBytes: big.length,
        hlc: f.store.nextHlc(),
        chunks: chunkHashes,
      ));

      final remoteBefore = f.remote.uploads;
      final result = await f.diff.call();
      expect(f.remote.uploads, remoteBefore,
          reason: 'multi-chunk file with identical chunks must NOT '
              'trigger upload');
      expect(result.modifiedFiles, 0);
    });

    test('keyed blob ids: unchanged file skipped when the diff hashes with '
        'the same key (regression: keyed → re-upload storm)', () async {
      // The blobs were stored under keyed HMAC ids. StartupDiff MUST hash
      // disk content with the same keyed scheme, otherwise the stored hash
      // never matches the recomputed one and the file re-uploads every start.
      final key = Uint8List.fromList(List.generate(32, (i) => (i * 7) & 0xff));
      final hasher = ChunkedBlobIO.hasherFor(key);
      final f = await _newFixture(blobIdKey: key);

      final bytes = _randomBytes(10 * 1024 * 1024, 42); // multi-chunk
      f.io.files['$_vaultPath/file.bin'] = bytes;

      // Store chunk hashes computed with the SAME keyed hasher (as a real
      // keyed upload would have produced).
      final chunked = await ContentDefinedChunker(blobIdHasher: hasher)(bytes);
      final chunkHashes =
          chunked.manifest.chunks.map((c) => c.hash).toList(growable: false);
      expect(chunkHashes.length, greaterThan(1));
      // These are HMAC ids, not the plain sha256 the old code would compute.
      final plain = await ContentDefinedChunker()(bytes);
      expect(chunkHashes.first,
          isNot(plain.manifest.chunks.first.hash));

      f.store.upsert(FileState(
        fileId: f.fileIdFor('file.bin'),
        path: 'file.bin',
        blobRef: 'manifest-hash',
        sizeBytes: bytes.length,
        hlc: f.store.nextHlc(),
        chunks: chunkHashes,
      ));

      final remoteBefore = f.remote.uploads;
      final result = await f.diff.call();
      expect(f.remote.uploads, remoteBefore,
          reason: 'keyed hashes match → unchanged file must NOT re-upload');
      expect(result.modifiedFiles, 0);
    });

    test('single-chunk file unchanged → skipped (existing behavior)',
        () async {
      final f = await _newFixture();
      final bytes = Uint8List.fromList(List.generate(100, (i) => i));
      f.io.files['$_vaultPath/file.bin'] = bytes;

      // Single-chunk hash: ContentDefinedChunker on 100 bytes (< min
      // chunk size) yields one chunk = whole file.
      final chunked = await ContentDefinedChunker()(bytes);
      expect(chunked.manifest.chunks.length, 1);
      f.store.upsert(FileState(
        fileId: f.fileIdFor('file.bin'),
        path: 'file.bin',
        blobRef: 'manifest-hash',
        sizeBytes: bytes.length,
        hlc: f.store.nextHlc(),
        chunks: [chunked.manifest.chunks.first.hash],
      ));

      final remoteBefore = f.remote.uploads;
      final result = await f.diff.call();
      expect(f.remote.uploads, remoteBefore);
      expect(result.modifiedFiles, 0);
    });

    test('multi-chunk file modified → goes through upload', () async {
      final f = await _newFixture();
      final big = _randomBytes(10 * 1024 * 1024, 7);
      f.io.files['$_vaultPath/file.bin'] = big;

      // State was for a different content with different chunks.
      f.store.upsert(FileState(
        fileId: f.fileIdFor('file.bin'),
        path: 'file.bin',
        blobRef: 'old-manifest',
        sizeBytes: big.length,
        hlc: f.store.nextHlc(),
        chunks: const ['stale-hash-1', 'stale-hash-2', 'stale-hash-3'],
      ));

      final result = await f.diff.call();
      expect(result.modifiedFiles, 1);
      expect(f.remote.uploads, greaterThan(0));
    });

    test('multi-chunk file size changed → goes through upload', () async {
      final f = await _newFixture();
      final big = _randomBytes(10 * 1024 * 1024, 5);
      f.io.files['$_vaultPath/file.bin'] = big;

      final chunked = await ContentDefinedChunker()(big);
      final chunkHashes = chunked.manifest.chunks
          .map((c) => c.hash)
          .toList(growable: false);

      // State has correct chunks but wrong sizeBytes (file grew on
      // disk between sessions).
      f.store.upsert(FileState(
        fileId: f.fileIdFor('file.bin'),
        path: 'file.bin',
        blobRef: 'old-manifest',
        sizeBytes: big.length - 100, // intentionally off
        hlc: f.store.nextHlc(),
        chunks: chunkHashes,
      ));

      final result = await f.diff.call();
      expect(result.modifiedFiles, 1,
          reason: 'size mismatch must force re-upload even when chunk '
              'hashes happen to match');
    });

    test('non-empty file with empty stored chunks → goes through upload',
        () async {
      // The mirror case to (a): disk has content but state's chunks
      // list is empty (e.g. from a partial earlier upload). Must NOT
      // short-circuit — the file genuinely needs to be uploaded.
      final f = await _newFixture();
      f.io.files['$_vaultPath/file.md'] = Uint8List.fromList([1, 2, 3]);
      f.store.upsert(FileState(
        fileId: f.fileIdFor('file.md'),
        path: 'file.md',
        blobRef: 'whatever',
        sizeBytes: 0, // stored as empty
        hlc: f.store.nextHlc(),
        chunks: const <String>[],
      ));

      final result = await f.diff.call();
      expect(result.modifiedFiles, 1,
          reason: 'state.sizeBytes=0 but disk has bytes → must upload');
    });
  });

  group('StateStartupDiff text delegation', () {
    test('text file routed to reconcileText, not raw-uploaded', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = FileStateStore(client: env.client, vaultId: _vaultId);
      await store.load();
      final io = _MemIo();
      final remote = _MemRemote();
      final blobStore = LocalBlobStore(InMemoryBlobRepository());
      io.files['$_vaultPath/note.md'] = Uint8List.fromList([104, 105]);
      io.files['$_vaultPath/pic.bin'] = _randomBytes(2048, 7);

      final delegated = <String>[];
      final diff = StateStartupDiff(
        store: store,
        blobStore: blobStore,
        remoteBlobStorage: remote,
        io: io,
        vaultPath: _vaultPath,
        vaultId: _vaultId,
        nodeId: 'd',
        readClock: store.nextHlc,
        writeClock: (_) {},
        reconcileText: (relPath) async {
          delegated.add(relPath);
          return false; // unchanged → no bump
        },
      );

      await diff.call();

      // Text went to the delegate; binary still went through the raw upload.
      expect(delegated, ['note.md']);
      expect(remote.uploads, greaterThan(0),
          reason: 'binary still uploaded raw');
      // The text file produced no FileState (delegate returned no change and
      // it writes its own state) and no raw blob for it was uploaded.
      expect(store.get(const Uuid().v5(_vaultId, 'note.md')), isNull);
    });

    test('unchanged text file skipped via persisted signature '
        '(not reconciled, not counted)', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = FileStateStore(client: env.client, vaultId: _vaultId);
      await store.load();
      final sigStore = StatSigStore(client: env.client, vaultId: _vaultId);
      await sigStore.load();
      final io = _MemIo();
      final blobStore = LocalBlobStore(InMemoryBlobRepository());

      final unchanged = Uint8List.fromList([104, 105, 106]);
      final changed = Uint8List.fromList([120, 121]);
      io.files['$_vaultPath/unchanged.md'] = unchanged;
      io.files['$_vaultPath/changed.md'] = changed;

      // Both have a live FileState.
      for (final entry in {'unchanged.md': unchanged, 'changed.md': changed}
          .entries) {
        store.upsert(FileState(
          fileId: const Uuid().v5(_vaultId, entry.key),
          path: entry.key,
          blobRef: 'ref',
          sizeBytes: entry.value.length,
          hlc: store.nextHlc(),
          chunks: const ['c'],
        ));
      }

      // _MemIo.statFile → (mtimeMs: 0, sizeBytes: content length).
      // Matching signature for the unchanged file; a size-mismatched one for
      // the changed file so it must still be delegated.
      sigStore.set(const Uuid().v5(_vaultId, 'unchanged.md'), 0, unchanged.length);
      sigStore.set(const Uuid().v5(_vaultId, 'changed.md'), 0, changed.length + 99);

      final delegated = <String>[];
      int? lastTotal;
      final diff = StateStartupDiff(
        store: store,
        blobStore: blobStore,
        remoteBlobStorage: _MemRemote(),
        io: io,
        vaultPath: _vaultPath,
        vaultId: _vaultId,
        nodeId: 'd',
        readClock: store.nextHlc,
        writeClock: (_) {},
        sigStore: sigStore,
        reconcileText: (relPath) async {
          delegated.add(relPath);
          return false;
        },
        onUploadProgress: (completed, total) => lastTotal = total,
      );

      await diff.call();

      expect(delegated, ['changed.md'],
          reason: 'matching sig → skipped before reconcile; '
              'mismatched sig → delegated');
      expect(lastTotal, 1,
          reason: 'only the changed file counts toward startup progress');
    });
  });
}
