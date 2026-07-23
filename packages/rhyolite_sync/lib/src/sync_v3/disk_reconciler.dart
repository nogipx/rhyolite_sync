import 'dart:convert';

import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Holds the disk ↔ CRDT-store reconcile logic in one place.
///
/// Three entry points share a single rule "reconcile-then-act":
///   * [reconcileWithDisk] — invoked from file-watcher events and from
///     the debounced text reconcile. Decides which path (binary vs.
///     text) and updates [store] / [fugueStore] when disk content
///     diverges from what the CRDT knows.
///   * [writeFileToDisk] — invoked from pull / merge outcomes. Pulls
///     the blob, projects Fugue if applicable, writes only when the
///     bytes actually differ.
///   * [loadOrSeedSequence] — exposed for the conflict resolver path
///     in the engine; seeds a Fugue Sequence either from a stored Fugue
///     blob or from a legacy plain-text blob with deterministic dots.
///
/// State this class touches:
///   * [store] / [fugueStore] — reads, applies local mutations,
///     persists single records.
///   * [io] — file read/write/exists.
///   * [blobStore] — local blob cache (via the chunkedIOBuilder).
///   * [changeProvider] — suppresses watcher echo when [writeFileToDisk]
///     writes.
///
/// State this class is deliberately blind to:
///   * RPC transport (passed in via the [chunkedIOBuilder] factory).
///   * Connection / epoch / push pipeline.
///   * Pull pipeline as a whole — only its disk-write step.
class DiskReconciler {
  /// Only files at least this big emit [SyncBlobTransfer] events — small notes
  /// would flash through the active-transfers monitor as noise.
  static const int _transferMonitorMinBytes = 256 * 1024;

  DiskReconciler({
    required this.vaultPath,
    required this.vaultId,
    required this.io,
    required this.blobStore,
    required this.changeProvider,
    required this.store,
    required this.fugueStore,
    required ChunkedBlobIO? Function() chunkedIOBuilder,
    required Set<String> Function() knownChunks,
    required String Function(String relPath) fileIdFor,
    required void Function(SyncEngineEvent event) emit,
    int? Function()? maxFileSizeBytes,
    Set<String> Function()? excludedExtensions,
    Set<String> Function()? forcedBinaryExtensions,
    Set<String>? sizeBlocked,
    StatSigStore? sigStore,
    LogScope? logger,
  }) : _chunkedIOBuilder = chunkedIOBuilder,
       _knownChunks = knownChunks,
       _fileIdFor = fileIdFor,
       _emit = emit,
       _maxFileSizeBytes = maxFileSizeBytes ?? (() => null),
       _excludedExtensions = excludedExtensions ?? (() => const <String>{}),
       _forcedBinaryExtensions =
           forcedBinaryExtensions ?? (() => const <String>{}),
       _sizeBlocked = sizeBlocked ?? <String>{},
       _sigStore = sigStore,
       _log = logger ?? LogScope.noop;

  final String vaultPath;
  final String vaultId;
  final IPlatformIO io;
  final LocalBlobStore blobStore;
  final IChangeProvider changeProvider;
  final FileStateStore store;
  final FugueStore fugueStore;
  final ChunkedBlobIO? Function() _chunkedIOBuilder;
  final Set<String> Function() _knownChunks;
  final String Function(String relPath) _fileIdFor;
  final void Function(SyncEngineEvent event) _emit;

  /// Current per-file upload size limit in bytes (null = unlimited). A file
  /// larger than this is never read/chunked/uploaded — surfaced via
  /// [SyncFileSizeBlocked] and skipped. Callback so a tier upgrade is live.
  final int? Function() _maxFileSizeBytes;

  /// Live per-device denylist of lowercase extensions (no dot) the user chose
  /// not to sync on this device. Callback so a settings change takes effect.
  final Set<String> Function() _excludedExtensions;

  /// Live vault-global set of extensions (no dot) forced onto the binary path.
  /// Callback so the synced policy takes effect without rebuilding the engine.
  final Set<String> Function() _forcedBinaryExtensions;

  /// Detector configured with the current force-binary policy.
  FileTypeDetector get _detector =>
      FileTypeDetector(extraBinaryExtensions: _forcedBinaryExtensions());

  /// Paths currently over the size limit (shared with [StateStartupDiff] via the
  /// engine). Used to emit [SyncFileSizeUnblocked] exactly once when a blocked
  /// file later disappears or shrinks — without it the UI's "too large" list
  /// would never clear.
  final Set<String> _sizeBlocked;

