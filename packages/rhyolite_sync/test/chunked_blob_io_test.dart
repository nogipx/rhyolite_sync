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
}
