import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';
import 'package:rhyolite_core/rhyolite_core.dart';

const _vaultPath = '/vault';
const _vaultId = '00000000-0000-4000-8000-0000000000bb';

class _MemRemote implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    covariant Object? context,
  }) async => {
    for (final id in blobIds)
      if (store.containsKey(id)) id,
  };
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
  }) async => {
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

Future<
  ({
    StateStartupDiff diff,
    FileStateStore store,
    _MemIo io,
    _MemRemote remote,
    String Function(String) fileIdFor,
  })
>
_newFixture({
  Uint8List? blobIdKey,
  Set<String>? excludedExtensions,
  PathScope? pathScope,
  bool Function()? isCancelled,
}) async {
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
    excludedExtensions: excludedExtensions == null
        ? null
        : () => excludedExtensions,
    pathScope: pathScope == null ? null : () => pathScope,
    isCancelled: isCancelled,
  );
  return (
    diff: diff,
    store: store,
    io: io,
    remote: remote,
    fileIdFor: fileIdFor,
  );
}

/// Reports cancelled once it has been asked [after] times.
class _CancelAfter {
  _CancelAfter(this.after);
  final int after;
  int calls = 0;
  bool get done => ++calls > after;
}

var _cancelAfter = _CancelAfter(1 << 30);

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

/// Fails exactly the calls whose index is in [failCalls]; everything else
/// uploads. Lets a test put a transient in the middle of a run.
class _FailsSpecificCallsRemote extends _MemRemote {
  _FailsSpecificCallsRemote({required this.failCalls});

  final Set<int> failCalls;
  int calls = 0;

  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    covariant Object? context,
  }) async {
    final n = calls++;
    if (failCalls.contains(n)) throw StateError('transient $n');
    return super.upload(blobs, context: context);
  }
}

/// Always refuses with the hub's terminal error — the session that owned the
/// transfers is gone.
class _DisposedHubRemote extends _MemRemote {
  int calls = 0;

  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    covariant Object? context,
  }) async {
    calls++;
    throw const BlobTransferHubDisposed();
  }
}

/// Always answers 401. Models a BYO backend with the wrong password: not a
/// failure that will pass, a backend that has declined this device.
class _RefusingRemote extends _MemRemote {
  int calls = 0;

  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    covariant Object? context,
  }) async {
    calls++;
    throw const BlobStorageRefused(401, 'Unauthorized');
  }
}

/// Captures what the diff logged, so a test can assert on its VOLUME — the
/// thing that made one report unreadable and evicted two other faults from it.
class _CollectingOutput extends LogOutput {
  final List<String> lines = [];

  @override
  void write(LogRecord record) {
    if (record is LogEvent) lines.add(record.message);
  }
}

/// Counts how many times a file's bytes were read, which is what the scan's
/// cost is made of.
class _CountingIo extends _MemIo {
  int reads = 0;

  @override
  Future<Uint8List> readFile(String absolutePath) {
    reads++;
    return super.readFile(absolutePath);
  }
}

/// Uploads normally until [failAfter] blobs have gone through, then refuses
/// every later call — standing in for the server's sustained rate limit, which
/// does not relent while the client keeps pushing.
class _FailsPartWayRemote extends _MemRemote {
  _FailsPartWayRemote({required this.failAfter});

  final int failAfter;

  /// How many upload CALLS were attempted, refused ones included — the
  /// success counter cannot show that a pass gave up early.
  int calls = 0;

  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    covariant Object? context,
  }) async {
    calls++;
    if (uploads >= failAfter) throw StateError('rate limit exceeded');
    return super.upload(blobs, context: context);
  }
}

