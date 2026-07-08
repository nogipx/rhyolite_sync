import 'dart:convert';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/sync_v3/disk_reconciler.dart';
import 'package:rhyolite_sync/src/sync_v3/remote_applier.dart';
import 'package:rhyolite_sync/src/sync_v3/state_record_codec.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

const _vaultPath = '/vault';
const _vaultId = '00000000-0000-4000-8000-000000000001';

class _IdentityCipher implements IVaultCipher {
  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async => plaintext;
  @override
  Future<Uint8List> decrypt(Uint8List ciphertext) async => ciphertext;
}

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

/// A resolver that must never run — the single-value apply path does not
/// touch it, so any call means the test set up a spurious conflict.
class _UnusedResolver implements IStateConflictResolver {
  @override
  Future<StateMergeOutcome> resolve(
    List<FileState> values, {
    String? baseRef,
  }) async =>
      throw StateError('resolver must not run in the single-value path');
}

/// Rebuilds a pull record from a put item, as the server would.
StateRecord _asRecord(StatePutItem item, int seq) => StateRecord(
      fileId: item.fileId,
      encryptedState: item.encryptedState,
      blobRef: item.blobRef,
      hlcPacked: item.hlcPacked,
      contextPacked: item.contextPacked,
      serverSeq: seq,
      tombstone: item.tombstone,
      chunks: item.chunks,
    );

typedef _Fx = ({
  RemoteApplier applier,
  FileStateStore store,
  _MemIo io,
  LocalBlobStore localBlobs,
  _MemRemote remote,
  List<SyncEngineEvent> events,
  StateRecordCodec codec,
  ChunkedBlobIO? Function() builder,
  String Function(String) fileIdFor,
});

Future<_Fx> _newApplier() async {
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
  final events = <SyncEngineEvent>[];

  String fileIdFor(String relPath) => const Uuid().v5(_vaultId, relPath);

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
    changeProvider: changes,
    store: store,
    fugueStore: fugueStore,
    chunkedIOBuilder: builder,
    knownChunks: () => {for (final s in store.allValuesFlat) ...s.chunks},
    fileIdFor: fileIdFor,
    emit: events.add,
  );

  final codec = StateRecordCodec(cipher: _IdentityCipher());

  final applier = RemoteApplier(
    store: store,
    fugueStore: fugueStore,
    reconciler: reconciler,
    codec: codec,
    blobStore: localBlobs,
    io: io,
    changeProvider: changes,
    vaultId: _vaultId,
    vaultPath: _vaultPath,
    newChunkedIO: builder,
    collectKnownChunks: () => <String>{},
    emit: events.add,
    isFatalRejection: (_) => false,
    log: LogScope.noop,
  );

  return (
    applier: applier,
    store: store,
    io: io,
    localBlobs: localBlobs,
    remote: remote,
    events: events,
    codec: codec,
    builder: builder,
    fileIdFor: fileIdFor,
  );
}

