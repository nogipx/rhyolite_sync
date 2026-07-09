// H2 — The plain (no-E2EE) blob path writes silently-corrupt bytes to disk.
//
// Continuation of H1: the same "wrong bytes, right length" fault, propagated
// all the way through RemoteApplier -> DiskReconciler.writeFileToDisk ->
// IPlatformIO.writeFile. With no cipher, the corruption lands on disk AND the
// file is marked synced (LCA advanced), so no later pull re-heals it.
//
// The mirror case proves E2EE is protected only as a SIDE EFFECT of AES-GCM
// authentication (the tag fails to decrypt), not by any content check in the
// sync engine itself.
import 'dart:convert';
import 'dart:typed_data';

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

import 'support/fake_blob_storage.dart';
import 'support/fake_change_provider.dart';
import 'support/fake_platform_io.dart';
import 'support/identity_cipher.dart';

const _vaultPath = '/vault';
const _vaultId = '00000000-0000-4000-8000-0000000000a2';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

String _fileIdFor(String relPath) => const Uuid().v5(_vaultId, relPath);

typedef _Fx = ({
  RemoteApplier applier,
  FileStateStore store,
  FakePlatformIO io,
  LocalBlobStore appLocal,
  StateRecordCodec codec,
});

/// Applier whose blob path talks to [remote]. The applier's own local cache is
/// EMPTY, so a materialise is forced to fetch from [remote] (where the fault is
/// injected). The state codec uses an identity cipher — we are testing the blob
/// path, not state encryption.
Future<_Fx> _newApplier(IBlobStorage remote) async {
  final env = await DataServiceFactory.inMemory();
  addTearDown(env.dispose);

  final store = FileStateStore(client: env.client, vaultId: _vaultId);
  await store.load();
  final fugueStore = FugueStore(client: env.client, vaultId: _vaultId);
  await fugueStore.load();

  final io = FakePlatformIO();
  final changes = NoopChangeProvider();
  final appLocal = LocalBlobStore(InMemoryBlobRepository());
  final events = <SyncEngineEvent>[];

  ChunkedBlobIO? builder() => ChunkedBlobIO(
        blobStore: appLocal,
        remoteBlobStorage: remote,
        vaultId: _vaultId,
      );

  final reconciler = DiskReconciler(
    vaultPath: _vaultPath,
    vaultId: _vaultId,
    io: io,
    blobStore: appLocal,
    changeProvider: changes,
    store: store,
    fugueStore: fugueStore,
    chunkedIOBuilder: builder,
    knownChunks: () => {for (final s in store.allValuesFlat) ...s.chunks},
    fileIdFor: _fileIdFor,
    emit: events.add,
  );

  final codec = StateRecordCodec(cipher: IdentityCipher());

  final applier = RemoteApplier(
    store: store,
    fugueStore: fugueStore,
    reconciler: reconciler,
    codec: codec,
    blobStore: appLocal,
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

  return (applier: applier, store: store, io: io, appLocal: appLocal, codec: codec);
}

Future<StateRecord> _record(StateRecordCodec codec, FileState state, int seq) async {
  final ctx = CausalContext.from({state.hlc.nodeId: state.hlc});
  final item = await codec.encode(state, ctx);
  return StateRecord(
    fileId: item.fileId,
    encryptedState: item.encryptedState,
    blobRef: item.blobRef,
    hlcPacked: item.hlcPacked,
    contextPacked: item.contextPacked,
    serverSeq: seq,
    tombstone: item.tombstone,
    chunks: item.chunks,
  );
}

/// Upload [original] to [remote] via a throwaway producer whose local cache is
/// discarded — so the applier under test cannot short-circuit on a local hit.
Future<({String manifestHash, List<String> chunkHashes})> _seedRemote(
  IBlobStorage remote,
  Uint8List original,
) async {
  final producer = ChunkedBlobIO(
    blobStore: LocalBlobStore(InMemoryBlobRepository()),
    remoteBlobStorage: remote,
    vaultId: _vaultId,
  );
  return producer.upload(original, <String>{});
}

void main() {
  group('H2 (FIXED) — corruption never reaches disk', () {
    test(
      'corrupt chunk on remote (no cipher) -> nothing written, NOT marked '
      'synced (a later pull retries)',
      () async {
        final backing = FakeBlobStorage();
        final f = await _newApplier(backing);
        final fileId = _fileIdFor('img.bin'); // binary -> written as-is

        final original = _bytes('the authentic binary payload');
        final up = await _seedRemote(backing, original);

        // Inject the fault: one chunk now returns wrong bytes of right length.
        corruptSameLength(backing.store, up.chunkHashes.first);

        final state = FileState(
          fileId: fileId,
          path: 'img.bin',
          blobRef: up.manifestHash,
          sizeBytes: original.length,
          hlc: Hlc(1000, 0, 'device-A'),
          chunks: up.chunkHashes,
        );

        await f.applier.apply(
          fileId,
          [await _record(f.codec, state, 1)],
          _UnusedResolver(),
        );

        expect(
          f.io.files.containsKey('$_vaultPath/img.bin'),
          isFalse,
          reason: 'download rejected the mismatched chunk (null) -> '
              'writeFileToDisk wrote nothing; no plain-path disk corruption',
        );
        expect(
          f.store.lastSyncedBlobRefFor(fileId),
          isNull,
          reason: 'not marked synced -> a later pull retries once the backend '
              'serves the correct chunk',
        );
      },
    );

    test(
      'corrupt chunk on remote (with cipher) -> GCM tag breaks decrypt, '
      'nothing written',
      () async {
        // E2EE blob path: EncryptedBlobStorage over the same backing.
        final backing = FakeBlobStorage();
        final cipher = VaultCipher.fromRawKey(Uint8List(32)); // fast, no Argon2
        final encRemote = EncryptedBlobStorage(inner: backing, cipher: cipher);
        final f = await _newApplier(encRemote);
        final fileId = _fileIdFor('img.bin');

        final original = _bytes('the authentic binary payload');
        final up = await _seedRemote(encRemote, original);

        // Tamper with the stored CIPHERTEXT of one chunk (flip a MAC byte).
        final ct = backing.store[up.chunkHashes.first]!;
        final tampered = Uint8List.fromList(ct);
        tampered[tampered.length - 1] ^= 0xFF; // breaks the AES-GCM auth tag
        backing.store[up.chunkHashes.first] = tampered;

        final state = FileState(
          fileId: fileId,
          path: 'img.bin',
          blobRef: up.manifestHash,
          sizeBytes: original.length,
          hlc: Hlc(1000, 0, 'device-A'),
          chunks: up.chunkHashes,
        );

        await f.applier.apply(
          fileId,
          [await _record(f.codec, state, 1)],
          _UnusedResolver(),
        );

        expect(
          f.io.files.containsKey('$_vaultPath/img.bin'),
          isFalse,
          reason: 'decrypt failed (GCM tag) -> download returned null -> '
              'nothing written; corruption cannot reach disk under E2EE',
        );
        expect(
          f.store.lastSyncedBlobRefFor(fileId),
          isNull,
          reason: 'not marked synced -> a later pull retries (no silent loss)',
        );
      },
    );

    test(
      'ChunkedBlobIO.download THROWS on a tampered ciphertext chunk '
      '(the protection is AES-GCM, not a content check)',
      () async {
        final backing = FakeBlobStorage();
        final cipher = VaultCipher.fromRawKey(Uint8List(32));
        final encRemote = EncryptedBlobStorage(inner: backing, cipher: cipher);

        final original = _bytes('secret note body');
        final up = await _seedRemote(encRemote, original);

        final ct = backing.store[up.chunkHashes.first]!;
        final tampered = Uint8List.fromList(ct);
        tampered[tampered.length - 1] ^= 0xFF;
        backing.store[up.chunkHashes.first] = tampered;

        final consumer = ChunkedBlobIO(
          blobStore: LocalBlobStore(InMemoryBlobRepository()),
          remoteBlobStorage: encRemote,
          vaultId: _vaultId,
        );

        await expectLater(
          () => consumer.download(up.manifestHash),
          throwsA(anything),
          reason: 'a tampered chunk under E2EE fails the AES-GCM MAC and '
              'raises — it is never silently assembled',
        );
      },
    );
  });
}

/// A resolver that must never run — the single-value apply path never touches
/// it, so any call means the test set up a spurious conflict.
class _UnusedResolver implements IStateConflictResolver {
  @override
  Future<StateMergeOutcome> resolve(
    List<FileState> values, {
    String? baseRef,
  }) async =>
      throw StateError('resolver must not run in the single-value path');
}