  /// Persistent mirror of [_statCache] so the stat short-circuit survives a
  /// plugin restart. Null when unavailable (tests) → in-memory only.
  final StatSigStore? _sigStore;

  final LogScope _log;

  /// Records a path's disk signature in both the in-session cache and the
  /// persistent store (keyed by the same fileId startup uses).
  void _setStat(String relPath, int mtimeMs, int sizeBytes) {
    _statCache[relPath] = (mtimeMs: mtimeMs, sizeBytes: sizeBytes);
    _sigStore?.set(_fileIdFor(relPath), mtimeMs, sizeBytes);
  }

  /// Drops a path's disk signature from both caches (file gone / renamed).
  void _dropStat(String relPath) {
    _statCache.remove(relPath);
    _sigStore?.remove(_fileIdFor(relPath));
  }

  /// In-memory stat cache. After each successful reconcile we record the
  /// disk's mtime + size for the path; the next call short-circuits if
  /// those haven't moved. Saves the heavy Fugue-diff / chunked-upload
  /// path when nothing on disk changed — extremely common during a
  /// startup pull where every applied record triggers a pre-reconcile
  /// for the same handful of paths.
  ///
  /// Reinstantiated on engine restart, but mirrored to [_sigStore] so a cold
  /// start still short-circuits via the persisted signature (a miss here falls
  /// back to [_sigStore] in [reconcileWithDisk]).
  final Map<String, ({int mtimeMs, int sizeBytes})> _statCache = {};

  /// Reconciles [relPath] with on-disk state. Returns true when the
  /// reconcile produced a state mutation that should be pushed.
  ///
  /// [context] propagates an optional cancellation token. Cancellation
  /// is checked before any chunk upload and before the commit-to-store
  /// step; if it fires mid-flight, no local mutation is persisted, so
  /// the file stays "dirty on disk" and the next reconcile picks it up.
  Future<bool> reconcileWithDisk(
    String relPath, {
    RpcContext? context,
  }) async {
    // Stat short-circuit: if neither mtime nor size moved since we last
    // ran reconcile for this path, disk is by definition still in sync
    // with what the store knows. POSIX mtime is reliable for "did the
    // file change?" in practice — false negatives require an adversarial
    // overwrite-with-same-mtime+size, which doesn't happen with normal
    // editors.
    final absPath = '$vaultPath/$relPath';

    // Type admission (per-device denylist): a file whose extension the user
    // excluded ON THIS DEVICE is never read/chunked/uploaded. Cheap (extension
    // string only). Takes precedence over the size check. A denylist change
    // triggers a re-scan (engine restart) so a re-included type re-syncs; a
    // skipped file leaves no stat signature, so the startup scan re-evaluates it.
    final excluded = _excludedExtensions();
    if (excluded.isNotEmpty) {
      final ext = FileTypeDetector.extensionOf(relPath);
      if (ext.isNotEmpty && excluded.contains(ext)) {
        _emit(SyncFileTypeExcluded(path: relPath, extension: ext));
        return false;
      }
    }

    final stat = await io.statFile(absPath);

    // Size admission: a file over the plan's per-file limit is never
    // read/chunked/uploaded — that would freeze the UI on a huge file and the
    // server would reject the blob anyway. Surface it and skip. O(1) (stat
    // only), so re-checking every reconcile is cheap; a shrunk file syncs.
    final limit = _maxFileSizeBytes();
    if (stat != null && limit != null && limit > 0 && stat.sizeBytes > limit) {
      _sizeBlocked.add(relPath);
      _emit(SyncFileSizeBlocked(
        path: relPath,
        sizeBytes: stat.sizeBytes,
        limitBytes: limit,
      ));
      return false;
    }
    // Not over the limit (deleted, shrank, or the tier limit rose): if this
    // path was blocked, announce it's clear so UI drops it from the list.
    if (_sizeBlocked.remove(relPath)) {
      _emit(SyncFileSizeUnblocked(path: relPath));
    }

    // Stat short-circuit: if neither mtime nor size moved since we last ran
    // reconcile for this path, disk is still in sync with the store. Fall back
    // to the persisted signature so the short-circuit works on a cold start too.
    final cached = _statCache[relPath] ?? _sigStore?.get(_fileIdFor(relPath));
    if (cached != null &&
        stat != null &&
        stat.mtimeMs == cached.mtimeMs &&
        stat.sizeBytes == cached.sizeBytes) {
      return false;
    }

    final changed = await (_detector.isText(relPath)
        ? _reconcileText(relPath, context: context)
        : _reconcileBinary(relPath, context: context));

    // Record post-reconcile stat so the next call short-circuits. If
    // the file was tombstoned (no longer on disk), drop the cache entry
    // so its recreation triggers a real reconcile.
    final postStat = await io.statFile(absPath);
    if (postStat != null) {
      _setStat(relPath, postStat.mtimeMs, postStat.sizeBytes);
    } else {
      _dropStat(relPath);
    }
    return changed;
  }

