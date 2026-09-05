import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rhyolite_core/rhyolite_core.dart';

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
/// and decrypts at download. Blob ids are keyed `HMAC-SHA256(vault subkey,
/// plain content)` when a [blobIdKey] is supplied (raw `sha256` only as a
/// test/keyless fallback) — see the class-doc note below on keying.
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
    this.maxDownloadBytes,
    this.staging,
  }) : _hasher = hasherFor(blobIdKey),
       _chunker =
           chunker ?? ContentDefinedChunker(blobIdHasher: hasherFor(blobIdKey));

  final LocalBlobStore blobStore;
  final IBlobStorage remoteBlobStorage;
  final String vaultId;
  final ContentDefinedChunker _chunker;

  /// Optional ceiling (plain bytes) on what [download] will assemble. A peer
  /// holding the vault key could store a many-chunk manifest whose assembled
  /// size is multiple GiB; without a cap a pull would fetch it all into memory
  /// and OOM the (small-heap, dart2js) client. The upload path is already
  /// size-gated; this mirrors that on download. Null = no cap (offline/tests).
  final int? maxDownloadBytes;

  /// Where a pull's in-transit chunks live instead of the database.
  ///
  /// When present it REPLACES the local blob cache for writes: nothing this
  /// instance fetches is persisted. Reads still fall back to the cache, so a
  /// chunk an older build left there is used rather than refetched.
  ///
  /// Null everywhere except the pull — the upload path stopped mirroring long
  /// ago, and a caller that genuinely wants a durable copy (settings sync,
  /// version viewer) still gets one.
  final BlobStaging? staging;

  /// The cached bytes for [hash], from staging first and the database after.
  Future<Uint8List?> _readCached(String hash) async {
    final staged = staging?.read(hash);
    if (staged != null) return staged;
    return blobStore.read(hash, vaultId: vaultId);
  }

  /// Keeps [bytes] where this instance's reads will find them again.
  ///
  /// The whole point of the staging path: during a pull this is a map
  /// assignment rather than a database write, and the database write was the
  /// gigabyte that stopped the queue from ever draining.
  Future<void> _writeCached(Uint8List bytes, String hash) async {
    final stage = staging;
    if (stage != null) {
      stage.write(hash, bytes);
      return;
    }
    await blobStore.write(bytes, hash, vaultId: vaultId);
  }

  /// Evicts a corrupt entry. Staging is written only from verified bytes, so
  /// this only ever concerns the durable cache.
  Future<void> _evictCached(String hash) async {
    if (staging != null) return;
    await blobStore.deleteBlobs([hash], vaultId: vaultId);
  }

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
    final built = await _build(bytes);
    final manifest = built.manifest;
    final chunkBytes = built.chunkBytes;
    final orderedHashes = built.orderedHashes;
    final manifestPlain = built.manifestPlain;
    final manifestHash = built.manifestHash;

    token?.throwIfCancelled();
    // NOTHING is mirrored into the local cache any more — see the class doc.
    //
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
      await remoteBlobStorage.upload([
        (manifestPlain, manifestHash),
      ], context: context);
    }
    onProgress?.call(total, total);

    return (manifestHash: manifestHash, chunkHashes: orderedHashes);
  }

  /// Uploads several files in a bounded number of round trips instead of two
  /// per file, without weakening manifest-last.
  ///
  /// [upload] costs a call for a file's chunks and another for its manifest,
  /// and the startup path — the one a whole-vault re-upload takes — called it
  /// once per file. 251 files meant 502 requests, four in flight, and on a
  /// latency-bound link that is what the wait is made of.
  ///
  /// The ordering is kept on THIS side, and made stricter rather than weaker:
  /// every chunk of every file in the batch goes up before any manifest does.
  /// A manifest visible while a chunk it names is absent is the silent-loss
  /// failure (audit H5), and the tempting shortcut — appending the manifest to
  /// its own chunk batch — would hold only because the server happens to write
  /// a batch in stream order. That moves an invariant the client can see into
  /// one file in another repository, where parallelising blob writes would
  /// break it silently. Two phases keep it here.
  ///
  /// Cancellation stays safe in both phases: cut during the chunks, no
  /// manifest was sent at all; cut during the manifests, every chunk is
  /// already up. Nothing published points at anything missing.
  Future<List<({String manifestHash, List<String> chunkHashes})>> uploadAll(
    List<Uint8List> files,
    Set<String> knownChunks, {
    RpcContext? context,
    void Function(int fileIndex, int sent, int total)? onFileProgress,
  }) async {
    final token = context?.cancellationToken;
    token?.throwIfCancelled();
    if (files.isEmpty) return const [];

    // --- build (CPU: rolling hash + sha256 over every byte) --------------
    final built =
        <
          ({
            BlobManifest manifest,
            Map<String, Uint8List> chunkBytes,
            List<String> orderedHashes,
            Uint8List manifestPlain,
            String manifestHash,
          })
        >[];
    for (final bytes in files) {
      token?.throwIfCancelled();
      built.add(await _build(bytes));
    }

    // --- phase 1: every chunk of every file ------------------------------
    const batchLimitBytes = 2 * 1024 * 1024;
    final sent = List<int>.filled(built.length, 0);
    void report(int i) => onFileProgress?.call(
      i,
      sent[i] > built[i].manifest.totalSize
          ? built[i].manifest.totalSize
          : sent[i],
      built[i].manifest.totalSize,
    );

    // Deduped across the batch: two files sharing a chunk send it once.
    final queued = <String>{};
    var batch = <(Uint8List, String)>[];
    var batchWire = 0;
    // Which files to re-report after a flush, and by how much.
    var pendingCredit = <int, int>{};
    Future<void> flush() async {
      if (batch.isEmpty) return;
      token?.throwIfCancelled();
      await remoteBlobStorage.upload(batch, context: context);
      pendingCredit.forEach((i, bytes) {
        sent[i] += bytes;
        report(i);
      });
      batch = <(Uint8List, String)>[];
      batchWire = 0;
      pendingCredit = <int, int>{};
    }

    for (var i = 0; i < built.length; i++) {
      final b = built[i];
      for (final c in b.manifest.chunks) {
        if (knownChunks.contains(c.hash) || queued.contains(c.hash)) {
          // Already on the server, or already in this batch for another file:
          // counts instantly, exactly as the per-file path credits dedup.
          sent[i] += c.size;
          continue;
        }
        queued.add(c.hash);
        batch.add((b.chunkBytes[c.hash]!, c.hash));
        batchWire += c.size;
        pendingCredit[i] = (pendingCredit[i] ?? 0) + c.size;
        if (batchWire >= batchLimitBytes) await flush();
      }
      report(i);
    }
    await flush();

    // --- phase 2: the manifests, once every chunk is up ------------------
    var manifests = <(Uint8List, String)>[];
    var manifestWire = 0;
    Future<void> flushManifests() async {
      if (manifests.isEmpty) return;
      token?.throwIfCancelled();
      await remoteBlobStorage.upload(manifests, context: context);
      manifests = <(Uint8List, String)>[];
      manifestWire = 0;
    }

    for (final b in built) {
      if (knownChunks.contains(b.manifestHash)) continue;
      manifests.add((b.manifestPlain, b.manifestHash));
      manifestWire += b.manifestPlain.length;
      if (manifestWire >= batchLimitBytes) await flushManifests();
    }
    await flushManifests();

    for (var i = 0; i < built.length; i++) {
      sent[i] = built[i].manifest.totalSize;
      report(i);
    }
    return [
      for (final b in built)
        (manifestHash: b.manifestHash, chunkHashes: b.orderedHashes),
    ];
  }

  /// Warms the local cache for several files with a bounded number of round
  /// trips, instead of two per file.
  ///
  /// [download] costs two SEQUENTIAL round trips — one for the manifest, then
  /// one for the chunks it names — and the puller called it once per file. On
  /// a latency-bound link that is the dominant cost of a pull: 207 files meant
  /// 414 round trips, four in flight, against a server ~250 ms away — 39 s of
  /// prefetch for 8 s of actual apply.
  ///
  /// Here it is two round trips per CALL: every uncached manifest in one
  /// request, then every missing chunk across ALL of those files in
  /// byte-bounded requests. Chunks shared between files are fetched once.
  ///
  /// Deliberately does NOT assemble. Prefetch through [download] decrypted,
  /// concatenated and length-checked each whole file — and the caller then
  /// dropped the bytes, only for the applier to assemble the same file again
  /// from cache moments later. Warming the cache is all this owes anyone.
  ///
  /// Best-effort per file: a manifest that is absent, corrupt or oversized is
  /// skipped rather than failing its neighbours, leaving that one file to the
  /// applier's own [download] — which refetches and can fail honestly.
  Future<void> prefetchAll(
    List<String> manifestHashes, {
    RpcContext? context,

    /// Reports a file's transfer as its chunks land, keyed by manifest hash.
    ///
    /// Without it a pull is silent about WHAT it is moving: the applier used
    /// to do the downloading and knew the path, but now the cache is warm by
    /// the time it runs, so nothing narrates the minutes spent on a large
    /// attachment. From the outside that is indistinguishable from a hang.
    void Function(String manifestHash, int sent, int total)? onFileProgress,
  }) async {
    final token = context?.cancellationToken;
    token?.throwIfCancelled();
    if (manifestHashes.isEmpty) return;
    final unique = manifestHashes.toSet().toList();

    // --- manifests -----------------------------------------------------
    final manifests = <String, Uint8List>{};
    final needManifest = <String>[];
    for (final hash in unique) {
      var plain = await _readCached(hash);
      // Same bit-rot guard [download] applies: the plain-byte cache carries no
      // MAC, so a cached blob that no longer content-addresses to its id is
      // corrupt and must be refetched, not parsed.
      if (plain != null && _hasher(plain) != hash) {
        await _evictCached(hash);
        plain = null;
      }
      if (plain == null) {
        needManifest.add(hash);
      } else {
        manifests[hash] = plain;
      }
    }
    // Capped because a manifest is only small for small files: one for a 1 GiB
    // blob lists ~1000 hashes. The cap keeps a single request bounded whatever
    // the caller passes.
    const manifestsPerRequest = 64;
    for (var i = 0; i < needManifest.length; i += manifestsPerRequest) {
      token?.throwIfCancelled();
      final slice = needManifest.sublist(
        i,
        (i + manifestsPerRequest).clamp(0, needManifest.length),
      );
      final got = await remoteBlobStorage.download(slice, context: context);
      for (final entry in got.entries) {
        if (_hasher(entry.value) != entry.key) continue;
        await _writeCached(entry.value, entry.key);
        manifests[entry.key] = entry.value;
      }
    }

    // --- what is missing, across every file at once ---------------------
    final missing = <String>{};
    final sizeOf = <String, int>{};
    // Which files still want which chunks, so a chunk landing can be credited
    // to every file that references it — chunks are shared.
    final wantedBy = <String, Set<String>>{};
    final totalOf = <String, int>{};
    final doneOf = <String, int>{};
    final yielder = TimeBudgetYielder();
    for (final hash in unique) {
      token?.throwIfCancelled();
      final plain = manifests[hash];
      if (plain == null) continue;
      final parsed = _parseManifest(plain);
      if (parsed == null) continue;
      // Declared-size admission, as in [download]. An oversized file is left
      // out of the warm-up entirely; the applier's own guard rejects it again.
      final max = maxDownloadBytes;
      if (max != null && max > 0) {
        final declared = parsed.chunks.fold<int>(
          0,
          (a, r) => a + (r.size < 0 ? 0 : r.size),
        );
        if (parsed.size > max || declared > max) continue;
      }
      totalOf[hash] = parsed.size;
      doneOf[hash] = 0;
      for (final ref in parsed.chunks) {
        sizeOf[ref.hash] = ref.size;
        if (missing.contains(ref.hash)) {
          (wantedBy[ref.hash] ??= <String>{}).add(hash);
          continue;
        }
        final bytes = await _readCached(ref.hash);
        if (bytes != null && _hasher(bytes) == ref.hash) {
          // Already cached: counts instantly, exactly as the upload path
          // credits chunks the server already holds.
          doneOf[hash] = (doneOf[hash] ?? 0) + ref.size;
          continue;
        }
        if (bytes != null) {
          await _evictCached(ref.hash);
        }
        missing.add(ref.hash);
        (wantedBy[ref.hash] ??= <String>{}).add(hash);
        await yielder.maybeYield();
      }
      onFileProgress?.call(hash, doneOf[hash]!, parsed.size);
    }
    if (missing.isEmpty) return;

    // --- chunks ---------------------------------------------------------
    // Bounded by BOTH: bytes, so one response stays a reasonable size, and
    // count, because a batch of small notes is one chunk each and the byte
    // bound alone would let the id list in the REQUEST grow without limit.
    const batchLimitBytes = 2 * 1024 * 1024;
    const batchLimitCount = 256;
    var batch = <String>[];
    var batchBytes = 0;
    Future<void> flush() async {
      if (batch.isEmpty) return;
      token?.throwIfCancelled();
      final got = await remoteBlobStorage.download(batch, context: context);
      for (final entry in got.entries) {
        // A backend returning the wrong bytes for a content-addressed id is
        // corrupt or hostile: drop it, leaving the chunk absent so the
        // applier's assemble fails loudly instead of caching corruption.
        if (_hasher(entry.value) != entry.key) continue;
        // Warming is optional; the apply refetches whatever is missing. So a
        // full staging area stops the warm-up rather than the pull, and the
        // memory ceiling holds without anyone having to predict sizes.
        if (staging?.isFull ?? false) continue;
        await _writeCached(entry.value, entry.key);
        for (final owner in wantedBy[entry.key] ?? const <String>{}) {
          doneOf[owner] = (doneOf[owner] ?? 0) + (sizeOf[entry.key] ?? 0);
          onFileProgress?.call(owner, doneOf[owner]!, totalOf[owner] ?? 0);
        }
      }
      batch = <String>[];
      batchBytes = 0;
    }

    for (final hash in missing) {
      batch.add(hash);
      batchBytes += sizeOf[hash] ?? 0;
      if (batchBytes >= batchLimitBytes || batch.length >= batchLimitCount) {
        await flush();
      }
    }
    await flush();
  }

  /// Parses a manifest blob into its declared total size and chunk list.
  ///
  /// Factored out for the same reason [_build] is: the manifest JSON *is* part
  /// of the content address, and a second reader drifting by one field name
  /// would fail in a way that looks like corruption.
  ({int size, List<({String hash, int size})> chunks})? _parseManifest(
    Uint8List manifestPlain,
  ) {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(manifestPlain)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    final chunksJson = (json['chunks'] as List?) ?? const [];
    return (
      size: (json['size'] as int?) ?? 0,
      chunks: chunksJson.map((e) {
        final m = e as Map<String, dynamic>;
        return (hash: m['h'] as String, size: (m['s'] as int?) ?? 0);
      }).toList(),
    );
  }

  /// Chunks [bytes] and derives the manifest exactly as [upload] does,
  /// without uploading, caching or touching the network.
  ///
  /// Factored out rather than duplicated because the manifest JSON *is* part
  /// of the content address: a second copy of that literal, drifting by one
  /// field name, would produce a manifest hash that looks plausible and
  /// matches nothing.
  Future<
    ({
      BlobManifest manifest,
      Map<String, Uint8List> chunkBytes,
      List<String> orderedHashes,
      Uint8List manifestPlain,
      String manifestHash,
    })
  >
  _build(Uint8List bytes) async {
    final result = await _chunker(bytes);
    final manifest = result.manifest;
    final manifestJson = jsonEncode({
      'v': 1,
      'size': manifest.totalSize,
      'chunks': manifest.chunks.map((c) => {'h': c.hash, 's': c.size}).toList(),
    });
    final manifestPlain = Uint8List.fromList(utf8.encode(manifestJson));
    return (
      manifest: manifest,
      chunkBytes: result.chunks,
      orderedHashes: manifest.chunks.map((c) => c.hash).toList(growable: false),
      manifestPlain: manifestPlain,
      manifestHash: _hasher(manifestPlain),
    );
  }

  /// The blob id [bytes] would be stored under, computed locally.
  ///
  /// The content address is a pure function of the bytes and the vault's blob
  /// key, so this answers "is the copy I already have the one this ref names?"
  /// without a download. That question is what keeps a lost bookkeeping row
  /// from costing a transfer: state can be rebuilt from disk and verified
  /// against it, instead of the disk being overwritten on the assumption that
  /// an absent record means absent content.
  Future<String> blobRefOf(Uint8List bytes) async =>
      (await _build(bytes)).manifestHash;

  /// Every blob (chunks + manifest) that [bytes] would produce, keyed by id.
  ///
  /// Lets a caller regenerate blobs it no longer holds from the file still on
  /// disk. Self-verifying by construction: an id only appears here if these
  /// bytes really hash to it, so a file that has changed since simply yields
  /// different ids and the caller finds nothing it was looking for. That is
  /// why healing from disk needs no mtime check to be safe.
  Future<Map<String, Uint8List>> recompute(Uint8List bytes) async {
    final built = await _build(bytes);
    return {...built.chunkBytes, built.manifestHash: built.manifestPlain};
  }

  /// Stages every blob [bytes] produces, but only if they really produce
  /// [manifestHash]. Returns whether they did.
  ///
  /// The download-free half of a fetch. A file that is being moved, copied, or
  /// pulled back after a local delete arrives as a manifest this device has no
  /// entry for — while its bytes sit on disk under another name. Chunking is
  /// deterministic and every id is content-addressed, so re-deriving them costs
  /// a read and a hash and settles the question by construction: the ids either
  /// come out identical, or these are not the bytes and nothing is staged.
  ///
  /// All-or-nothing on purpose. Staging a subset would leave the assemble
  /// fetching the remainder one blob at a time, which is the shape of round
  /// trips the batched prefetch exists to avoid.
  Future<bool> seedFrom(Uint8List bytes, String manifestHash) async {
    // The same brake the network warm-up uses. [BlobStaging.write] accepts
    // whatever it is given — the budget is advisory and enforced by whoever
    // is about to add to it — so without this a large file rebuilt locally
    // would be held in memory past a ceiling that exists precisely to keep a
    // pull's transit area bounded. Refusing here sends it down the fetch path,
    // which has its own pressure handling.
    if (staging?.isFull ?? false) return false;
    final Map<String, Uint8List> produced;
    try {
      produced = await recompute(bytes);
    } catch (_) {
      // Chunking a file that is being written under us can fail; that is a
      // reason to fetch it, not to fail the pull.
      return false;
    }
    if (!produced.containsKey(manifestHash)) return false;
    for (final entry in produced.entries) {
      await _writeCached(entry.value, entry.key);
    }
    return true;
  }

  /// Fetch manifest by hash, fetch any chunks not in the local cache, and
  /// concatenate them in order. Returns null if anything cannot be
  /// retrieved or the result fails the size check.
  /// [onTooLarge] is called instead of nothing when the refusal below is a
  /// SIZE refusal, with the size that exceeded and the ceiling it exceeded.
  ///
  /// Reported out of band rather than through the return type or a throw. Null
  /// already means "these bytes are not available" at eight other call sites
  /// that handle it gracefully, and both alternatives would change what those
  /// see; this adds the reason without moving anything. What it fixes is a
  /// caller that could not tell a refusal from a loss and so reported the
  /// wrong one — see the callback's only user, in DiskReconciler.
  Future<Uint8List?> download(
    String manifestHash, {
    RpcContext? context,
    void Function(int sent, int total)? onProgress,
    void Function(int sizeBytes, int limitBytes)? onTooLarge,
  }) async {
    final token = context?.cancellationToken;
    token?.throwIfCancelled();
    var manifestPlain = await _readCached(manifestHash);
    // A cached manifest that no longer content-addresses to its id is corrupt
    // (bit-rot; the plain-byte cache has no MAC). Evict it and re-fetch.
    if (manifestPlain != null && _hasher(manifestPlain) != manifestHash) {
      await _evictCached(manifestHash);
      manifestPlain = null;
    }
    if (manifestPlain == null) {
      final got = await remoteBlobStorage.download([
        manifestHash,
      ], context: context);
      manifestPlain = got[manifestHash];
      if (manifestPlain == null) return null;
      // A backend that returns the wrong bytes for a content-addressed id is
      // corrupt or hostile — reject rather than parse garbage as a manifest.
      if (_hasher(manifestPlain) != manifestHash) return null;
      await _writeCached(manifestPlain, manifestHash);
    }

    final parsed = _parseManifest(manifestPlain);
    if (parsed == null) return null;
    final size = parsed.size;
    final chunkRefs = parsed.chunks;

    // Size admission (see [maxDownloadBytes]). Reject early on the DECLARED
    // sizes so an oversized blob is never fetched. The declared sizes are
    // attacker-controlled, so the fetch/assembly below ALSO guards the actual
    // running byte count — an understated manifest can't slip a multi-GiB blob
    // into memory.
    final max = maxDownloadBytes;
    if (max != null && max > 0) {
      final declaredChunkTotal = chunkRefs.fold<int>(
        0,
        (a, r) => a + (r.size < 0 ? 0 : r.size),
      );
      if (size > max || declaredChunkTotal > max) {
        onTooLarge?.call(size > max ? size : declaredChunkTotal, max);
        return null;
      }
    }

    final cached = <String, Uint8List>{};
    final missing = <String>[];
    var localBytes = 0;
    final verifyYielder = TimeBudgetYielder();
    for (final ref in chunkRefs) {
      final bytes = await _readCached(ref.hash);
      // Verify every cached chunk against its content-address. The local cache
      // holds PLAIN bytes, so the E2EE MAC never covers it — a bit-rotted entry
      // would otherwise be assembled into the file silently. A mismatch is
      // treated as a miss: evict the bad copy so the re-download below heals it.
      if (bytes != null && _hasher(bytes) == ref.hash) {
        cached[ref.hash] = bytes;
        localBytes += ref.size;
      } else {
        if (bytes != null) {
          await _evictCached(ref.hash);
        }
        missing.add(ref.hash);
      }
      // Hashing every chunk is O(bytes), so 16 of them is anywhere between
      // trivial and very expensive depending on chunk size — measure the work
      // instead of counting it.
      await verifyYielder.maybeYield();
    }
    // Chunks already in the local cache count instantly; fetch the rest in
    // byte-bounded batches so a large file reports moving progress.
    onProgress?.call(localBytes > size ? size : localBytes, size);

    if (missing.isNotEmpty) {
      final sizeOf = {for (final ref in chunkRefs) ref.hash: ref.size};
      const batchLimitBytes = 2 * 1024 * 1024;
      var batch = <String>[];
      var batchBytes = 0;
      // Sum of ACTUAL fetched-chunk bytes; guards against a manifest that
      // understates chunk sizes to slip past the declared-size gate above.
      var fetchedBytes = 0;
      var oversize = false;
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
          await _writeCached(entry.value, entry.key);
          localBytes += sizeOf[entry.key] ?? entry.value.length;
          fetchedBytes += entry.value.length;
          if (max != null && max > 0 && fetchedBytes > max) {
            // The manifest understated itself and the real bytes crossed the
            // line. Report what we actually saw, not what it claimed.
            onTooLarge?.call(fetchedBytes, max);
            oversize = true;
            return;
          }
        }
        onProgress?.call(localBytes > size ? size : localBytes, size);
        batch = <String>[];
        batchBytes = 0;
      }

      for (final h in missing) {
        batch.add(h);
        batchBytes += sizeOf[h] ?? 0;
        if (batchBytes >= batchLimitBytes) {
          await fetch();
          if (oversize) return null;
        }
      }
      await fetch();
      if (oversize) return null;
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
