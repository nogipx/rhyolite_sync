// H1 (FIXED) — A downloaded chunk IS now verified against its content-address.
//
// ChunkedBlobIO.download re-hashes every chunk (and the manifest) against the
// id it was requested under before assembling:
//   * a chunk fetched from the remote that doesn't match -> dropped -> the
//     assembly fails safe (returns null) instead of yielding a corrupt file;
//   * a bit-rotted LOCAL cache entry -> evicted -> re-downloaded from the
//     remote -> the file self-heals.
//
// Fault-injection against the real ChunkedBlobIO via the IBlobStorage /
// LocalBlobStore seams — no source changes in the test.
import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:test/test.dart';

import 'support/fake_blob_storage.dart';

const _vaultId = '00000000-0000-4000-8000-0000000000a1';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

/// Same-length, guaranteed-different copy of [b].
Uint8List _flip(Uint8List b) {
  final out = Uint8List(b.length);
  for (var i = 0; i < b.length; i++) {
    out[i] = b[i] ^ 0xFF;
  }
  return out;
}

void main() {
  group('H1 — chunk verified against content-address', () {
    test(
      'remote returns wrong bytes of correct length -> download fails safe '
      '(null), never assembles garbage',
      () async {
        final backing = FakeBlobStorage();
        final producer = ChunkedBlobIO(
          blobStore: LocalBlobStore(InMemoryBlobRepository()),
          remoteBlobStorage: backing,
          vaultId: _vaultId,
        );

        final original = _bytes('the real secret content of this note');
        final up = await producer.upload(original, <String>{});
        expect(up.chunkHashes, isNotEmpty);

        // Corrupt one chunk on the remote: SAME length, different content.
        corruptSameLength(backing.store, up.chunkHashes.first);

        // Consumer with an EMPTY local cache is forced to fetch it.
        final consumer = ChunkedBlobIO(
          blobStore: LocalBlobStore(InMemoryBlobRepository()),
          remoteBlobStorage: backing,
          vaultId: _vaultId,
        );

        final result = await consumer.download(up.manifestHash);

        expect(
          result,
          isNull,
          reason: 'the mismatched chunk is rejected; assembly returns null '
              'rather than a silently-corrupt file',
        );
      },
    );

    test(
      'bit-rotted LOCAL cache entry is evicted and re-downloaded -> self-heals',
      () async {
        final backing = FakeBlobStorage();
        final local = LocalBlobStore(InMemoryBlobRepository());
        final io = ChunkedBlobIO(
          blobStore: local,
          remoteBlobStorage: backing,
          vaultId: _vaultId,
        );

        final original = _bytes('cached content that survives a bit flip');
        final up = await io.upload(original, <String>{});

        // Rot the cached chunk in place (same length). The remote still holds
        // the correct copy (the upload populated it too).
        final good = (await local.read(up.chunkHashes.first, vaultId: _vaultId))!;
        await local.write(_flip(good), up.chunkHashes.first, vaultId: _vaultId);

        final result = await io.download(up.manifestHash);

        expect(result, equals(original),
            reason: 'the corrupt cache entry was evicted and re-fetched from '
                'the remote — the file heals');
        expect(backing.downloadCalls, greaterThan(0),
            reason: 'healing required a re-download, not a cache hit');
        // The cache is repaired for next time.
        expect(
          await local.read(up.chunkHashes.first, vaultId: _vaultId),
          equals(good),
          reason: 'the good chunk is written back to the cache',
        );
      },
    );

    test(
      'bit-rotted LOCAL cache AND unreachable remote -> fails safe (null)',
      () async {
        // Evicting a rotted entry cannot heal if the remote no longer has it —
        // the correct outcome is a clean null, never the rotted bytes.
        final backing = FakeBlobStorage();
        final local = LocalBlobStore(InMemoryBlobRepository());
        final io = ChunkedBlobIO(
          blobStore: local,
          remoteBlobStorage: backing,
          vaultId: _vaultId,
        );

        final original = _bytes('content whose remote copy will be dropped');
        final up = await io.upload(original, <String>{});

        // Rot the cache AND remove the remote copy.
        final good = (await local.read(up.chunkHashes.first, vaultId: _vaultId))!;
        await local.write(_flip(good), up.chunkHashes.first, vaultId: _vaultId);
        backing.store.remove(up.chunkHashes.first);

        final result = await io.download(up.manifestHash);
        expect(result, isNull,
            reason: 'no clean source -> null, never the rotted bytes');
      },
    );
  });
}