  /// Drops the cached stat for [relPath]. Used when a move/rename
  /// invalidates the cache key.
  void forgetStat(String relPath) => _dropStat(relPath);

  /// Writes [state]'s materialised content to disk, with three
  /// short-circuits:
  ///   1. Same blobRef as `lastSyncedBlobRefFor` — already on disk.
  ///   2. File on disk is byte-identical to what we'd write.
  ///   3. Blob is a Fugue Sequence — we project to text after caching.
  ///
  /// Returns true when the on-disk content is now known to match
  /// [state].blobRef (written just now, already identical, or already
  /// synced by this device) — i.e. it is safe for the caller to record
  /// this blobRef as the synced LCA. Returns false when nothing landed
  /// (blob unavailable): the caller MUST NOT advance the LCA, otherwise
  /// the already-synced short-circuit (1) permanently skips the file and
  /// it stays missing on disk.
  Future<bool> writeFileToDisk(
    FileState state, {
    RpcContext? context,
  }) async {
    // (1) Already materialised by this device — skip everything.
    final lastRef = store.lastSyncedBlobRefFor(state.fileId);
    if (state.blobRef.isNotEmpty && state.blobRef == lastRef) {
      _log.info(
        'disk write path=${state.path} bytes=0 '
        'download=0ms compare=0ms write=0ms total=0ms '
        'result=skipped-already-synced',
      );
      return true;
    }

    final swWriteTotal = Stopwatch()..start();
    Uint8List? bytes;
    final chunkedIO = _chunkedIOBuilder();
    final swDownload = Stopwatch();
    final monitor = state.sizeBytes >= _transferMonitorMinBytes;
    if (chunkedIO != null) {
      swDownload.start();
      try {
        bytes = await chunkedIO.download(
          state.blobRef,
          context: context,
          onProgress: monitor
              ? (sent, total) => _emit(SyncBlobTransfer(
                    path: state.path,
                    upload: false,
                    sentBytes: sent,
                    totalBytes: total,
                    done: false,
                  ))
              : null,
        );
      } catch (e) {
        _log.warning('Chunked download failed for ${state.path}: $e');
      } finally {
        if (monitor) {
          _emit(SyncBlobTransfer(
            path: state.path,
            upload: false,
            sentBytes: state.sizeBytes,
            totalBytes: state.sizeBytes,
            done: true,
          ));
        }
      }
      swDownload.stop();
    }
    if (bytes == null) {
      final tag = state.blobRef.length < 8
          ? state.blobRef
          : state.blobRef.substring(0, 8);
      _log.warning('Blob not available: $tag for ${state.path}');
      return false;
    }

    // (3) Fugue projection. The Fugue-magic test is a cheap 4-byte prefix
    // check and runs for EVERY file regardless of classification: a
    // magic-prefixed blob is always text-projectable and writing its raw
    // serialised bytes to disk is never correct. This keeps a file that was
    // synced as Fugue but is now classified binary (e.g. .excalidraw.md)
    // materialising correctly until a local edit migrates it to raw chunks.
    // Pre-Fugue plain-text blobs fall through and are written as-is; the next
    // local edit upgrades them via [loadOrSeedSequence].
    final isTextPath = _detector.isText(state.path);
    final swDecode = Stopwatch()..start();
    final fugue = _tryDecodeFugueBlob(bytes);
    swDecode.stop();
    if (fugue != null) {
      // Only text files consult the tree on the push path, so only they need
      // it cached; a now-binary file just needs the projected bytes.
      if (isTextPath) {
        fugueStore.set(state.fileId, fugue);
        await fugueStore.persistOne(state.fileId);
      }
      // Yield to the host event loop before the projection — for big
      // trees `.values.join()` runs hundreds of ms on the main JS
      // thread, freezing Obsidian when chaining files.
      await Future<void>.delayed(Duration.zero);
      final swProject = Stopwatch()..start();
      bytes = Uint8List.fromList(utf8.encode(fugue.values.join()));
      swProject.stop();
      _log.info(
        'fugue materialise path=${state.path} '
        'elements=${fugue.elementCount} '
        'decode=${swDecode.elapsedMilliseconds}ms '
        'project=${swProject.elapsedMilliseconds}ms '
        'projected=${bytes.length}B',
      );
    } else if (isTextPath && FugueStore.isLegacySequenceBlob(bytes)) {
      // A pre-Fugue Sequence blob from a not-yet-upgraded peer. Its bytes
      // are NOT document text — writing them would corrupt the note. Skip
      // without advancing the LCA so a reseed (from this device's own
      // reconcile-from-disk, or an upgraded peer) replaces it. The probe is a
      // full CBOR/JSON decode, so keep it off the binary path (large blobs).
      _log.warning(
        'Skipping legacy Sequence blob for ${state.path} — awaiting reseed',
      );
      return false;
    }
    // Otherwise: a genuine pre-Fugue plain-text blob, or a real binary — write
    // as-is.

    final fullPath = '$vaultPath/${state.path}';
    final swCompare = Stopwatch();
    final swWrite = Stopwatch();
    var skippedIdentical = false;
    // (2) Bytes-identical short-circuit.
    if (await io.fileExists(fullPath)) {
      try {
        swCompare.start();
        final existing = await io.readFile(fullPath);
        final eq =
            existing.length == bytes.length && _bytesEqual(existing, bytes);
        swCompare.stop();
        if (eq) {
          skippedIdentical = true;
          swWriteTotal.stop();
          _log.info(
            'disk write path=${state.path} bytes=${bytes.length} '
            'download=${swDownload.elapsedMilliseconds}ms '
            'compare=${swCompare.elapsedMilliseconds}ms '
            'write=0ms '
            'total=${swWriteTotal.elapsedMilliseconds}ms '
            'result=skipped-identical',
          );
          return true;
        }
      } catch (_) {
        swCompare.stop();
      }
    }
    changeProvider.suppress(state.path);
    swWrite.start();
    await io.writeFile(fullPath, bytes);
    swWrite.stop();
    // Refresh stat cache to what we just wrote — otherwise the next
    // reconcileWithDisk for this path will see mtime/size moved and
    // redo a full reconcile against bytes that already match the store.
    final postWriteStat = await io.statFile(fullPath);
    if (postWriteStat != null) {
      _setStat(state.path, postWriteStat.mtimeMs, postWriteStat.sizeBytes);
    }
    _emit(SyncFilePulled(fileId: state.fileId, nodeCount: 0, path: state.path));
    swWriteTotal.stop();
    _log.info(
      'disk write path=${state.path} bytes=${bytes.length} '
      'download=${swDownload.elapsedMilliseconds}ms '
      'compare=${swCompare.elapsedMilliseconds}ms '
      'write=${swWrite.elapsedMilliseconds}ms '
      'total=${swWriteTotal.elapsedMilliseconds}ms '
      'result=${skippedIdentical ? 'unreachable' : 'written'}',
    );
    return true;
  }

