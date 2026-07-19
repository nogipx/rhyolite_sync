import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:test/test.dart';

const _v = 'vault-test';

/// In-memory IBlobStorage standing in for an encrypted remote. Treats
/// blobs as plain bytes — the chunked path doesn't double-encrypt.
class _MemRemote implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  @override
  Future<Set<String>> exists(List<String> blobIds, {RpcContext? context}) async =>
      {for (final id in blobIds) if (store.containsKey(id)) id};
  int uploadCount = 0;

  @override
  Future<void> upload(List<(Uint8List, String)> blobs, {RpcContext? context}) async {
    for (final (bytes, id) in blobs) {
      store[id] = bytes;
      uploadCount++;
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

Uint8List _bytes(String s) =>
    Uint8List.fromList(List<int>.generate(s.length, (i) => s.codeUnitAt(i)));

void main() {
  late LocalBlobStore local;
  late _MemRemote remote;
  late ChunkedBlobIO io;

  setUp(() {
    local = LocalBlobStore(InMemoryBlobRepository());
    remote = _MemRemote();
    io = ChunkedBlobIO(
      blobStore: local,
      remoteBlobStorage: remote,
      vaultId: _v,
      // Tiny chunks so even small test inputs split into multiple parts.
      chunker: ContentDefinedChunker(
        minChunkSize: 64,
        avgChunkSize: 128,
        maxChunkSize: 256,
      ),
    );
  });

  test('roundtrips small file as a single chunk', () async {
    final original = _bytes('hello world');
    final result = await io.upload(original, {});
    expect(result.chunkHashes.length, 1);

    final downloaded = await io.download(result.manifestHash);
    expect(downloaded, isNotNull);
    expect(downloaded!.toList(), original.toList());
  });

  test('roundtrips a larger file as multiple chunks', () async {
    // Produce ~1 KiB of varied bytes so the chunker actually splits.
    final original = Uint8List(1024);
    for (var i = 0; i < original.length; i++) {
      original[i] = (i * 17 + 11) & 0xff;
    }
    final result = await io.upload(original, {});
    expect(result.chunkHashes.length, greaterThan(1));

    final downloaded = await io.download(result.manifestHash);
    expect(downloaded, isNotNull);
    expect(downloaded!.toList(), original.toList());
  });

  test('skips re-uploading chunks the server already has', () async {
    final original = Uint8List(1024);
    for (var i = 0; i < original.length; i++) {
      original[i] = i & 0xff;
    }
    final first = await io.upload(original, {});
    final uploadsAfterFirst = remote.uploadCount;

    // Pretend the caller passes back the known chunk set on the second
    // upload (simulating "same file edited but no actual change").
    final knownChunks = first.chunkHashes.toSet();

    // Track a second upload to confirm dedup.
    remote.uploadCount = 0;
    final second = await io.upload(original, knownChunks);
    expect(second.manifestHash, first.manifestHash);
    expect(
      remote.uploadCount,
      lessThan(uploadsAfterFirst),
      reason:
          'all chunks already known → only manifest should be uploaded '
          '(or nothing if manifest hash was already in known set)',
    );
  });

  test('incremental edit re-uploads only changed chunk(s)', () async {
    final original = Uint8List(2048);
    for (var i = 0; i < original.length; i++) {
      original[i] = (i * 31) & 0xff;
    }
    final v1 = await io.upload(original, {});

    // Mutate one byte in the middle.
    final modified = Uint8List.fromList(original);
    modified[1024] = (modified[1024] + 1) & 0xff;

    remote.uploadCount = 0;
    final knownChunks = v1.chunkHashes.toSet();
    final v2 = await io.upload(modified, knownChunks);

    // Some chunks before AND after the edit boundary survive; only one
    // (the chunk containing the changed byte) needs uploading. Plus one
    // upload for the new manifest.
    final reused = v2.chunkHashes.where(knownChunks.contains).length;
    expect(
      reused,
      greaterThan(0),
      reason: 'most chunks must be reused after a 1-byte edit',
    );
    expect(
      remote.uploadCount,
      lessThan(v2.chunkHashes.length + 1),
      reason: 'a few new chunks + 1 new manifest, much less than full file',
    );

    final downloaded = await io.download(v2.manifestHash);
    expect(downloaded!.toList(), modified.toList());
  });

  test('download returns null when manifest is missing', () async {
    final result = await io.download('nonexistent');
    expect(result, isNull);
  });

  test('download repopulates local cache for missing chunks', () async {
    final original = Uint8List(512);
    for (var i = 0; i < original.length; i++) {
      original[i] = (i * 7) & 0xff;
    }
    final result = await io.upload(original, {});

    // Clear the local cache to force fetch-from-remote.
    for (final h in [...result.chunkHashes, result.manifestHash]) {
      await local.deleteBlobs([h], vaultId: _v);
    }

    final downloaded = await io.download(result.manifestHash);
    expect(downloaded, isNotNull);
    expect(downloaded!.toList(), original.toList());

    // After download, the cache should be repopulated.
    final cached = await local.read(result.manifestHash, vaultId: _v);
    expect(cached, isNotNull);
  });

  test('onProgress reports completion for upload and download', () async {
    final original = Uint8List(1024);
    for (var i = 0; i < original.length; i++) {
      original[i] = (i * 17 + 11) & 0xff;
    }

    final up = <(int, int)>[];
    final result =
        await io.upload(original, {}, onProgress: (s, t) => up.add((s, t)));
    expect(up, isNotEmpty);
    // Total is always the content size; the final report is 100%.
    expect(up.every((e) => e.$2 == original.length), isTrue);
    expect(up.last, (original.length, original.length));

    // Fresh cache → download must fetch from remote and end at full size.
    final freshLocal = LocalBlobStore(InMemoryBlobRepository());
    final io2 = ChunkedBlobIO(
      blobStore: freshLocal,
      remoteBlobStorage: remote,
      vaultId: _v,
    );
    final down = <(int, int)>[];
    final got = await io2.download(result.manifestHash,
        onProgress: (s, t) => down.add((s, t)));
    expect(got, isNotNull);
    expect(down, isNotEmpty);
    expect(down.last, (original.length, original.length));
  });

  test('onProgress advances across batches for a multi-MiB upload/download',
      () async {
    // Default ~1 MiB chunker + 5 MiB of varied data → several 2 MiB upload
    // batches, so progress must report intermediate values (the bar moves).
    final remote2 = _MemRemote();
    final io2 = ChunkedBlobIO(
      blobStore: LocalBlobStore(InMemoryBlobRepository()),
      remoteBlobStorage: remote2,
      vaultId: _v,
    );
    final big = Uint8List(5 * 1024 * 1024);
    for (var i = 0; i < big.length; i++) {
      big[i] = (i * 2654435761 >> 13) & 0xff; // pseudo-random, splits well
    }

    final up = <int>[];
    final res = await io2.upload(big, {}, onProgress: (s, _) => up.add(s));
    expect(up.where((s) => s > 0 && s < big.length), isNotEmpty,
        reason: 'upload must report intermediate progress, not just 0 → done');
    expect(up.last, big.length);

    // Fresh cache download must also step through.
    final io3 = ChunkedBlobIO(
      blobStore: LocalBlobStore(InMemoryBlobRepository()),
      remoteBlobStorage: remote2,
      vaultId: _v,
    );
    final down = <int>[];
    final got =
        await io3.download(res.manifestHash, onProgress: (s, _) => down.add(s));
    expect(got!.length, big.length);
    expect(down.where((s) => s > 0 && s < big.length), isNotEmpty,
        reason: 'download must report intermediate progress');
    expect(down.last, big.length);
  });

  group('maxDownloadBytes (M5 — download size admission)', () {
    ChunkedBlobIO _capped(int max) => ChunkedBlobIO(
          blobStore: local,
          remoteBlobStorage: remote,
          vaultId: _v,
          maxDownloadBytes: max,
          chunker: ContentDefinedChunker(
            minChunkSize: 64,
            avgChunkSize: 128,
            maxChunkSize: 256,
          ),
        );

    test('rejects a blob whose declared size exceeds the cap', () async {
      final content = _bytes('x' * 4000); // spans many tiny chunks
      final up = await io.upload(content, {}); // uncapped upload
      final got = await _capped(500).download(up.manifestHash);
      expect(got, isNull,
          reason: 'an oversized blob must not be assembled into memory');
    });

    test('a blob within the cap still downloads intact', () async {
      final content = _bytes('hello world, still within the cap');
      final up = await io.upload(content, {});
      final got = await _capped(1 << 20).download(up.manifestHash);
      expect(got, isNotNull);
      expect(got!.toList(), content.toList());
    });

    test('no cap (null) downloads any size', () async {
      final content = _bytes('y' * 4000);
      final up = await io.upload(content, {});
      final got = await io.download(up.manifestHash); // io has no cap
      expect(got, isNotNull);
      expect(got!.length, content.length);
    });
  });
}
