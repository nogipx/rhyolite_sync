import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:test/test.dart';

const _v = 'vault-keying-test';

/// In-memory remote treating blobs as opaque bytes (keyed by the id given).
class _MemRemote implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  @override
  Future<Set<String>> exists(List<String> ids, {RpcContext? context}) async =>
      {for (final id in ids) if (store.containsKey(id)) id};

  @override
  Future<void> upload(List<(Uint8List, String)> blobs, {RpcContext? context}) async {
    for (final (bytes, id) in blobs) {
      store[id] = bytes;
    }
  }

  @override
  Future<Map<String, Uint8List>> download(List<String> ids, {RpcContext? context}) async =>
      {for (final id in ids) if (store.containsKey(id)) id: store[id]!};

  @override
  Future<void> deleteMany(List<String> ids, {RpcContext? context}) async {
    for (final id in ids) {
      store.remove(id);
    }
  }
}

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List _varied(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = (i * 13 + 7) & 0xff;
  }
  return out;
}

void main() {
  group('VaultCipher.deriveBlobIdKey', () {
    test('deterministic, 32 bytes, key-separated from the AES key', () async {
      final c = await VaultCipher.derive('correct horse battery staple', 'vault-1');
      final k1 = c.deriveBlobIdKey();
      final k2 = c.deriveBlobIdKey();
      expect(k1.length, 32);
      expect(k1, k2, reason: 'derivation must be deterministic');
      expect(k1, isNot(c.rawKeyBytes),
          reason: 'blob-id key must not be the AES key itself');
    });

    test('differs across passphrase and across vault', () async {
      final a = (await VaultCipher.derive('pass-A', 'vault-1')).deriveBlobIdKey();
      final b = (await VaultCipher.derive('pass-B', 'vault-1')).deriveBlobIdKey();
      final c = (await VaultCipher.derive('pass-A', 'vault-2')).deriveBlobIdKey();
      expect(a, isNot(b), reason: 'different passphrase → different subkey');
      expect(a, isNot(c), reason: 'different vault → different subkey');
    });
  });

  group('keyed content-addressing', () {
    test('chunker with a keyed hasher yields HMAC ids, not sha256', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final data = _b('a small blob that stays a single chunk');

      final keyed = ContentDefinedChunker(
        blobIdHasher: (bytes) => Hmac(sha256, key).convert(bytes).toString(),
      );
      final plain = ContentDefinedChunker();

      final keyedHash = keyed(data).manifest.chunks.single.hash;
      final plainHash = plain(data).manifest.chunks.single.hash;

      expect(keyedHash, isNot(plainHash));
      expect(plainHash, sha256.convert(data).toString());
      expect(keyedHash, Hmac(sha256, key).convert(data).toString());
    });

    test('ChunkedBlobIO: keyed ids differ from unkeyed and still round-trip',
        () async {
      final key = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      ChunkedBlobIO make({Uint8List? k}) => ChunkedBlobIO(
            blobStore: LocalBlobStore(InMemoryBlobRepository()),
            remoteBlobStorage: _MemRemote(),
            vaultId: _v,
            blobIdKey: k,
          );

      final data = _varied(300);
      final keyed = await make(k: key).upload(data, {});
      final plain = await make().upload(data, {});

      expect(keyed.manifestHash, isNot(plain.manifestHash),
          reason: 'keyed manifest id must differ from the unkeyed sha256 id');
      expect(keyed.chunkHashes, isNot(plain.chunkHashes));

      // Full round-trip through one keyed instance.
      final io = make(k: key);
      final r = await io.upload(data, {});
      final back = await io.download(r.manifestHash);
      expect(back, isNotNull);
      expect(back!.toList(), data.toList());
    });

    test('within-vault dedup still works with a key (same content → same id)',
        () async {
      final key = Uint8List.fromList(List.generate(32, (i) => (i * 3) & 0xff));
      final io = ChunkedBlobIO(
        blobStore: LocalBlobStore(InMemoryBlobRepository()),
        remoteBlobStorage: _MemRemote(),
        vaultId: _v,
        blobIdKey: key,
      );
      final data = _varied(300);
      final first = await io.upload(data, {});
      final second = await io.upload(data, first.chunkHashes.toSet());
      expect(second.manifestHash, first.manifestHash,
          reason: 'identical content under the same key → identical id');
      expect(second.chunkHashes, first.chunkHashes);
    });
  });
}
