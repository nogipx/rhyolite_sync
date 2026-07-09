import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Stores file content as a content-defined-chunked manifest.
///
/// Why: large binary files (PDFs, attachments) edited slightly should not
/// re-upload the whole blob. CDC splits a file into ~1 MiB chunks at
/// content-defined boundaries; a small edit changes one or two chunks,
/// the rest are reused. Small files fall under the min chunk size and
/// always come out as a single chunk, so the same code path handles
/// notes and large binaries uniformly.
///
/// Storage layout: each chunk and each manifest are independent blobs.
/// LocalBlobStore holds plain bytes; the remote IBlobStorage is expected
/// to be EncryptedBlobStorage (or compatible) — it encrypts at upload
/// and decrypts at download. All ids are sha256 of the PLAIN content.
///
/// `FileState.blobRef` points to the manifest. `FileState.chunks` is a
/// plain list of chunk hashes (server uses it for blob GC).
///
/// Blob ids are `HMAC-SHA256(blobIdKey, plainContent)` when a [blobIdKey] is
/// supplied (the engine derives it per-vault via [VaultCipher.deriveBlobIdKey]),
/// otherwise a raw `sha256`. Keying prevents a storage operator from confirming
/// possession of a known file by recomputing its plaintext hashes; within-vault
/// dedup is unchanged since the key is stable across a vault's devices.
class ChunkedBlobIO {
  ChunkedBlobIO({
    required this.blobStore,
    required this.remoteBlobStorage,
    required this.vaultId,
    Uint8List? blobIdKey,
    ContentDefinedChunker? chunker,
  })  : _hasher = hasherFor(blobIdKey),
        _chunker =
            chunker ?? ContentDefinedChunker(blobIdHasher: hasherFor(blobIdKey));

  final LocalBlobStore blobStore;
  final IBlobStorage remoteBlobStorage;
  final String vaultId;
  final ContentDefinedChunker _chunker;

  /// Content-address function for the manifest blob; the chunker uses an
  /// equivalent one for chunk ids. Keyed HMAC when a vault subkey is present.
  final String Function(Uint8List) _hasher;

  /// Builds the content-address function for a vault: keyed `HMAC-SHA256`
  /// when [blobIdKey] is present, else a raw `sha256`. Exposed so the startup
  /// diff hashes disk content with the SAME scheme its blobs were stored under
  /// — a mismatch makes every file look changed and re-upload every startup.
  static String Function(Uint8List) hasherFor(Uint8List? blobIdKey) =>
      blobIdKey == null
          ? ((b) => sha256.convert(b).toString())
          : ((b) => Hmac(sha256, blobIdKey).convert(b).toString());

  /// Chunk the file, upload missing chunks + manifest, mirror everything
  /// into the local cache. Returns (manifestHash, ordered chunk hashes).
  ///
  /// [knownChunks] is the set of chunk hashes the caller knows are already
  /// on the server (typically derived from `union(file_state.chunks)`).
  /// Anything in that set is not re-uploaded. The local cache is always
  /// written so subsequent operations find the bytes instantly.
  Future<({String manifestHash, List<String> chunkHashes})> upload(
    Uint8List bytes,
    Set<String> knownChunks, {
    RpcContext? context,
    void Function(int sent, int total)? onProgress,
  }) async {
    final token = context?.cancellationToken;
    token?.throwIfCancelled();
    // Yield before the chunker — content-defined chunking is rolling
    // hash + sha256 over every byte, ~50-200ms for a ~1 MiB blob on
    // dart2js, fully synchronous. Without this yield N back-to-back
    // uploads keep the JS thread pinned and the Obsidian UI frozen
    // through the whole burst.
    final result = await _chunker(bytes);
    final manifest = result.manifest;
    final chunkBytes = result.chunks;
    final orderedHashes = manifest.chunks
        .map((c) => c.hash)
        .toList(growable: false);

    final manifestJson = jsonEncode({
      'v': 1,
      'size': manifest.totalSize,
      'chunks': manifest.chunks.map((c) => {'h': c.hash, 's': c.size}).toList(),
    });
    final manifestPlain = Uint8List.fromList(utf8.encode(manifestJson));
    final manifestHash = _hasher(manifestPlain);

    token?.throwIfCancelled();
    // Local cache mirrors everything in plain — same as the legacy
    // single-blob path. Future reads of the same file (own device)
    // never need a remote roundtrip.
    for (final entry in chunkBytes.entries) {
      await blobStore.write(entry.value, entry.key, vaultId: vaultId);
    }
    await blobStore.write(manifestPlain, manifestHash, vaultId: vaultId);

    // Upload only chunks the server hasn't already got. The manifest is
    // uploaded LAST (after every chunk it references is on the server) so a
    // partial upload can never leave a manifest pointing at absent chunks.
    final total = manifest.totalSize;
    final chunksToUpload = <(Uint8List, String)>[];
    var done = 0;
    for (final c in manifest.chunks) {
      if (knownChunks.contains(c.hash)) {
        done += c.size; // already on the server (dedup) — counts instantly
      } else {
        chunksToUpload.add((chunkBytes[c.hash]!, c.hash));
      }
    }
    onProgress?.call(done > total ? total : done, total);

    // Chunks in byte-bounded batches so a large file reports moving progress
    // instead of jumping 0→100 after one giant call. Each batch is a complete,
    // content-addressed, idempotent upload — splitting is safe.
    const batchLimitBytes = 2 * 1024 * 1024;
    final sizeOf = {for (final c in manifest.chunks) c.hash: c.size};
    var batch = <(Uint8List, String)>[];
    var batchWire = 0;
    var batchContent = 0;
    Future<void> flush() async {
      if (batch.isEmpty) return;
      token?.throwIfCancelled();
      await remoteBlobStorage.upload(batch, context: context);
      done += batchContent;
      onProgress?.call(done > total ? total : done, total);
      batch = <(Uint8List, String)>[];
      batchWire = 0;
      batchContent = 0;
    }

    for (final (bytes, id) in chunksToUpload) {
      batch.add((bytes, id));
      batchWire += bytes.length;
      batchContent += sizeOf[id] ?? bytes.length;
      if (batchWire >= batchLimitBytes) await flush();
    }
    await flush();

    if (!knownChunks.contains(manifestHash)) {
      token?.throwIfCancelled();
      await remoteBlobStorage.upload(
        [(manifestPlain, manifestHash)],
        context: context,
      );
    }
    onProgress?.call(total, total);

    return (manifestHash: manifestHash, chunkHashes: orderedHashes);
  }

