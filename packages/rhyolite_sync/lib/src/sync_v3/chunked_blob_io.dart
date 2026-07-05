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
  }) async {
    final token = context?.cancellationToken;
    token?.throwIfCancelled();
    // Yield before the chunker — content-defined chunking is rolling
    // hash + sha256 over every byte, ~50-200ms for a ~1 MiB blob on
    // dart2js, fully synchronous. Without this yield N back-to-back
    // uploads keep the JS thread pinned and the Obsidian UI frozen
    // through the whole burst.
    await Future<void>.delayed(Duration.zero);
    final result = _chunker(bytes);
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
    // freshly content-addressed for this version, so always upload it
    // unless the exact same manifest already exists (very rare — same
    // content + same chunk layout).
    final toUpload = <(Uint8List, String)>[];
    for (final entry in chunkBytes.entries) {
      if (knownChunks.contains(entry.key)) continue;
      toUpload.add((entry.value, entry.key));
    }
    if (!knownChunks.contains(manifestHash)) {
      toUpload.add((manifestPlain, manifestHash));
    }

    if (toUpload.isNotEmpty) {
      token?.throwIfCancelled();
      await remoteBlobStorage.upload(toUpload, context: context);
    }

    return (manifestHash: manifestHash, chunkHashes: orderedHashes);
  }

  /// Fetch manifest by hash, fetch any chunks not in the local cache, and
  /// concatenate them in order. Returns null if anything cannot be
  /// retrieved or the result fails the size check.
  Future<Uint8List?> download(
    String manifestHash, {
    RpcContext? context,
  }) async {
    final token = context?.cancellationToken;
    token?.throwIfCancelled();
    var manifestPlain = await blobStore.read(manifestHash, vaultId: vaultId);
    if (manifestPlain == null) {
      final got = await remoteBlobStorage.download(
        [manifestHash],
        context: context,
      );
      manifestPlain = got[manifestHash];
      if (manifestPlain == null) return null;
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
    for (final ref in chunkRefs) {
      final bytes = await blobStore.read(ref.hash, vaultId: vaultId);
      if (bytes != null) {
        cached[ref.hash] = bytes;
      } else {
        missing.add(ref.hash);
      }
    }

    if (missing.isNotEmpty) {
      token?.throwIfCancelled();
      final downloaded = await remoteBlobStorage.download(
        missing,
        context: context,
      );
      for (final entry in downloaded.entries) {
        cached[entry.key] = entry.value;
        await blobStore.write(entry.value, entry.key, vaultId: vaultId);
      }
    }

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
