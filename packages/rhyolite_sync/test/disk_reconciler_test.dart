import 'dart:convert';
import 'dart:typed_data';

import 'package:convergent/convergent.dart';
import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_tail.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_render.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_split.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_store.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_state.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_store.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_document.dart';
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
  FmStore fmStore,
  _MemIo io,
  _NoopChangeProvider changes,
  LocalBlobStore localBlobs,
  _MemRemote remote,
  List<SyncEngineEvent> events,
  String Function(String) fileIdFor,
});

Future<_Fixture> _newFixture({
  int? Function()? maxFileSizeBytes,
  PathScope? pathScope,
  bool frontmatter = true,
  int? fmGcBarrier,
}) async {
  final env = await DataServiceFactory.inMemory();
  addTearDown(env.dispose);

  final store = FileStateStore(client: env.client, vaultId: _vaultId);
  await store.load();
  final fugueStore = FugueStore(client: env.client, vaultId: _vaultId);
  await fugueStore.load();
  final fmStore = FmStore(client: env.client, vaultId: _vaultId);
  await fmStore.load();

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
    pathScope: pathScope == null ? null : () => pathScope,
    fmStore: frontmatter ? fmStore : null,
    fmGcBarrier: () => fmGcBarrier,
  );

  return (
    reconciler: reconciler,
    store: store,
    fugueStore: fugueStore,
    fmStore: fmStore,
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

  group('DiskReconciler — a format this build cannot read', () {
    /// A blob written by a NEWER client: NUL-tagged, no decoder here.
    ///
    /// Not `\0doc1` — that tag exists now. This is whatever comes after it.
    Future<String> publishFutureFormat(_Fixture f, String relPath) async {
      final blob = Uint8List.fromList(
        [0x00, 0x78, 0x79, 0x7A, 0x39, 0xA1, 0x61, 0x78, 0x01],
      );
      final chunked = ChunkedBlobIO(
        blobStore: f.localBlobs,
        remoteBlobStorage: f.remote,
        vaultId: _vaultId,
      );
      final up = await chunked.upload(blob, <String>{});
      final fileId = f.fileIdFor(relPath);
      f.store.applyLocal(
        FileState(
          fileId: fileId,
          path: relPath,
          blobRef: up.manifestHash,
          sizeBytes: blob.length,
          hlc: Hlc.now('peer-from-the-future'),
          chunks: up.chunkHashes,
        ),
      );
      return fileId;
    }

    test('is never written to disk, and says so', () async {
      // Before the classifier this fell through to "write as-is" and put the
      // serialised state inside the user's note. This is the only path that
      // corrupts the vault rather than merely showing something unreadable.
      final f = await _newFixture();
      final fileId = await publishFutureFormat(f, 'notes/future.md');

      final wrote = await f.reconciler.writeFileToDisk(f.store.get(fileId)!);

      expect(wrote, isFalse);
      expect(f.io.files.containsKey('$_vaultPath/notes/future.md'), isFalse,
          reason: 'nothing may reach disk');
      final events =
          f.events.whereType<SyncFileFormatUnsupported>().toList();
      expect(events.single.path, 'notes/future.md');
    });

    test('the LCA is not advanced, so an updated client heals it', () async {
      final f = await _newFixture();
      final fileId = await publishFutureFormat(f, 'notes/future.md');

      await f.reconciler.writeFileToDisk(f.store.get(fileId)!);

      expect(f.store.lastSyncedBlobRefFor(fileId), anyOf(isNull, isEmpty),
          reason: 'advancing it would mark the file done forever');
    });

    test('a local edit does not push over it', () async {
      // The dangerous direction: seeding an empty tree would make the
      // reconciler diff disk against nothing, push a full-content blob in THIS
      // build's format, and destroy what the newer client wrote.
      final f = await _newFixture();
      final fileId = await publishFutureFormat(f, 'notes/future.md');
      final serverBlob = f.store.get(fileId)!.blobRef;
      f.io.files['$_vaultPath/notes/future.md'] = _bytes('local edit');

      final changed = await f.reconciler.reconcileWithDisk('notes/future.md');

      expect(changed, isFalse, reason: 'no push may be produced');
      expect(f.store.get(fileId)!.blobRef, serverBlob,
          reason: "the newer client's blob must still be the one referenced");
      expect(f.events.whereType<SyncFileFormatUnsupported>(), isNotEmpty);
    });
  });

  group('DiskReconciler — frontmatter as a CRDT', () {
    test('a note with no properties is byte-identical to what ships today',
        () async {
      // Not a flag any more — a property. An empty state would cost ~80 bytes
      // of "nothing here" on every note in the vault, so nothing is appended
      // until there is something to say.
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] = _bytes('# Note\n\njust body\n');

      await f.reconciler.reconcileWithDisk('note.md');

      final state = f.store.get(f.fileIdFor('note.md'))!;
      final blob = await ChunkedBlobIO(
        blobStore: f.localBlobs,
        remoteBlobStorage: f.remote,
        vaultId: _vaultId,
      ).download(state.blobRef);
      expect(blob!.sublist(0, 4), [0x00, 0x66, 0x67, 0x31], reason: 'fugue1');
      expect(hasFmTail(blob), isFalse, reason: 'no tail either');
    });

    test('emptying the properties still carries the tombstones', () async {
      // The subtlety behind the rule above: no LIVE entries is not the same as
      // nothing to carry. Drop the tail here and a peer that never saw the
      // delete adds the keys straight back.
      final f = await _newFixture();
      f.io.files['$_vaultPath/n.md'] = _bytes('---\nx: 1\n---\nbody\n');
      await f.reconciler.reconcileWithDisk('n.md');
      f.io.files['$_vaultPath/n.md'] = _bytes('body\n');
      await f.reconciler.reconcileWithDisk('n.md');

      final blob = await ChunkedBlobIO(
        blobStore: f.localBlobs,
        remoteBlobStorage: f.remote,
        vaultId: _vaultId,
      ).download(f.store.get(f.fileIdFor('n.md'))!.blobRef);
      final fm = readFmTail(blob!);
      expect(fm, isNotNull, reason: 'the delete must travel');
      expect((fm! as FmMapState).entries['x']?.isLive, isFalse);
    });

    test('the state rides in the tail, invisibly', () async {
      final f = await _newFixture();
      f.io.files['$_vaultPath/note.md'] =
          _bytes('---\ntitle: Note\ntags:\n  - work\n---\n\nbody\n');

      await f.reconciler.reconcileWithDisk('note.md');

      final state = f.store.get(f.fileIdFor('note.md'))!;
      final blob = await ChunkedBlobIO(
        blobStore: f.localBlobs,
        remoteBlobStorage: f.remote,
        vaultId: _vaultId,
      ).download(state.blobRef);
      // Still an ordinary fugue1 blob to anyone who does not look for a tail.
      expect(blob!.sublist(0, 4), [0x00, 0x66, 0x67, 0x31]);

      // And an OLD client decodes it to the whole note, frontmatter included,
      // exactly as it does today. This is the property the design rests on.
      expect(
        utf8.decode(materializeFileContent(blob, 'note.md')!),
        '---\ntitle: Note\ntags:\n  - work\n---\n\nbody\n',
      );

      // A new client additionally finds the typed state.
      final fm = readFmTail(blob);
      expect(fm, isNotNull);
      final doc = materializeFm(fm!) as FmMap;
      expect(doc.entries.map((e) => e.key), ['title', 'tags']);
    });

    test('writing the blob back to disk reproduces the note', () async {
      final f = await _newFixture();
      const note = '---\ntitle: Note\ntags:\n  - work\n---\n\nbody\n';
      f.io.files['$_vaultPath/note.md'] = _bytes(note);
      await f.reconciler.reconcileWithDisk('note.md');

      final state = f.store.get(f.fileIdFor('note.md'))!;
      f.io.files.remove('$_vaultPath/note.md');
      await f.fugueStore.remove(f.fileIdFor('note.md'));
      await f.fmStore.remove(f.fileIdFor('note.md'));

      final wrote = await f.reconciler.writeFileToDisk(state);

      expect(wrote, isTrue);
      expect(utf8.decode(f.io.files['$_vaultPath/note.md']!), note);
    });

    test('THE BUG, through the engine: two devices append to one key',
        () async {
      // Each fixture is a device. They start from the same note, edit offline,
      // and the join runs over what each one uploaded.
      final a = await _newFixture();
      final b = await _newFixture();
      const base = '---\nrelated:\n  - "[[seed]]"\n---\n\nbody\n';

      a.io.files['$_vaultPath/n.md'] = _bytes(base);
      await a.reconciler.reconcileWithDisk('n.md');
      b.io.files['$_vaultPath/n.md'] = _bytes(base);
      await b.reconciler.reconcileWithDisk('n.md');

      a.io.files['$_vaultPath/n.md'] =
          _bytes('---\nrelated:\n  - "[[seed]]"\n  - "[[from-a]]"\n---\n\nbody\n');
      await a.reconciler.reconcileWithDisk('n.md');
      b.io.files['$_vaultPath/n.md'] =
          _bytes('---\nrelated:\n  - "[[seed]]"\n  - "[[from-b]]"\n---\n\nbody\n');
      await b.reconciler.reconcileWithDisk('n.md');

      final fileId = a.fileIdFor('n.md');
      final fmA = (await a.fmStore.get(fileId))!;
      final fmB = (await b.fmStore.get(fileId))!;

      final merged = materializeFm(joinFm(fmA, fmB)) as FmMap;
      expect(merged.entries, hasLength(1), reason: 'one `related`, not two');
      final items = (merged.entries.single.value as FmList).items;
      expect(items, containsAll(['[[seed]]', '[[from-a]]', '[[from-b]]']));
    });

    test('THE BUG, through the real merge: the region is rewritten from the '
        'joined state', () async {
      // The previous test joins the two states by hand. This one goes through
      // what RemoteApplier actually does when two divergent versions meet:
      // join the trees, join the tails, then REWRITE the region from the
      // joined frontmatter. Without that last step the char-level join leaves
      // `related:` in the file twice — valid YAML that readers silently halve,
      // which is the original defect.
      // The key must not exist in the base. Where the `related:` LINE is
      // shared history, the character join already merges the items correctly
      // — writing this test the other way round proved that, and it is worth
      // knowing: the defect is concurrent CREATION of the same key, not
      // concurrent appending to one that already exists.
      final a = await _newFixture();
      final b = await _newFixture();
      const base = '---\ncreated: 2026-08-03\n---\n\nbody\n';

      a.io.files['$_vaultPath/n.md'] = _bytes(base);
      await a.reconciler.reconcileWithDisk('n.md');
      b.io.files['$_vaultPath/n.md'] = _bytes(base);
      await b.reconciler.reconcileWithDisk('n.md');

      a.io.files['$_vaultPath/n.md'] = _bytes(
          '---\ncreated: 2026-08-03\nrelated:\n  - "[[from-a]]"\n---\n\nbody\n');
      await a.reconciler.reconcileWithDisk('n.md');
      b.io.files['$_vaultPath/n.md'] = _bytes(
          '---\ncreated: 2026-08-03\nrelated:\n  - "[[from-b]]"\n---\n\nbody\n');
      await b.reconciler.reconcileWithDisk('n.md');

      final fileId = a.fileIdFor('n.md');
      final blobA = (await ChunkedBlobIO(
        blobStore: a.localBlobs,
        remoteBlobStorage: a.remote,
        vaultId: _vaultId,
      ).download(a.store.get(fileId)!.blobRef))!;
      final blobB = (await ChunkedBlobIO(
        blobStore: b.localBlobs,
        remoteBlobStorage: b.remote,
        vaultId: _vaultId,
      ).download(b.store.get(fileId)!.blobRef))!;

      // What the char-level join alone produces — the defect, reproduced.
      final textOnly = FugueStore.tryDecodeBlob(blobA)!
          .join(FugueStore.tryDecodeBlob(blobB)!)
          .values
          .join();
      expect('related:'.allMatches(textOnly).length, 2,
          reason: 'the text merge really does duplicate the key');

      // What the frontmatter join produces instead.
      final joined = joinFm(readFmTail(blobA)!, readFmTail(blobB)!);
      final parts = splitFrontmatter(textOnly);
      final corrected = renderNote(materializeFm(joined), parts.body);

      expect('related:'.allMatches(corrected).length, 1, reason: 'one key');
      expect(corrected, contains('[[from-a]]'));
      expect(corrected, contains('[[from-b]]'));
      expect(corrected, endsWith('body\n'));
    });

    test('a deletion everyone has seen is reclaimed on the next write',
        () async {
      // Reclaimed only on a write that was happening anyway, and only past the
      // causal-stability barrier. A sweep of its own would rewrite every file
      // in the vault, which is exactly the mass re-upload to avoid.
      final f = await _newFixture(fmGcBarrier: 1 << 30);
      f.io.files['$_vaultPath/n.md'] = _bytes('---\nx: 1\ny: 2\n---\nbody\n');
      await f.reconciler.reconcileWithDisk('n.md');
      final fileId = f.fileIdFor('n.md');
      f.store.recordServerSeq(fileId, 1);

      f.io.files['$_vaultPath/n.md'] = _bytes('---\ny: 2\n---\nbody\n');
      await f.reconciler.reconcileWithDisk('n.md');

      final fm = (await f.fmStore.get(fileId))! as FmMapState;
      expect(fm.entries.containsKey('x'), isFalse, reason: 'reclaimed');
      expect(fm.entries.containsKey('y'), isTrue);
    });

    test('a deletion the barrier does not cover is kept', () async {
      // No barrier means no proof every device saw the delete, so the
      // tombstone stays and a lagging peer cannot resurrect the key.
      final f = await _newFixture();
      f.io.files['$_vaultPath/n.md'] = _bytes('---\nx: 1\ny: 2\n---\nbody\n');
      await f.reconciler.reconcileWithDisk('n.md');
      final fileId = f.fileIdFor('n.md');

      f.io.files['$_vaultPath/n.md'] = _bytes('---\ny: 2\n---\nbody\n');
      await f.reconciler.reconcileWithDisk('n.md');

      final fm = (await f.fmStore.get(fileId))! as FmMapState;
      expect(fm.entries['x']?.isLive, isFalse, reason: 'present, tombstoned');
    });

    test('a peer that ignores the tail simply drops it, and nothing breaks',
        () async {
      // The graceful-degradation claim, exercised: a device without the
      // feature re-encodes the tree on its next edit and the tail goes with
      // it. The note is intact, the typed state is rebuilt next time a device
      // that has the feature touches the file.
      final on = await _newFixture();
      on.io.files['$_vaultPath/n.md'] = _bytes('---\nx: 1\n---\nbody\n');
      await on.reconciler.reconcileWithDisk('n.md');

      // A device without the feature: no frontmatter store wired, exactly as
      // a build predating it behaves.
      final off = await _newFixture(frontmatter: false);
      off.remote.store.addAll(on.remote.store);
      off.store.applyLocal(on.store.get(on.fileIdFor('n.md'))!);
      off.io.files['$_vaultPath/n.md'] = _bytes('---\nx: 2\n---\nbody\n');

      await off.reconciler.reconcileWithDisk('n.md');

      final after = off.store.get(off.fileIdFor('n.md'))!;
      final blob = await ChunkedBlobIO(
        blobStore: off.localBlobs,
        remoteBlobStorage: off.remote,
        vaultId: _vaultId,
      ).download(after.blobRef);
      expect(hasFmTail(blob!), isFalse, reason: 'the tail is gone');
      expect(
        utf8.decode(materializeFileContent(blob, 'n.md')!),
        '---\nx: 2\n---\nbody\n',
        reason: 'the note itself is untouched',
      );
    });
  });

  group('DiskReconciler - path admission', () {
    test('an in-scope file syncs normally', () async {
      final f = await _newFixture(pathScope: PathScope(include: ['Work']));
      f.io.files['$_vaultPath/Work/plan.md'] = _bytes('hello');

      final changed = await f.reconciler.reconcileWithDisk('Work/plan.md');

      expect(changed, isTrue);
      expect(f.store.get(f.fileIdFor('Work/plan.md')), isNotNull);
      expect(f.events.whereType<SyncFileOutOfScope>(), isEmpty);
    });

    test('an out-of-scope file is neither read nor uploaded', () async {
      final f = await _newFixture(pathScope: PathScope(include: ['Work']));
      f.io.files['$_vaultPath/Personal/diary.md'] = _bytes('secret');

      final changed = await f.reconciler.reconcileWithDisk('Personal/diary.md');

      expect(changed, isFalse);
      expect(f.store.get(f.fileIdFor('Personal/diary.md')), isNull,
          reason: 'no FileState is minted for a path out of scope');
      expect(f.remote.store, isEmpty, reason: 'nothing was uploaded');
      expect(
        f.events.whereType<SyncFileOutOfScope>().map((e) => e.path),
        ['Personal/diary.md'],
      );
    });

    test('narrowing the scope does not tombstone what falls out of it',
        () async {
      // The file was synced while everything was in scope...
      final wide = await _newFixture();
      wide.io.files['$_vaultPath/Personal/diary.md'] = _bytes('secret');
      await wide.reconciler.reconcileWithDisk('Personal/diary.md');
      final fileId = wide.fileIdFor('Personal/diary.md');
      expect(wide.store.get(fileId)?.tombstone, isFalse);

      // ...then the user restricts sync to Work/ and deletes the file (or it
      // simply stops being visible). A delete reaches the reconciler as a
      // reconcile of a path with no file behind it; out of scope, that must
      // NOT become a tombstone the peers would act on.
      final narrow = await _newFixture(pathScope: PathScope(include: ['Work']));
      narrow.store.applyLocal(wide.store.get(fileId)!);
      // no file on disk in the narrow fixture

      final changed =
          await narrow.reconciler.reconcileWithDisk('Personal/diary.md');

      expect(changed, isFalse);
      expect(narrow.store.get(fileId)?.tombstone, isFalse,
          reason: 'a scope change is not a delete');
    });

    test('exclude carves a hole inside an included folder', () async {
      final f = await _newFixture(
        pathScope: PathScope(include: ['Work'], exclude: ['Work/scratch']),
      );
      f.io.files['$_vaultPath/Work/plan.md'] = _bytes('keep');
      f.io.files['$_vaultPath/Work/scratch/tmp.md'] = _bytes('drop');

      expect(await f.reconciler.reconcileWithDisk('Work/plan.md'), isTrue);
      expect(
        await f.reconciler.reconcileWithDisk('Work/scratch/tmp.md'),
        isFalse,
      );
      expect(f.store.get(f.fileIdFor('Work/scratch/tmp.md')), isNull);
    });
  });
}