  /// Returns the locally-stored [Fugue] tree for [fileId], seeding it from
  /// the current FileState's blob (plain-text or Fugue) when this is the
  /// first time we touch the file as text. Returns an empty [Fugue] when no
  /// prior state exists — or when the blob is a pre-Fugue Sequence, so the
  /// caller reseeds from the current DISK text instead of from stale bytes.
  Future<Fugue<String>> loadOrSeedSequence(
    String fileId,
    String relPath, {
    RpcContext? context,
  }) async {
    final cached = await fugueStore.get(fileId);
    if (cached != null) return cached;

    final current = store.get(fileId);
    if (current == null || current.tombstone || current.blobRef.isEmpty) {
      return Fugue<String>();
    }
    final chunkedIO = _chunkedIOBuilder();
    if (chunkedIO == null) return Fugue<String>();

    try {
      final swDl = Stopwatch()..start();
      final bytes = await chunkedIO.download(current.blobRef, context: context);
      swDl.stop();
      if (bytes == null) return Fugue<String>();
      final swDecode = Stopwatch()..start();
      final fugue = _tryDecodeFugueBlob(bytes);
      swDecode.stop();
      if (fugue != null) {
        if (swDl.elapsedMilliseconds + swDecode.elapsedMilliseconds > 500) {
          _log.info(
            'seed $relPath: fugue blob bytes=${bytes.length} '
            'dl=${swDl.elapsedMilliseconds}ms '
            'decode=${swDecode.elapsedMilliseconds}ms '
            'elements=${fugue.elementCount}',
          );
        }
        return fugue;
      }
      // A pre-Fugue Sequence blob (old format) is NOT document text — seeding
      // from its raw bytes would produce garbage. Return empty so the caller
      // reseeds from the current disk content instead.
      if (FugueStore.isLegacySequenceBlob(bytes)) {
        _log.info('seed path=$relPath legacy Sequence blob — reseed from disk');
        return Fugue<String>();
      }
      // Genuine plain-text blob — seed deterministically. Two devices
      // independently seeding the same bytes converge by construction.
      final text = utf8.decode(bytes, allowMalformed: true);
      final swSeed = Stopwatch()..start();
      final seeded = FugueTextSync.seedFromText(text);
      swSeed.stop();
      _log.info(
        'seed path=$relPath plain-text chars=${text.length} '
        'dl=${swDl.elapsedMilliseconds}ms '
        'seed=${swSeed.elapsedMilliseconds}ms',
      );
      return seeded;
    } catch (e) {
      _log.warning('Fugue seed failed for $relPath: $e');
      return Fugue<String>();
    }
  }

