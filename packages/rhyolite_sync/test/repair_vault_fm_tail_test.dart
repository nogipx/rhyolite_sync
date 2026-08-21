import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_state.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_store.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_tail.dart';
import 'package:rhyolite_sync/src/sync_v3/disk_reconciler.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'support/fake_change_provider.dart';

const _vaultPath = '/vault';
const _vaultId = '00000000-0000-4000-8000-000000000002';
const _note = 'note.md';
const _notePath = 'test/fixtures/frontmatter_heavy_note.md';

class _MemIo implements IPlatformIO {
  final Map<String, Uint8List> files = {};

  @override
  Future<bool> fileExists(String p) async => files.containsKey(p);
  @override
  Future<bool> dirExists(String p) async => true;
  @override
  Future<Uint8List> readFile(String p) async => files[p]!;
  @override
  Future<void> writeFile(String p, Uint8List b) async => files[p] = b;
  @override
  Future<void> deleteFile(String p) async => files.remove(p);
  @override
  Future<void> moveFile(String a, String b) async {
    final v = files.remove(a);
    if (v != null) files[b] = v;
  }

  @override
  Future<void> deleteEmptyDirsUpTo(String d, String s) async {}
  @override
  Future<List<String>> listFiles(String d) async =>
      files.keys.where((p) => p.startsWith(d)).toList();
  @override
  Future<FileStatInfo?> statFile(String p) async {
    final b = files[p];
    return b == null ? null : FileStatInfo(mtimeMs: 1, sizeBytes: b.length);
  }
}

class _MemRemote implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  @override
  Future<Set<String>> exists(List<String> ids, {RpcContext? context}) async =>
      {for (final i in ids) if (store.containsKey(i)) i};
  @override
  Future<void> upload(List<(Uint8List, String)> blobs,
      {RpcContext? context}) async {
    for (final (b, i) in blobs) {
      store[i] = b;
    }
  }

  @override
  Future<Map<String, Uint8List>> download(List<String> ids,
          {RpcContext? context}) async =>
      {for (final i in ids) if (store.containsKey(i)) i: store[i]!};
  @override
  Future<void> deleteMany(List<String> ids, {RpcContext? context}) async {
    for (final i in ids) {
      store.remove(i);
    }
  }
}

void main() {
  test('repair re-uploads text blobs WITH their frontmatter tail', () async {
    final env = await DataServiceFactory.inMemory();
    addTearDown(env.dispose);

    final store = FileStateStore(client: env.client, vaultId: _vaultId);
    await store.load();
    final fugueStore = FugueStore(client: env.client, vaultId: _vaultId);
    await fugueStore.load();
    final fmStore = FmStore(client: env.client, vaultId: _vaultId);
    await fmStore.load();

    final io = _MemIo();
    final localBlobs = LocalBlobStore(InMemoryBlobRepository());
    final remote = _MemRemote();
    final events = <SyncEngineEvent>[];

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
      changeProvider: NoopChangeProvider(),
      store: store,
      fugueStore: fugueStore,
      fmStore: fmStore,
      chunkedIOBuilder: builder,
      knownChunks: () => <String>{},
      fileIdFor: (p) => const Uuid().v5(_vaultId, p),
      emit: events.add,
    );

    final note = File(_notePath).readAsStringSync();
    io.files['$_vaultPath/$_note'] = Uint8List.fromList(utf8.encode(note));

    await RepairVaultUseCase(
      io: io,
      vaultPath: _vaultPath,
      vaultId: _vaultId,
      store: store,
      fugueStore: fugueStore,
      fmStore: fmStore,
      uploadSequenceBlob: reconciler.uploadSequenceBlob,
      emit: events.add,
      logWarning: (_) {},
    )();

    final state = store.get(const Uuid().v5(_vaultId, _note));
    expect(state, isNotNull, reason: 'repair must write a state for the note');

    final bytes = await builder()!.download(state!.blobRef);
    expect(bytes, isNotNull);
    expect(
      hasFmTail(bytes!),
      isTrue,
      reason: 'a repaired blob without the tail turns every later concurrent '
          'edit into a character merge of the frontmatter region',
    );

    // The tail must describe the note that is actually on disk.
    final fm = readFmTail(bytes)!;
    final rebuilt = renderNote(
      materializeFm(fm),
      splitFrontmatter(note).body,
    );
    expect(rebuilt, normalizeNewlines(note));
  });

  test('a note with no frontmatter is repaired without a tail', () async {
    final env = await DataServiceFactory.inMemory();
    addTearDown(env.dispose);

    final store = FileStateStore(client: env.client, vaultId: _vaultId);
    await store.load();
    final fugueStore = FugueStore(client: env.client, vaultId: _vaultId);
    await fugueStore.load();
    final fmStore = FmStore(client: env.client, vaultId: _vaultId);
    await fmStore.load();

    final io = _MemIo();
    final localBlobs = LocalBlobStore(InMemoryBlobRepository());
    final remote = _MemRemote();

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
      changeProvider: NoopChangeProvider(),
      store: store,
      fugueStore: fugueStore,
      fmStore: fmStore,
      chunkedIOBuilder: builder,
      knownChunks: () => <String>{},
      fileIdFor: (p) => const Uuid().v5(_vaultId, p),
      emit: (_) {},
    );

    io.files['$_vaultPath/plain.md'] =
        Uint8List.fromList(utf8.encode('# Title\n\nbody\n'));

    await RepairVaultUseCase(
      io: io,
      vaultPath: _vaultPath,
      vaultId: _vaultId,
      store: store,
      fugueStore: fugueStore,
      fmStore: fmStore,
      uploadSequenceBlob: reconciler.uploadSequenceBlob,
      emit: (_) {},
      logWarning: (_) {},
    )();

    final state = store.get(const Uuid().v5(_vaultId, 'plain.md'))!;
    final bytes = await builder()!.download(state.blobRef);
    expect(hasFmTail(bytes!), isFalse,
        reason: 'no properties means nothing to carry — the blob stays as it '
            'is today, so plain notes cost nothing');
  });
}