void main() {
  group('a cancelled pass stops and claims nothing', () {
    test('the scan ends early and reports no missing files', () async {
      // StateStartupDiff had no cancellation at all: the engine checked
      // _running before calling in and never again, so a pass could outlive
      // the session that started it. What it reports matters as much as when
      // it stops — missingFileIds drives tombstone creation, so a pass that
      // walked half the vault must not answer "the rest is missing".
      final f = await _newFixture(isCancelled: () => _cancelAfter.done);
      _cancelAfter = _CancelAfter(20);

      for (var i = 0; i < 200; i++) {
        f.io.files['$_vaultPath/note$i.md'] = _randomBytes(64, i);
      }

      final result = await f.diff();

      expect(
        _cancelAfter.calls,
        lessThan(200),
        reason: 'the scan must stop asking once the run is gone',
      );
      expect(
        result.missingFileIds,
        isEmpty,
        reason:
            'a partial walk has no opinion about what is missing; answering '
            'from it would tombstone every file the scan had not reached',
      );
      expect(result.newFiles, 0);
    });
  });

  group('StateStartupDiff fast-path skips', () {
    test('empty file with empty state → skipped, no upload', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/empty.md'] = Uint8List(0);
      f.store.upsert(
        FileState(
          fileId: f.fileIdFor('empty.md'),
          path: 'empty.md',
          blobRef: 'whatever',
          sizeBytes: 0,
          hlc: f.store.nextHlc(),
          chunks: const <String>[],
        ),
      );

      final remoteBefore = f.remote.uploads;
      final result = await f.diff.call();
      expect(
        f.remote.uploads,
        remoteBefore,
        reason: 'empty file with sizeBytes=0 must NOT trigger upload',
      );
      expect(result.modifiedFiles, 0);
    });

    test('large multi-chunk binary unchanged → skipped, no upload', () async {
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

      f.store.upsert(
        FileState(
          fileId: f.fileIdFor('file.bin'),
          path: 'file.bin',
          blobRef: 'manifest-hash',
          sizeBytes: big.length,
          hlc: f.store.nextHlc(),
          chunks: chunkHashes,
        ),
      );

      final remoteBefore = f.remote.uploads;
      final result = await f.diff.call();
      expect(
        f.remote.uploads,
        remoteBefore,
        reason:
            'multi-chunk file with identical chunks must NOT '
            'trigger upload',
      );
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
      final chunkHashes = chunked.manifest.chunks
          .map((c) => c.hash)
          .toList(growable: false);
      expect(chunkHashes.length, greaterThan(1));
      // These are HMAC ids, not the plain sha256 the old code would compute.
      final plain = await ContentDefinedChunker()(bytes);
      expect(chunkHashes.first, isNot(plain.manifest.chunks.first.hash));

      f.store.upsert(
        FileState(
          fileId: f.fileIdFor('file.bin'),
          path: 'file.bin',
          blobRef: 'manifest-hash',
          sizeBytes: bytes.length,
          hlc: f.store.nextHlc(),
          chunks: chunkHashes,
        ),
      );

      final remoteBefore = f.remote.uploads;
      final result = await f.diff.call();
      expect(
        f.remote.uploads,
        remoteBefore,
        reason: 'keyed hashes match → unchanged file must NOT re-upload',
      );
      expect(result.modifiedFiles, 0);
    });

    test('single-chunk file unchanged → skipped (existing behavior)', () async {
      final f = await _newFixture();
      final bytes = Uint8List.fromList(List.generate(100, (i) => i));
      f.io.files['$_vaultPath/file.bin'] = bytes;

      // Single-chunk hash: ContentDefinedChunker on 100 bytes (< min
      // chunk size) yields one chunk = whole file.
      final chunked = await ContentDefinedChunker()(bytes);
      expect(chunked.manifest.chunks.length, 1);
      f.store.upsert(
        FileState(
          fileId: f.fileIdFor('file.bin'),
          path: 'file.bin',
          blobRef: 'manifest-hash',
          sizeBytes: bytes.length,
          hlc: f.store.nextHlc(),
          chunks: [chunked.manifest.chunks.first.hash],
        ),
      );

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
      f.store.upsert(
        FileState(
          fileId: f.fileIdFor('file.bin'),
          path: 'file.bin',
          blobRef: 'old-manifest',
          sizeBytes: big.length,
          hlc: f.store.nextHlc(),
          chunks: const ['stale-hash-1', 'stale-hash-2', 'stale-hash-3'],
        ),
      );

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
      f.store.upsert(
        FileState(
          fileId: f.fileIdFor('file.bin'),
          path: 'file.bin',
          blobRef: 'old-manifest',
          sizeBytes: big.length - 100, // intentionally off
          hlc: f.store.nextHlc(),
          chunks: chunkHashes,
        ),
      );

      final result = await f.diff.call();
      expect(
        result.modifiedFiles,
        1,
        reason:
            'size mismatch must force re-upload even when chunk '
            'hashes happen to match',
      );
    });

    test(
      'non-empty file with empty stored chunks → goes through upload',
      () async {
        // The mirror case to (a): disk has content but state's chunks
        // list is empty (e.g. from a partial earlier upload). Must NOT
        // short-circuit — the file genuinely needs to be uploaded.
        final f = await _newFixture();
        f.io.files['$_vaultPath/file.md'] = Uint8List.fromList([1, 2, 3]);
        f.store.upsert(
          FileState(
            fileId: f.fileIdFor('file.md'),
            path: 'file.md',
            blobRef: 'whatever',
            sizeBytes: 0, // stored as empty
            hlc: f.store.nextHlc(),
            chunks: const <String>[],
          ),
        );

        final result = await f.diff.call();
        expect(
          result.modifiedFiles,
          1,
          reason: 'state.sizeBytes=0 but disk has bytes → must upload',
        );
      },
    );

    test('denylisted extension → not uploaded, reported as excluded; '
        'other files still upload', () async {
      final f = await _newFixture(excludedExtensions: {'pdf'});
      // A brand-new pdf (denylisted) and a brand-new binary file (not),
      // neither in the store yet. Binary so it takes the raw upload path
      // that bumps modifiedFiles (text would be delegated to reconcileText).
      f.io.files['$_vaultPath/doc.pdf'] = _randomBytes(2048, 3);
      f.io.files['$_vaultPath/pic.bin'] = _randomBytes(2048, 9);

      final result = await f.diff.call();

      expect(
        result.excluded.map((e) => e.path),
        ['doc.pdf'],
        reason: 'the pdf must be reported excluded, not uploaded',
      );
      expect(result.excluded.single.extension, 'pdf');
      // The pdf must not have produced any stored state.
      expect(
        f.store.get(f.fileIdFor('doc.pdf')),
        isNull,
        reason: 'excluded file must not be admitted into the store',
      );
      // The binary is not denylisted → normal upload path (new file).
      expect(
        result.newFiles,
        1,
        reason: 'the non-excluded binary must still sync',
      );
      expect(
        f.store.get(f.fileIdFor('pic.bin')),
        isNotNull,
        reason: 'the non-excluded binary must be admitted into the store',
      );
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
      expect(
        remote.uploads,
        greaterThan(0),
        reason: 'binary still uploaded raw',
      );
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
      for (final entry in {
        'unchanged.md': unchanged,
        'changed.md': changed,
      }.entries) {
        store.upsert(
          FileState(
            fileId: const Uuid().v5(_vaultId, entry.key),
            path: entry.key,
            blobRef: 'ref',
            sizeBytes: entry.value.length,
            hlc: store.nextHlc(),
            chunks: const ['c'],
          ),
        );
      }

      // _MemIo.statFile → (mtimeMs: 0, sizeBytes: content length).
      // Matching signature for the unchanged file; a size-mismatched one for
      // the changed file so it must still be delegated.
      sigStore.set(
        const Uuid().v5(_vaultId, 'unchanged.md'),
        0,
        unchanged.length,
      );
      sigStore.set(
        const Uuid().v5(_vaultId, 'changed.md'),
        0,
        changed.length + 99,
      );

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

      expect(
        delegated,
        ['changed.md'],
        reason:
            'matching sig → skipped before reconcile; '
            'mismatched sig → delegated',
      );
      expect(
        lastTotal,
        1,
        reason: 'only the changed file counts toward startup progress',
      );
    });
  });

  group('StateStartupDiff path admission', () {
    test('only in-scope files are uploaded, the rest are reported', () async {
      final f = await _newFixture(pathScope: PathScope(include: ['Work']));
      f.io.files['$_vaultPath/Work/plan.md'] = _randomBytes(1024, 1);
      f.io.files['$_vaultPath/Personal/diary.md'] = _randomBytes(1024, 2);
      f.io.files['$_vaultPath/loose.md'] = _randomBytes(1024, 3);

      final result = await f.diff.call();

      expect(result.newFiles, 1, reason: 'only Work/plan.md is in scope');
      expect(f.remote.uploads, greaterThan(0));
      expect(f.store.get(f.fileIdFor('Personal/diary.md')), isNull);
      expect(f.store.get(f.fileIdFor('loose.md')), isNull);
      expect(result.outOfScope..sort(), ['Personal/diary.md', 'loose.md']);
    });

    test(
      'an out-of-scope file that IS on disk is not reported missing',
      () async {
        // Otherwise the engine would read it as a delete candidate — the exact
        // confusion that would turn a narrowed scope into a mass delete.
        final f = await _newFixture(pathScope: PathScope(include: ['Work']));
        f.io.files['$_vaultPath/Personal/diary.md'] = _randomBytes(1024, 2);
        f.store.upsert(
          FileState(
            fileId: f.fileIdFor('Personal/diary.md'),
            path: 'Personal/diary.md',
            blobRef: 'manifest',
            sizeBytes: 1024,
            hlc: f.store.nextHlc(),
            chunks: const <String>['c1'],
          ),
        );

        final result = await f.diff.call();

        expect(result.missingFileIds, isEmpty);
        expect(result.outOfScope, ['Personal/diary.md']);
      },
    );
  });

  // -------------------------------------------------------------------------
  // Progress must survive a failure part-way through.
  //
  // What a real vault ran into: 9119 files, the server's blob rate limit
  // tripped mid-upload, the whole startup died — and because the diff only
  // ever wrote to memory, the next run began again from `0 tracked`. It never
  // finished, so it never persisted, so it never started anywhere but the top.
  // -------------------------------------------------------------------------
  group('a failed run keeps what it already uploaded', () {
    Future<({StateStartupDiff diff, FileStateStore store, IDataClient client})>
    fixtureWith(_MemRemote remote, int fileCount) async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = FileStateStore(client: env.client, vaultId: _vaultId);
      await store.load();
      final io = _MemIo();
      for (var i = 0; i < fileCount; i++) {
        io.files['$_vaultPath/f$i.bin'] = _randomBytes(512, i + 1);
      }
      return (
        diff: StateStartupDiff(
          store: store,
          blobStore: LocalBlobStore(InMemoryBlobRepository()),
          remoteBlobStorage: remote,
          io: io,
          vaultPath: _vaultPath,
          vaultId: _vaultId,
          nodeId: 'test-device',
          readClock: store.nextHlc,
          writeClock: (_) {},
          // One worker, so "uploaded before the failure" is a prefix rather
          // than whichever groups four workers happened to be holding.
          uploadConcurrency: 1,
        ),
        store: store,
        client: env.client,
      );
    }

    test('the rows reach the database, not just memory', () async {
      // 64 files = eight groups of eight. A group uploads 16 blobs (one
      // chunk and one manifest per file), so 32 lets two groups through and
      // the remaining six fail — enough for the five-in-a-row guard to end
      // the pass rather than carry on to the end.
      final f = await fixtureWith(_FailsPartWayRemote(failAfter: 32), 64);
      await expectLater(f.diff.call(), throwsA(isA<StateError>()));

      // A FRESH store on the same database — this is the restart. Reading
      // f.store would prove nothing: that one holds the in-memory copy, which
      // was never the thing in doubt.
      final reopened = FileStateStore(client: f.client, vaultId: _vaultId);
      await reopened.load();

      expect(
        reopened.fileIds.length,
        16,
        reason: 'the two groups that finished must survive the rest failing',
      );
      for (final id in reopened.fileIds) {
        final state = reopened.get(id);
        expect(state, isNotNull);
        expect(state!.blobRef, isNotEmpty);
        expect(
          state.chunks,
          isNotEmpty,
          reason: 'without chunks the next scan cannot skip the file',
        );
      }
    });

    test('the causal context survives with them', () async {
      // `load` rebuilds the hlc by scanning the rows, so the clock recovers on
      // its own — but `_ownContext` comes from the meta row and nowhere else,
      // and `upsert` advances it per file. Persisting rows without it leaves a
      // restart claiming to have seen less than it has already written.
      final f = await fixtureWith(_FailsPartWayRemote(failAfter: 32), 64);
      await expectLater(f.diff.call(), throwsA(isA<StateError>()));

      final reopened = FileStateStore(client: f.client, vaultId: _vaultId);
      await reopened.load();

      expect(
        reopened.ownContext.pack(),
        isNot(const CausalContext.empty().pack()),
        reason: 'the context of the sixteen banked writes must come back',
      );
    });

    test('one bad group is skipped, the rest still land', () async {
      // A single group failing is a transient — a rate-limited batch, a lost
      // chunk upload. Ending the whole pass over it throws away every other
      // group's work, which is what a failed first sync could not afford.
      // Call 0 is the first group's chunk upload; the group is lost, the two
      // that follow are not.
      final remote = _FailsSpecificCallsRemote(failCalls: {0});
      final f = await fixtureWith(remote, 24);
      final result = await f.diff.call();

      expect(result.skippedGroups, 1);
      expect(
        result.newFiles,
        16,
        reason: 'the two healthy groups must still be recorded',
      );

      final reopened = FileStateStore(client: f.client, vaultId: _vaultId);
      await reopened.load();
      expect(reopened.fileIds.length, 16);
    });

    test('a run of failures ends the pass instead of grinding', () async {
      // Systemic, not transient: a refused token or a server that is down
      // fails every group identically. Carrying on would work through
      // thousands of them to reach the same answer, freezing the host — the
      // per-record grind this codebase has met before.
      final remote = _FailsPartWayRemote(failAfter: 0);
      final f = await fixtureWith(remote, 64);

      await expectLater(f.diff.call(), throwsA(isA<StateError>()));
      expect(remote.uploads, 0);
      // Eight groups, and the guard stops at five in a row — so the pass ends
      // early rather than working through every one of them to reach the same
      // answer. That grind is what freezes the host.
      // Exactly the threshold: eight groups are available and it attempts
      // five before giving up. Pinned as an equality rather than an upper
      // bound, because "fewer than eight" is also satisfied by aborting on the
      // very first failure — which is the behaviour this guard replaced.
      expect(
        remote.calls,
        5,
        reason:
            'five in a row ends the pass; it neither grinds through all '
            'eight nor bails on the first',
      );
    });

    test('a disposed hub stops the pass at once, not after five', () async {
      // It does not mean "this group failed" — it means the session that owned
      // the transfers is gone, so every later group fails identically.
      // Carrying on does work for a session that no longer exists; a real pass
      // burned 26 groups discovering that one at a time.
      final remote = _DisposedHubRemote();
      final f = await fixtureWith(remote, 64);

      await expectLater(f.diff.call(), throwsA(isA<BlobTransferHubDisposed>()));
      expect(
        remote.calls,
        1,
        reason: 'the first refusal ends it — no five-in-a-row budget',
      );
    });

    test(
      'a refused storage stops the pass and is reported, not thrown',
      () async {
        // The shape that made this necessary: a vault on BYO WebDAV with a
        // mistyped password. Every upload came back 401, the group handler
        // logged "group 0 failed, continuing", the pass finished, the engine
        // started, and the UI showed a healthy sync that had uploaded nothing.
        //
        // So the refusal has to end the pass — retrying it 9000 times reaches
        // the same answer — and it has to leave the pass as a VALUE. Thrown, it
        // would take the start down with it and there would be no live engine
        // left to accept the corrected password.
        final remote = _RefusingRemote();
        final f = await fixtureWith(remote, 64);

        final result = await f.diff.call();
        expect(result.storageRefused, isNotNull);
        expect(result.storageRefused, contains('401'));
        expect(
          remote.calls,
          1,
          reason: 'the first refusal ends it — no five-in-a-row budget',
        );
      },
    );

    test('a tracked binary is skipped on its stat, not re-read', () async {
      // Every tracked binary used to be read in full on every scan — and a
      // multi-chunk one re-chunked on top — purely to conclude it had not
      // changed. That cost is paid BY TRACKED FILES, so the scan got slower
      // the more of the vault was synced: one report shows 24s climbing to
      // 46s as the tracked count went from 392 to 6560, on a scan that runs
      // at every single start.
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = FileStateStore(client: env.client, vaultId: _vaultId);
      await store.load();
      final sigs = StatSigStore(client: env.client, vaultId: _vaultId);
      await sigs.load();
      final io = _CountingIo();
      for (var i = 0; i < 5; i++) {
        io.files['$_vaultPath/f$i.bin'] = _randomBytes(4096, i + 1);
      }
      final remote = _MemRemote();

      StateStartupDiff diff() => StateStartupDiff(
        store: store,
        blobStore: LocalBlobStore(InMemoryBlobRepository()),
        remoteBlobStorage: remote,
        io: io,
        vaultPath: _vaultPath,
        vaultId: _vaultId,
        nodeId: 'test-device',
        readClock: store.nextHlc,
        writeClock: (_) {},
        sigStore: sigs,
      );

      await diff().call();
      final readsWhileUploading = io.reads;
      expect(
        readsWhileUploading,
        greaterThanOrEqualTo(5),
        reason: 'the first pass has to read them to upload them',
      );

      io.reads = 0;
      await diff().call();

      expect(
        io.reads,
        0,
        reason: 'a second pass over unchanged binaries must not read one',
      );
    });

    test('and is read again once it actually changes', () async {
      // The skip trusts mtime+size, which is the same trust the reconciler and
      // the text path already run on. It must still notice a real edit.
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = FileStateStore(client: env.client, vaultId: _vaultId);
      await store.load();
      final sigs = StatSigStore(client: env.client, vaultId: _vaultId);
      await sigs.load();
      final io = _CountingIo();
      io.files['$_vaultPath/a.bin'] = _randomBytes(4096, 1);
      final remote = _MemRemote();

      StateStartupDiff diff() => StateStartupDiff(
        store: store,
        blobStore: LocalBlobStore(InMemoryBlobRepository()),
        remoteBlobStorage: remote,
        io: io,
        vaultPath: _vaultPath,
        vaultId: _vaultId,
        nodeId: 'test-device',
        readClock: store.nextHlc,
        writeClock: (_) {},
        sigStore: sigs,
      );

      await diff().call();
      io.files['$_vaultPath/a.bin'] = _randomBytes(8192, 2);
      io.reads = 0;

      final result = await diff().call();

      expect(io.reads, greaterThan(0), reason: 'a changed file must be read');
      expect(result.modifiedFiles, 1);
    });

    test(
      'the scan samples its per-file lines instead of one per file',
      () async {
        // One report's log was 40322 of these lines out of 40988 — 98% of
        // everything the device had recorded, because on a first sync every
        // file is new. It pushed whole sessions out of the rotation, and two
        // other faults in that same report could not be diagnosed at all
        // because the segment holding them had been evicted by this line.
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);
        final store = FileStateStore(client: env.client, vaultId: _vaultId);
        await store.load();
        final io = _MemIo();
        for (var i = 0; i < 200; i++) {
          io.files['$_vaultPath/f$i.bin'] = _randomBytes(64, i + 1);
        }

        final captured = _CollectingOutput();
        final lines = captured.lines;
        await StateStartupDiff(
          store: store,
          blobStore: LocalBlobStore(InMemoryBlobRepository()),
          remoteBlobStorage: _MemRemote(),
          io: io,
          vaultPath: _vaultPath,
          vaultId: _vaultId,
          nodeId: 'test-device',
          readClock: store.nextHlc,
          writeClock: (_) {},
          logger: LogController(outputs: [captured]).scope('scan'),
        ).call();

        final perFile = lines
            .where((l) => l.contains('StartupDiff: pending'))
            .length;
        expect(
          perFile,
          lessThanOrEqualTo(20),
          reason: '200 new files must not produce 200 lines',
        );
        expect(
          lines.where((l) => l.contains('line(s) withheld')),
          isNotEmpty,
          reason: 'a sample must say it is one, or it reads as the whole truth',
        );
        // The summary still carries the real numbers.
        expect(
          lines.where((l) => l.contains('new=200')),
          isNotEmpty,
          reason: 'the counts are what was ever true in bulk',
        );
      },
    );

    test('the scan reports where it has got to', () async {
      // The longest silent stretch a sync has. Without a heartbeat the engine
      // says nothing for as long as the walk takes, and the host reads that
      // silence as a dead engine — one real vault had a mid-scan restart
      // throw away an hour and begin the same minute again.
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = FileStateStore(client: env.client, vaultId: _vaultId);
      await store.load();
      final io = _MemIo();
      for (var i = 0; i < 30; i++) {
        io.files['$_vaultPath/f$i.bin'] = _randomBytes(64, i + 1);
      }

      final beats = <(int, int)>[];
      await StateStartupDiff(
        store: store,
        blobStore: LocalBlobStore(InMemoryBlobRepository()),
        remoteBlobStorage: _MemRemote(),
        io: io,
        vaultPath: _vaultPath,
        vaultId: _vaultId,
        nodeId: 'test-device',
        readClock: store.nextHlc,
        writeClock: (_) {},
        onScanProgress: (scanned, total) => beats.add((scanned, total)),
      ).call();

      expect(beats, isNotEmpty, reason: 'the scan must not be silent');
      // The last beat always lands, whatever the time budget did in between,
      // so a watcher can tell "finished" from "stopped".
      expect(beats.last, (30, 30));
      for (final (scanned, total) in beats) {
        expect(total, 30);
        expect(scanned, inInclusiveRange(1, 30));
      }
    });

    test('the next run skips what the failed one banked', () async {
      // The point of persisting: the fast path compares disk against the
      // stored chunk list, so a surviving row is what stops the file being
      // read, chunked and uploaded all over again.
      final remote = _FailsPartWayRemote(failAfter: 32);
      final f = await fixtureWith(remote, 64);
      await expectLater(f.diff.call(), throwsA(isA<StateError>()));

      final healthy = _MemRemote()..store.addAll(remote.store);
      final reopened = FileStateStore(client: f.client, vaultId: _vaultId);
      await reopened.load();
      final io = _MemIo();
      for (var i = 0; i < 64; i++) {
        io.files['$_vaultPath/f$i.bin'] = _randomBytes(512, i + 1);
      }
      final result = await StateStartupDiff(
        store: reopened,
        blobStore: LocalBlobStore(InMemoryBlobRepository()),
        remoteBlobStorage: healthy,
        io: io,
        vaultPath: _vaultPath,
        vaultId: _vaultId,
        nodeId: 'test-device',
        readClock: reopened.nextHlc,
        writeClock: (_) {},
        uploadConcurrency: 1,
      ).call();

      expect(
        result.newFiles,
        48,
        reason: 'only the forty-eight the first run never reached',
      );
      expect(
        reopened.fileIds.length,
        64,
        reason: 'the second run completes the set rather than redoing it',
      );
    });
    test(
      'a signature left by the sha-skip names the blob it is evidence for',
      () async {
        // The line this protects is the one that made a finished sync start
        // over. `DiskReconciler._diskAlreadyHolds` refuses a blobRef-less
        // signature by design — it proves "unchanged since we last looked",
        // not "holds that content" — so its own-echo guard could never fire
        // for a binary this scan had skipped. The pull that hands a device its
        // own push straight back then downloaded the whole vault, one file at
        // a time, to compare every file against itself.
        //
        // The signature is born here and nowhere else for these files: a later
        // scan skips on it without rewriting it, so a blobRef missing on this
        // pass is missing for good.
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);
        final store = FileStateStore(client: env.client, vaultId: _vaultId);
        await store.load();
        final sigs = StatSigStore(client: env.client, vaultId: _vaultId);
        await sigs.load();
        final io = _CountingIo();
        io.files['$_vaultPath/a.bin'] = _randomBytes(4096, 7);
        final remote = _MemRemote();

        StateStartupDiff diff() => StateStartupDiff(
          store: store,
          blobStore: LocalBlobStore(InMemoryBlobRepository()),
          remoteBlobStorage: remote,
          io: io,
          vaultPath: _vaultPath,
          vaultId: _vaultId,
          nodeId: 'test-device',
          readClock: store.nextHlc,
          writeClock: (_) {},
          sigStore: sigs,
        );

        await diff().call();
        final fileId = const Uuid().v5(_vaultId, 'a.bin');
        final blobRef = store.get(fileId)!.blobRef;
        expect(blobRef, isNotEmpty);

        // An install that predates the blobRef field, or one that simply lost
        // the row: the state is tracked, the signature is not there. This is
        // the state every vault synced by an older build starts the next scan
        // in, and the only one in which the sha-skip writes a signature.
        await sigs.wipeAll();

        await diff().call();

        expect(
          io.reads,
          greaterThan(0),
          reason: 'without a signature the file has to be read — which is '
              'precisely the pass that then records one',
        );
        final sig = sigs.get(fileId);
        expect(sig, isNotNull, reason: 'the skip must leave a signature');
        expect(
          sig!.blobRef,
          blobRef,
          reason: 'the fast path proved the disk bytes hash to this state\'s '
              'chunk list, so the signature may carry the strong claim — and '
              'must, or the pull re-downloads the file to learn it again',
        );
      },
    );
    test(
      'a legacy blobRef-less signature is upgraded by one extra read',
      () async {
        // The half that would otherwise have been missed. Recording the
        // blobRef on the fast path only helps files the scan actually READS,
        // and the mtime+size skip above returns before any read and does not
        // rewrite the signature it skipped on. So a vault carrying thousands
        // of blobRef-less signatures — every vault synced by an older build —
        // would keep them for ever, and go on re-downloading itself.
        //
        // One scan pays for the migration; every scan after it is fast again.
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);
        final store = FileStateStore(client: env.client, vaultId: _vaultId);
        await store.load();
        final sigs = StatSigStore(client: env.client, vaultId: _vaultId);
        await sigs.load();
        final io = _CountingIo();
        io.files['$_vaultPath/a.bin'] = _randomBytes(4096, 11);

        StateStartupDiff diff() => StateStartupDiff(
          store: store,
          blobStore: LocalBlobStore(InMemoryBlobRepository()),
          remoteBlobStorage: _MemRemote(),
          io: io,
          vaultPath: _vaultPath,
          vaultId: _vaultId,
          nodeId: 'test-device',
          readClock: store.nextHlc,
          writeClock: (_) {},
          sigStore: sigs,
        );

        await diff().call();
        final fileId = const Uuid().v5(_vaultId, 'a.bin');
        final blobRef = store.get(fileId)!.blobRef;

        // Exactly what an older build left behind: mtime and size, no blobRef.
        final stat = (await io.statFile('$_vaultPath/a.bin'))!;
        sigs.set(fileId, stat.mtimeMs, stat.sizeBytes);
        // Fire-and-forget by design; a write still in flight when the test's
        // in-memory endpoint closes surfaces as an unhandled stream error.
        await sigs.flushPending();
        expect(sigs.get(fileId)!.blobRef, isNull, reason: 'fixture sanity');

        io.reads = 0;
        await diff().call();

        expect(
          io.reads,
          1,
          reason: 'the migration costs one read of the file, once',
        );
        expect(sigs.get(fileId)!.blobRef, blobRef);

        io.reads = 0;
        await diff().call();

        expect(
          io.reads,
          0,
          reason: 'and the scan after it skips on the stat again — the '
              'migration must not become a permanent cost',
        );
        await sigs.flushPending();
      },
    );

    test(
      'a value carrying a peer node id is left to the pull, not re-read',
      () async {
        // The hazard the migration is fenced against. If the store holds a
        // peer\'s version this device never materialised — the blob was
        // missing, refused, or the pull was interrupted — then disk holds OUR
        // older content. Reading it here would find bytes that do not match
        // the stored chunk list, call that a local edit, and re-upload our
        // older content over the peer\'s.
        //
        // Only a value this device minted may be confirmed by reading the
        // file, because only then can the read possibly agree.
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);
        final store = FileStateStore(client: env.client, vaultId: _vaultId);
        await store.load();
        final sigs = StatSigStore(client: env.client, vaultId: _vaultId);
        await sigs.load();
        final io = _CountingIo();
        io.files['$_vaultPath/a.bin'] = _randomBytes(4096, 12);
        final remote = _MemRemote();

        StateStartupDiff diff() => StateStartupDiff(
          store: store,
          blobStore: LocalBlobStore(InMemoryBlobRepository()),
          remoteBlobStorage: remote,
          io: io,
          vaultPath: _vaultPath,
          vaultId: _vaultId,
          nodeId: 'test-device',
          readClock: store.nextHlc,
          writeClock: (_) {},
          sigStore: sigs,
        );

        await diff().call();
        final fileId = const Uuid().v5(_vaultId, 'a.bin');

        // A peer publishes a version this device has not materialised, and the
        // signature is the old blobRef-less kind.
        final mine = store.get(fileId)!;
        store.applyLocal(
          FileState(
            fileId: fileId,
            path: 'a.bin',
            blobRef: 'peer-blob-ref',
            sizeBytes: mine.sizeBytes,
            hlc: Hlc.now('some-other-device'),
            chunks: const ['peer-chunk'],
          ),
        );
        final stat = (await io.statFile('$_vaultPath/a.bin'))!;
        sigs.set(fileId, stat.mtimeMs, stat.sizeBytes);
        await sigs.flushPending();

        io.reads = 0;
        final uploadsBefore = remote.uploads;
        final result = await diff().call();

        expect(
          io.reads,
          0,
          reason: 'a peer value is not ours to confirm by reading the disk',
        );
        expect(
          remote.uploads,
          uploadsBefore,
          reason: 'and nothing of ours may be pushed over it',
        );
        expect(result.modifiedFiles, 0);
        await sigs.flushPending();
      },
    );
  });
}
