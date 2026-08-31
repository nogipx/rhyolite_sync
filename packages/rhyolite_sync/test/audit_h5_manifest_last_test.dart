// H5 — Manifest-last upload survives cancellation.
//
// ChunkedBlobIO.upload uploads every chunk FIRST and the manifest LAST, with a
// cancellation check between them. The invariants under test:
//   1. Cancel BETWEEN chunks and manifest -> the manifest is never on the
//      remote, so there is no dangling manifest pointing at (possibly) absent
//      chunks. A resume re-uploads ONLY the missing manifest (chunks dedup).
//   2. Cancel AFTER the manifest -> the blob is complete; another device can
//      assemble it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import 'support/fake_blob_storage.dart';

const _vaultId = '00000000-0000-4000-8000-0000000000a5';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

ChunkedBlobIO _io(IBlobStorage remote, [LocalBlobStore? local]) =>
    ChunkedBlobIO(
      blobStore: local ?? LocalBlobStore(InMemoryBlobRepository()),
      remoteBlobStorage: remote,
      vaultId: _vaultId,
    );

void main() {
  final content = _bytes('H5 manifest-last invariant — one chunk of content');

  group('H5 — manifest-last survives cancellation', () {
    test('cancel between chunks and manifest -> no dangling manifest; '
        'resume uploads only the manifest; then it downloads', () async {
      // Learn the deterministic hashes for this content up front.
      final refBacking = FakeBlobStorage();
      final ref = await _io(refBacking).upload(content, <String>{});
      final manifestHash = ref.manifestHash;
      final chunkHashes = ref.chunkHashes;
      expect(chunkHashes, isNotEmpty);

      // Fresh producer; cancel the moment a NON-manifest (chunk) batch lands.
      final backing = FakeBlobStorage();
      final local = LocalBlobStore(InMemoryBlobRepository());
      final io = _io(backing, local);
      final token = RpcCancellationToken();
      backing.afterUpload = (ids) {
        if (!ids.contains(manifestHash)) token.cancel('after chunk flush');
      };

      await expectLater(
        () => io.upload(
          content,
          <String>{},
          context: RpcContext.withCancellation(token),
        ),
        throwsA(isA<RpcCancelledException>()),
      );

      // Invariant 1: chunk durably uploaded, manifest NOT — no dangling ref.
      expect(
        backing.store.containsKey(chunkHashes.first),
        isTrue,
        reason: 'the chunk was flushed before the cancel',
      );
      expect(
        backing.store.containsKey(manifestHash),
        isFalse,
        reason:
            'the manifest is uploaded last and must be absent, so no '
            'manifest ever points at missing chunks',
      );

      // Resume: the caller now knows (via exists) the chunks are present.
      final known = await backing.exists(chunkHashes);
      backing.afterUpload = null;
      backing.uploadedBatches.clear();
      await io.upload(content, known);

      // Only the manifest is (re)sent — chunks are deduped away.
      expect(
        backing.uploadedBatches,
        hasLength(1),
        reason: 'resume should send exactly one batch',
      );
      expect(
        backing.uploadedBatches.single,
        [manifestHash],
        reason: 'and that batch is just the manifest',
      );
      expect(backing.store.containsKey(manifestHash), isTrue);

      // A fresh device (empty local cache) can now assemble it.
      final downloaded = await _io(backing).download(manifestHash);
      expect(downloaded, equals(content));
    });

    test('cancel AFTER the manifest -> upload completes and another device '
        'assembles the file', () async {
      final refBacking = FakeBlobStorage();
      final ref = await _io(refBacking).upload(content, <String>{});
      final manifestHash = ref.manifestHash;

      final backing = FakeBlobStorage();
      final io = _io(backing);
      final token = RpcCancellationToken();
      backing.afterUpload = (ids) {
        if (ids.contains(manifestHash)) token.cancel('after manifest');
      };

      // No throw: there is no cancellation checkpoint after the manifest.
      await io.upload(
        content,
        <String>{},
        context: RpcContext.withCancellation(token),
      );

      expect(backing.store.containsKey(manifestHash), isTrue);
      for (final c in ref.chunkHashes) {
        expect(backing.store.containsKey(c), isTrue);
      }

      final downloaded = await _io(backing).download(manifestHash);
      expect(
        downloaded,
        equals(content),
        reason:
            'a cancel after the manifest still leaves a complete, '
            'assemblable blob',
      );
    });
  });

  group('H5 — manifest-last holds across a batch upload', () {
    test('every chunk of every file precedes every manifest', () async {
      // uploadAll exists to stop paying two round trips per file. The saving
      // must not come out of the ordering: the tempting shortcut is to append
      // each manifest to its own chunk batch, which holds only because the
      // server writes a batch in stream order — an invariant the client can
      // see, moved into another repository. Two phases keep it here.
      final backing = FakeBlobStorage();
      final io = _io(backing);

      final results = await io.uploadAll([
        _bytes('first file, one chunk of content'),
        _bytes('second file, different content entirely'),
        _bytes('third file, also distinct'),
      ], <String>{});
      expect(results, hasLength(3));

      final order = backing.uploadedBatches.expand((b) => b).toList();
      final manifests = results.map((r) => r.manifestHash).toSet();
      final firstManifest = order.indexWhere(manifests.contains);
      expect(
        firstManifest,
        greaterThanOrEqualTo(0),
        reason: 'the manifests must actually have been sent',
      );

      for (final r in results) {
        for (final chunk in r.chunkHashes) {
          expect(
            order.indexOf(chunk),
            lessThan(firstManifest),
            reason:
                'every chunk of every file must be on the server before '
                'ANY manifest — otherwise a manifest can point at bytes '
                'nobody holds',
          );
        }
      }
    });

    test(
      'cancelling during the chunk phase sends no manifest at all',
      () async {
        final backing = FakeBlobStorage();
        final io = _io(backing);
        final token = RpcCancellationToken();
        backing.afterUpload = (_) => token.cancel('mid chunks');

        await expectLater(
          () => io.uploadAll(
            [_bytes('a' * 4000), _bytes('b' * 4000)],
            <String>{},
            context: RpcContext.withCancellation(token),
          ),
          throwsA(isA<RpcCancelledException>()),
        );

        // Whatever landed, none of it is a manifest: the phase that sends them
        // had not begun.
        final sentIds = backing.store.keys.toSet();
        final refIo = _io(FakeBlobStorage());
        final refs = await refIo.uploadAll([
          _bytes('a' * 4000),
          _bytes('b' * 4000),
        ], <String>{});
        for (final r in refs) {
          expect(
            sentIds.contains(r.manifestHash),
            isFalse,
            reason:
                'a manifest reached the server while the batch was still '
                'uploading chunks',
          );
        }
      },
    );
  });
}