Future<StateRecord> _record(
  StateRecordCodec codec,
  FileState state,
  int seq,
) async {
  final ctx = CausalContext.from({state.hlc.nodeId: state.hlc});
  final item = await codec.encode(state, ctx);
  return _asRecord(item, seq);
}

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('RemoteApplier — synced-ref only on confirmed disk write (L1-1)', () {
    test(
      'blob unavailable -> file NOT marked synced (so a later pull retries)',
      () async {
        final f = await _newApplier();
        final fileId = f.fileIdFor('img.bin');
        // A record pointing at a manifest that exists in neither the local
        // cache nor remote storage: download returns null, so nothing is
        // written to disk.
        final state = FileState(
          fileId: fileId,
          path: 'img.bin',
          blobRef: 'manifest-that-does-not-exist',
          sizeBytes: 14,
          hlc: Hlc(1000, 0, 'device-A'),
          chunks: const ['chunk-that-does-not-exist'],
        );

        await f.applier.apply(fileId, [await _record(f.codec, state, 1)],
            _UnusedResolver());

        expect(
          f.io.files.containsKey('$_vaultPath/img.bin'),
          isFalse,
          reason: 'download failed, so nothing should be on disk',
        );
        expect(
          f.store.lastSyncedBlobRefFor(fileId),
          isNull,
          reason:
              'the LCA must NOT advance to a blobRef we never materialised — '
              'otherwise the blobRef==lastRef short-circuit permanently skips '
              'this file and it stays missing on disk forever',
        );
      },
    );

    test('blob available -> file written and marked synced', () async {
      final f = await _newApplier();
      final fileId = f.fileIdFor('img.bin');
      // Upload real content so the manifest + chunk are retrievable.
      final up = await f.builder()!.upload(_bytes('binary content'), <String>{});
      final state = FileState(
        fileId: fileId,
        path: 'img.bin',
        blobRef: up.manifestHash,
        sizeBytes: 14,
        hlc: Hlc(1000, 0, 'device-A'),
        chunks: up.chunkHashes,
      );

      await f.applier.apply(fileId, [await _record(f.codec, state, 1)],
          _UnusedResolver());

      expect(
        utf8.decode(f.io.files['$_vaultPath/img.bin']!),
        'binary content',
        reason: 'content is available, so it must land on disk',
      );
      expect(f.store.lastSyncedBlobRefFor(fileId), up.manifestHash,
          reason: 'confirmed write advances the LCA');
    });
  });

  group('RemoteApplier — text conflict never drops an unreachable side (L1-2)',
      () {
    test(
      'concurrent text edit whose blob is unreachable is retained, not sealed away',
      () async {
        final f = await _newApplier();
        final fileId = f.fileIdFor('note.md');

        // Device A: real, retrievable content.
        final upA = await f.builder()!.upload(_bytes('hello from A'), <String>{});
        final stateA = FileState(
          fileId: fileId,
          path: 'note.md',
          blobRef: upA.manifestHash,
          sizeBytes: 11,
          hlc: Hlc(1000, 0, 'device-A'),
          chunks: upA.chunkHashes,
        );
        // Device B: concurrent edit, but its blob was never uploaded here —
        // download will fail. Its content must NOT be lost.
        final stateB = FileState(
          fileId: fileId,
          path: 'note.md',
          blobRef: 'manifest-B-unreachable',
          sizeBytes: 11,
          hlc: Hlc(1000, 0, 'device-B'),
          chunks: const ['chunk-B-unreachable'],
        );

        await f.applier.apply(
          fileId,
          [
            await _record(f.codec, stateA, 1),
            await _record(f.codec, stateB, 2),
          ],
          _UnusedResolver(),
        );

        expect(
          f.store.hasConflict(fileId),
          isTrue,
          reason:
              'with one concurrent blob unreachable, the register must stay '
              'multi-valued (deferred) rather than collapse to the survivor',
        );
        expect(
          f.store.currentValues(fileId).map((s) => s.blobRef),
          containsAll(<String>[upA.manifestHash, 'manifest-B-unreachable']),
          reason: 'both concurrent sides must survive; nothing is dropped',
        );
        expect(
          f.events.whereType<SyncConflictResolved>(),
          isEmpty,
          reason: 'a conflict resolved on partial input would be a false claim',
        );
      },
    );
  });

  group('RemoteApplier — N>2 binary conflict preserves every version (L1-5)',
      () {
    test(
        'three concurrent binary versions -> winner + 2 conflict copies on disk',
        () async {
      final f = await _newApplier();
      final fileId = f.fileIdFor('photo.bin'); // non-text -> binary resolver

      // Upload distinct content so each version's blob is retrievable.
      final upA = await f.builder()!.upload(_bytes('version A'), <String>{});
      final upB = await f.builder()!.upload(_bytes('version B'), <String>{});
      final upC = await f.builder()!.upload(_bytes('version C'), <String>{});
      FileState mk(({String manifestHash, List<String> chunkHashes}) up,
              int millis, String node) =>
          FileState(
            fileId: fileId,
            path: 'photo.bin',
            blobRef: up.manifestHash,
            sizeBytes: 9,
            hlc: Hlc(millis, 0, node),
            chunks: up.chunkHashes,
          );

      final resolver = StateConflictResolver(
        store: f.store,
        blobStore: f.localBlobs,
        vaultId: _vaultId,
        nodeId: 'test',
        chunkedBlobIO: f.builder(),
      );

      await f.applier.apply(
        fileId,
        [
          await _record(f.codec, mk(upA, 100, 'A'), 1),
          await _record(f.codec, mk(upB, 200, 'B'), 2),
          await _record(f.codec, mk(upC, 300, 'C'), 3),
        ],
        resolver,
      );

      // Winner (max-HLC = C) is materialised at the canonical path.
      expect(utf8.decode(f.io.files['$_vaultPath/photo.bin']!), 'version C');
      // The two non-winning versions are preserved as conflict-copy files —
      // not silently dropped.
      final copies =
          f.io.files.keys.where((p) => p != '$_vaultPath/photo.bin').toList();
      expect(copies, hasLength(2),
          reason: 'both A and B must survive as conflict copies');
      final copyContents =
          copies.map((p) => utf8.decode(f.io.files[p]!)).toSet();
      expect(copyContents, containsAll(<String>{'version A', 'version B'}));
    });
  });
}