  /// Fetch manifest by hash, fetch any chunks not in the local cache, and
  /// concatenate them in order. Returns null if anything cannot be
  /// retrieved or the result fails the size check.
  Future<Uint8List?> download(
    String manifestHash, {
    RpcContext? context,
    void Function(int sent, int total)? onProgress,
  }) async {
    final token = context?.cancellationToken;
    token?.throwIfCancelled();
    var manifestPlain = await blobStore.read(manifestHash, vaultId: vaultId);
    // A cached manifest that no longer content-addresses to its id is corrupt
    // (bit-rot; the plain-byte cache has no MAC). Evict it and re-fetch.
    if (manifestPlain != null && _hasher(manifestPlain) != manifestHash) {
      await blobStore.deleteBlobs([manifestHash], vaultId: vaultId);
      manifestPlain = null;
    }
    if (manifestPlain == null) {
      final got = await remoteBlobStorage.download(
        [manifestHash],
        context: context,
      );
      manifestPlain = got[manifestHash];
      if (manifestPlain == null) return null;
      // A backend that returns the wrong bytes for a content-addressed id is
      // corrupt or hostile — reject rather than parse garbage as a manifest.
      if (_hasher(manifestPlain) != manifestHash) return null;
      await blobStore.write(manifestPlain, manifestHash, vaultId: vaultId);
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(manifestPlain)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final chunksJson = (json['chunks'] as List?) ?? const [];
    final size = (json['size'] as int?) ?? 0;
    final chunkRefs = chunksJson.map((e) {
      final m = e as Map<String, dynamic>;
      return (hash: m['h'] as String, size: (m['s'] as int?) ?? 0);
    }).toList();

    final cached = <String, Uint8List>{};
    final missing = <String>[];
    var localBytes = 0;
    var verifiedSinceYield = 0;
    for (final ref in chunkRefs) {
      final bytes = await blobStore.read(ref.hash, vaultId: vaultId);
      // Verify every cached chunk against its content-address. The local cache
      // holds PLAIN bytes, so the E2EE MAC never covers it — a bit-rotted entry
      // would otherwise be assembled into the file silently. A mismatch is
      // treated as a miss: evict the bad copy so the re-download below heals it.
      if (bytes != null && _hasher(bytes) == ref.hash) {
        cached[ref.hash] = bytes;
        localBytes += ref.size;
      } else {
        if (bytes != null) {
          await blobStore.deleteBlobs([ref.hash], vaultId: vaultId);
        }
        missing.add(ref.hash);
      }
      // Hashing every chunk is O(bytes); yield periodically so a many-chunk
      // download doesn't pin the dart2js main thread (mirrors the chunker).
      if (++verifiedSinceYield >= 16) {
        verifiedSinceYield = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    // Chunks already in the local cache count instantly; fetch the rest in
    // byte-bounded batches so a large file reports moving progress.
    onProgress?.call(localBytes > size ? size : localBytes, size);

    if (missing.isNotEmpty) {
      final sizeOf = {for (final ref in chunkRefs) ref.hash: ref.size};
      const batchLimitBytes = 2 * 1024 * 1024;
      var batch = <String>[];
      var batchBytes = 0;
      Future<void> fetch() async {
        if (batch.isEmpty) return;
        token?.throwIfCancelled();
        final downloaded = await remoteBlobStorage.download(
          batch,
          context: context,
        );
        for (final entry in downloaded.entries) {
          // Verify the fetched chunk against the id we asked for. A mismatch
          // means the backend returned the wrong bytes — drop it (leaving the
          // chunk absent, so assembly returns null) instead of caching and
          // assembling corruption.
          if (_hasher(entry.value) != entry.key) continue;
          cached[entry.key] = entry.value;
          await blobStore.write(entry.value, entry.key, vaultId: vaultId);
          localBytes += sizeOf[entry.key] ?? entry.value.length;
        }
        onProgress?.call(localBytes > size ? size : localBytes, size);
        batch = <String>[];
        batchBytes = 0;
      }

      for (final h in missing) {
        batch.add(h);
        batchBytes += sizeOf[h] ?? 0;
        if (batchBytes >= batchLimitBytes) await fetch();
      }
      await fetch();
    }
    onProgress?.call(size, size);

    final builder = BytesBuilder(copy: false);
    for (final ref in chunkRefs) {
      final bytes = cached[ref.hash];
      if (bytes == null) return null;
      builder.add(bytes);
    }
    final out = builder.takeBytes();
    if (out.length != size) return null;
    return out;
  }
}