  /// Renders the deterministic line-union of a multi-value text register to
  /// disk as a derived VIEW — WITHOUT collapsing the register.
  ///
  /// Used by the apply pipeline when concurrent text values share no causal
  /// history and so cannot be char-merged losslessly. The CRDT state (the
  /// MvRegister) stays multi-valued and converges across devices; the union
  /// is merely how that multi-value state is shown in the single file. The
  /// device's working Fugue sequence is set to `seed(union)` so a later user
  /// edit diffs against the union and — under an ownContext that already
  /// dominates every concurrent value — collapses the register on the next
  /// reconcile.
  ///
  /// Idempotent: re-rendering the same union (e.g. an idempotent re-pull)
  /// neither rewrites the file nor moves the stat cache. Returns true when it
  /// actually wrote to disk.
  Future<bool> renderUnionView(
    String fileId,
    String relPath,
    String unionText,
  ) async {
    // Working sequence = seed(union): reconcileWithDisk then sees disk ==
    // projection and treats it as a no-op, not a user edit.
    fugueStore.set(fileId, FugueTextSync.seedFromText(unionText));
    await fugueStore.persistOne(fileId);

    final fullPath = '$vaultPath/$relPath';
    final bytes = Uint8List.fromList(utf8.encode(unionText));
    if (await io.fileExists(fullPath)) {
      try {
        final existing = await io.readFile(fullPath);
        if (existing.length == bytes.length && _bytesEqual(existing, bytes)) {
          final stat = await io.statFile(fullPath);
          if (stat != null) {
            _setStat(relPath, stat.mtimeMs, stat.sizeBytes);
          }
          return false;
        }
      } catch (_) {}
    }
    changeProvider.suppress(relPath);
    await io.writeFile(fullPath, bytes);
    final postStat = await io.statFile(fullPath);
    if (postStat != null) {
      _setStat(relPath, postStat.mtimeMs, postStat.sizeBytes);
    }
    return true;
  }

