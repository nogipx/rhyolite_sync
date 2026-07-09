// H3 — The engine has NO defense against a torn (truncated) disk write; that
// guarantee must come from the IPlatformIO implementation.
//
// This test injects a truncating IPlatformIO and drives the real DiskReconciler
// to capture the worst case: a torn file is not only left on disk, it is then
// read back by the next reconcile and becomes the new authoritative version —
// i.e. the truncated content would be pushed to the server as a fresh edit.
//
// FIX: the write must be atomic at the IO layer. FilesystemIO.writeFile now
// writes a flushed sibling temp and renames it over the target (rename(2) is
// atomic), so this failure mode is unreachable through the real CLI IO — see
// rhyolite_client_filesystem/test/filesystem_io_atomic_test.dart. This engine
// test remains as the guard for WHY the IO contract must be atomic; ObsidianIO
// writes through Obsidian's own Vault API and still needs a plugin-tested fix.
import 'dart:typed_data';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/sync_v3/disk_reconciler.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'support/fake_blob_storage.dart';
import 'support/fake_change_provider.dart';
import 'support/fake_platform_io.dart';

const _vaultPath = '/vault';
const _vaultId = '00000000-0000-4000-8000-0000000000a3';

String _fileIdFor(String relPath) => const Uuid().v5(_vaultId, relPath);

typedef _Fx = ({
  DiskReconciler reconciler,
  FileStateStore store,
  PartialWriteIO io,
  ChunkedBlobIO Function() builder,
});

Future<_Fx> _newReconciler(int truncateAt) async {
  final env = await DataServiceFactory.inMemory();
  addTearDown(env.dispose);
  final store = FileStateStore(client: env.client, vaultId: _vaultId);
  await store.load();
  final fugueStore = FugueStore(client: env.client, vaultId: _vaultId);
  await fugueStore.load();

  final io = PartialWriteIO(truncateAt);
  final appLocal = LocalBlobStore(InMemoryBlobRepository());
  final backing = FakeBlobStorage();

  ChunkedBlobIO builder() => ChunkedBlobIO(
        blobStore: appLocal,
        remoteBlobStorage: backing,
        vaultId: _vaultId,
      );

  final reconciler = DiskReconciler(
    vaultPath: _vaultPath,
    vaultId: _vaultId,
    io: io,
    blobStore: appLocal,
    changeProvider: NoopChangeProvider(),
    store: store,
    fugueStore: fugueStore,
    chunkedIOBuilder: builder,
    knownChunks: () => {for (final s in store.allValuesFlat) ...s.chunks},
    fileIdFor: _fileIdFor,
    emit: (_) {},
  );

  return (reconciler: reconciler, store: store, io: io, builder: builder);
}

void main() {
  group('H3 — non-atomic write leaves a truncated file that then propagates',
      () {
    test(
      'crash mid-write -> truncated file stays on disk AND becomes the new '
      'version the next reconcile would push',
      () async {
        const truncateAt = 500;
        final f = await _newReconciler(truncateAt);
        final fileId = _fileIdFor('big.bin');

        // Correct content (single chunk, well under the min chunk size).
        final original =
            Uint8List.fromList(List<int>.generate(2000, (i) => (i * 7) & 0xFF));
        final up = await f.builder().upload(original, <String>{});

        // The register already knows the correct version (as after a pull that
        // decoded the record but before the disk write lands).
        final correct = FileState(
          fileId: fileId,
          path: 'big.bin',
          blobRef: up.manifestHash,
          sizeBytes: original.length,
          hlc: Hlc(1000, 0, 'device-A'),
          chunks: up.chunkHashes,
        );
        f.store.applyLocal(correct);
        await f.store.persistOne(fileId);

        // The disk write is interrupted after `truncateAt` bytes.
        await expectLater(
          () => f.reconciler.writeFileToDisk(correct),
          throwsA(isA<StateError>()),
          reason: 'the non-atomic write surfaces the crash',
        );

        // (a) A truncated file is left on disk — not absent, not whole.
        final onDisk = f.io.files['$_vaultPath/big.bin'];
        expect(onDisk, isNotNull,
            reason: 'a tmp+rename write would have left NO partial file');
        expect(onDisk!.length, truncateAt,
            reason: 'exactly the bytes written before the crash remain');
        expect(onDisk, equals(original.sublist(0, truncateAt)),
            reason: 'it is a genuine prefix — a torn write');

        // (b) The next reconcile reads the truncated file back and treats it as
        // a local edit: the truncated content becomes the tracked version.
        f.io.armed = false; // let the (small) re-upload of truncated bytes pass
        final changed = await f.reconciler.reconcileWithDisk('big.bin');
        expect(changed, isTrue,
            reason: 'truncated disk content diverges from the store -> '
                'a push-worthy mutation');

        final tracked = f.store.get(fileId)!;
        expect(tracked.sizeBytes, truncateAt,
            reason: 'the truncated size is now the authoritative version');
        expect(tracked.blobRef, isNot(up.manifestHash),
            reason: 'it no longer references the correct blob — the torn '
                'version would be uploaded to the server as a new edit');
      },
    );
  });
}