  Future<bool> _reconcileBinary(
    String relPath, {
    RpcContext? context,
  }) async {
    final absPath = '$vaultPath/$relPath';
    final fileId = _fileIdFor(relPath);
    final current = store.get(fileId);

    if (!await io.fileExists(absPath)) {
      if (current == null || current.tombstone) return false;
      final hlc = store.nextHlc();
      store.applyLocal(
        current.copyWith(hlc: hlc, tombstone: true, blobRef: '', sizeBytes: 0),
      );
      await store.persistOne(fileId);
      return true;
    }

    final chunkedIO = _chunkedIOBuilder();
    if (chunkedIO == null) {
      _log.warning('Chunked IO unavailable (no remote storage) for $relPath');
      return false;
    }

    final bytes = await io.readFile(absPath);

    // Don't create sync state for a 0-byte file that isn't already tracked
    // as a live (non-tombstone) record. Obsidian mints empty notes on "new
    // note"; syncing them just churns records. A later edit that fills the
    // file promotes it into sync; an existing live file truncated to empty
    // still syncs (current is live), so real deletions/truncations propagate.
    if (bytes.isEmpty && (current == null || current.tombstone)) {
      return false;
    }

    final monitor = bytes.length >= _transferMonitorMinBytes;
    final ({String manifestHash, List<String> chunkHashes}) result;
    try {
      result = await chunkedIO.upload(
        bytes,
        _knownChunks(),
        context: context,
        onProgress: monitor
            ? (sent, total) => _emit(SyncBlobTransfer(
                  path: relPath,
                  upload: true,
                  sentBytes: sent,
                  totalBytes: total,
                  done: false,
                ))
            : null,
      );
    } finally {
      if (monitor) {
        _emit(SyncBlobTransfer(
          path: relPath,
          upload: true,
          sentBytes: bytes.length,
          totalBytes: bytes.length,
          done: true,
        ));
      }
    }

    if (current != null &&
        current.blobRef == result.manifestHash &&
        !current.tombstone) {
      return false;
    }

    // Last check before persisting — if the user started typing during
    // the upload, abort BEFORE touching the store so the file stays
    // dirty-on-disk and the next reconcile picks it up.
    context?.cancellationToken?.throwIfCancelled();

    final hlc = store.nextHlc();
    store.applyLocal(
      FileState(
        fileId: fileId,
        path: relPath,
        blobRef: result.manifestHash,
        sizeBytes: bytes.length,
        hlc: hlc,
        tombstone: false,
        chunks: result.chunkHashes,
      ),
    );
    await store.persistOne(fileId);
    return true;
  }

  Future<bool> _reconcileText(
    String relPath, {
    RpcContext? context,
  }) async {
    final absPath = '$vaultPath/$relPath';
    final fileId = _fileIdFor(relPath);
    final current = store.get(fileId);

    if (!await io.fileExists(absPath)) {
      if (current == null || current.tombstone) return false;
      final hlc = store.nextHlc();
      store.applyLocal(
        current.copyWith(hlc: hlc, tombstone: true, blobRef: '', sizeBytes: 0),
      );
      await store.persistOne(fileId);
      await fugueStore.remove(fileId);
      return true;
    }

    final swTotal = Stopwatch()..start();
    _log.info('text reconcile begin path=$relPath');
    final bytes = await io.readFile(absPath);

    // Skip empty new/tombstoned files — see _reconcileBinary. No Fugue seed
    // for a 0-byte note until it actually has content.
    if (bytes.isEmpty && (current == null || current.tombstone)) {
      return false;
    }

    final newText = utf8.decode(bytes, allowMalformed: true);
    _log.info('text reconcile read path=$relPath chars=${newText.length}');

    final swSeed = Stopwatch()..start();
    final oldSequence = await loadOrSeedSequence(
      fileId,
      relPath,
      context: context,
    );
    swSeed.stop();
    _log.info(
      'text reconcile seed-done path=$relPath '
      'elements=${oldSequence.elementCount} '
      'seed=${swSeed.elapsedMilliseconds}ms',
    );

    // Raise the local edit clock above every dot already in this file, so
    // the chars we are about to author strictly dominate existing content
    // even when a peer's clock ran ahead. Without this a fresh edit can be
    // stamped with a smaller counter than an adjacent character and be
    // misplaced by the position resolver across a tombstoned gap. This
    // `observe` SUBSUMES the old FileStateStore.witness step on the text
    // path, now over the Fugue Lamport clock.
    store.observeDots(oldSequence.dots);

    final swDiff = Stopwatch()..start();
    final newSequence = await FugueTextSync.applyTextSnapshot(
      oldFugue: oldSequence,
      newText: newText,
      clock: store.fugueClock,
    );
    swDiff.stop();
    _log.info(
      'text reconcile diff-done path=$relPath '
      'newElements=${newSequence.elementCount} '
      'diff=${swDiff.elapsedMilliseconds}ms',
    );
    // Unchanged content is a no-op for any TRACKED file. `current` is null
    // when the register is a multi-value conflict (store.get collapses to
    // null on conflict), so check hasConflict too — otherwise rendering the
    // union view to disk would look like a brand-new edit and applyLocal
    // would phantom-collapse the conflict under this device's HLC, diverging
    // peers. Only a genuinely new file (no register at all) falls through.
    if (identical(newSequence, oldSequence) &&
        (current != null || store.hasConflict(fileId))) {
      return false;
    }

    final swUpload = Stopwatch()..start();
    _log.info('text reconcile upload-begin path=$relPath');
    final upload = await _uploadSequenceBlob(newSequence, context: context);
    swUpload.stop();
    _log.info(
      'text reconcile upload-done path=$relPath '
      'upload=${swUpload.elapsedMilliseconds}ms',
    );
    if (upload == null) {
      _log.warning('Chunked IO unavailable (no remote storage) for $relPath');
      return false;
    }
    swTotal.stop();
    _log.info(
      'text reconcile path=$relPath chars=${newText.length} '
      'elements=${newSequence.elementCount} '
      'blob=${upload.blobSize}B '
      'seed=${swSeed.elapsedMilliseconds}ms '
      'diff=${swDiff.elapsedMilliseconds}ms '
      'upload=${swUpload.elapsedMilliseconds}ms '
      'total=${swTotal.elapsedMilliseconds}ms',
    );

    // Last check before any persist — typing during upload aborts
    // here, leaving fugueStore and FileState untouched. Disk still
    // diverges → next reconcile picks the file up.
    context?.cancellationToken?.throwIfCancelled();

    // Same manifest hash as the current FileState — the tree changed
    // (new tombstones) but bytes didn't. Cache the tree, skip the
    // FileState bump.
    if (current != null &&
        current.blobRef == upload.manifestHash &&
        !current.tombstone) {
      fugueStore.set(fileId, newSequence);
      await fugueStore.persistOne(fileId);
      return false;
    }

    fugueStore.set(fileId, newSequence);
    await fugueStore.persistOne(fileId);

    final hlc = store.nextHlc();
    store.applyLocal(
      FileState(
        fileId: fileId,
        path: relPath,
        blobRef: upload.manifestHash,
        sizeBytes: upload.blobSize,
        hlc: hlc,
        tombstone: false,
        chunks: upload.chunkHashes,
      ),
    );
    await store.persistOne(fileId);
    return true;
  }

  /// Serialises [seq] as a chunked blob via [ChunkedBlobIO]. Returns
  /// `null` when no remote storage is configured (offline-only run).
  /// Exposed for the conflict-resolution path in the engine; the same
  /// upload is used internally by [_reconcileText].
  Future<({String manifestHash, List<String> chunkHashes, int blobSize})?>
  uploadSequenceBlob(
    Fugue<String> seq, {
    RpcContext? context,
  }) =>
      _uploadSequenceBlob(seq, context: context);

  /// Exposed for the conflict-resolution path in the engine — needs
  /// to probe arbitrary blob bytes when reconstructing a Fugue
  /// loser-state during 3-way merge.
  Fugue<String>? tryDecodeFugueBlob(Uint8List bytes) =>
      _tryDecodeFugueBlob(bytes);

  Future<({String manifestHash, List<String> chunkHashes, int blobSize})?>
  _uploadSequenceBlob(
    Fugue<String> seq, {
    RpcContext? context,
  }) async {
    final chunkedIO = _chunkedIOBuilder();
    if (chunkedIO == null) return null;
    final swEncode = Stopwatch()..start();
    // Magic-prefixed compact binary — self-identifying, ~2 B/char, so peers
    // decode it back with FugueStore.tryDecodeBlob and old clients reject it.
    final bytes = FugueStore.encodeBlob(seq);
    swEncode.stop();
    if (swEncode.elapsedMilliseconds > 50 || bytes.length > 256 * 1024) {
      _log.info(
        'fugue encode: elements=${seq.elementCount} bytes=${bytes.length} '
        'encode=${swEncode.elapsedMilliseconds}ms',
      );
    }
    final result = await chunkedIO.upload(
      bytes,
      _knownChunks(),
      context: context,
    );
    return (
      manifestHash: result.manifestHash,
      chunkHashes: result.chunkHashes,
      blobSize: bytes.length,
    );
  }

  /// Tries to interpret raw blob bytes as a serialised [Fugue] tree.
  /// Returns null when the bytes are not a magic-prefixed Fugue blob —
  /// typically a pre-Fugue plain-text / legacy Sequence blob, or a binary
  /// file misrouted here. Callers pair a null with
  /// [FugueStore.isLegacySequenceBlob] to tell those apart.
  Fugue<String>? _tryDecodeFugueBlob(Uint8List bytes) =>
      FugueStore.tryDecodeBlob(bytes);

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
