import 'dart:convert';

import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

import 'package:rhyolite_core/rhyolite_core.dart';
import '../storage/fm_store.dart';

/// Everything a text reconcile worked out before it needed the network.
///
/// Exists so a caller with many files to push can do the network part for all
/// of them at once. The startup pass had no way to: [DiskReconciler] decided,
/// uploaded and committed in one call, so 188 notes cost 376 round trips while
/// 188 binaries would have cost 48 — the binary path groups eight files behind
/// one pair of requests and text had no equivalent. On a backend where the
/// round trip is cheap that never showed; on a BYO WebDAV it was the whole
/// wait.
class TextReconcilePlan {
  const TextReconcilePlan({
    required this.relPath,
    required this.fileId,
    required this.blobBytes,
    required this.sequence,
    required this.fm,
    required this.charCount,
  });

  final String relPath;
  final String fileId;

  /// The encoded Fugue tree, frontmatter tail included. Exactly the bytes
  /// [DiskReconciler] would have uploaded itself.
  final Uint8List blobBytes;

  final Fugue<String> sequence;
  final FmState? fm;
  final int charCount;
}

/// What [DiskReconciler.planTextReconcile] concluded.
///
/// Most reconciles never reach the network — an unedited note, a delete, a
/// format this build cannot read — and those are settled in the planning call
/// itself. Only the rest carry a [plan].
class TextReconcileOutcome {
  /// Finished without needing an upload. [changed] is what `reconcileWithDisk`
  /// would have returned.
  const TextReconcileOutcome.settled(this.changed) : plan = null;

  /// Produced bytes; the caller uploads them and calls
  /// [DiskReconciler.commitTextReconcile].
  const TextReconcileOutcome.needsUpload(TextReconcilePlan this.plan)
    : changed = false;

  final bool changed;
  final TextReconcilePlan? plan;
}

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
  ///
  /// Public so [StateStartupDiff] narrates from the same threshold: it uploads
  /// the same files on the startup and re-upload paths, and two copies of this
  /// number would drift into "the monitor shows a file when you edit it but
  /// not when you re-upload the vault".
  static const int transferMonitorMinBytes = 256 * 1024;

  static const int _transferMonitorMinBytes = transferMonitorMinBytes;

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
    PathScope Function()? pathScope,
    Set<String> Function()? forcedBinaryExtensions,
    Set<String>? sizeBlocked,
    StatSigStore? sigStore,
    FmStore? fmStore,
    int? Function()? fmGcBarrier,

    /// Told when a referenced blob turns out not to be fetchable. See the
    /// call site for why a materialise is the one place that finds this out
    /// on its own.
    void Function(String blobRef, String path)? onBlobUnavailable,
    LogScope? logger,
  }) : _onBlobUnavailable = onBlobUnavailable ?? ((_, _) {}),
       _fmStore = fmStore,
       _fmGcBarrier = fmGcBarrier ?? (() => null),
       _chunkedIOBuilder = chunkedIOBuilder,
       _knownChunks = knownChunks,
       _fileIdFor = fileIdFor,
       _emit = emit,
       _maxFileSizeBytes = maxFileSizeBytes ?? (() => null),
       _excludedExtensions = excludedExtensions ?? (() => const <String>{}),
       _pathScope = pathScope ?? (() => PathScope.everything),
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
  final void Function(String blobRef, String path) _onBlobUnavailable;
  final void Function(SyncEngineEvent event) _emit;

  /// Current per-file upload size limit in bytes (null = unlimited). A file
  /// larger than this is never read/chunked/uploaded — surfaced via
  /// [SyncFileSizeBlocked] and skipped. Callback so a tier upgrade is live.
  final int? Function() _maxFileSizeBytes;

  /// Live per-device denylist of lowercase extensions (no dot) the user chose
  /// not to sync on this device. Callback so a settings change takes effect.
  final Set<String> Function() _excludedExtensions;

  /// Live per-device folder filter. A path outside it is never read, chunked,
  /// uploaded — nor tombstoned when it disappears from disk, which is the
  /// whole point: narrowing the scope must not look like a mass delete to the
  /// user's other devices.
  final PathScope Function() _pathScope;

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

  /// Per-file frontmatter CRDT state. Null in tests that do not wire it, and
  /// then no tail is written — which is exactly what a peer without the
  /// feature does, so the path is worth keeping cheap rather than special.
  final FmStore? _fmStore;

  /// Newest server seq every active device has pulled past, or null when
  /// unknown. Supplied by [CausalStabilityGc], which already pays the RPC.
  final int? Function() _fmGcBarrier;

  /// Persistent mirror of [_statCache] so the stat short-circuit survives a
  /// plugin restart. Null when unavailable (tests) → in-memory only.
  final StatSigStore? _sigStore;

  final LogScope _log;

  /// Records a path's disk signature in both the in-session cache and the
  /// persistent store (keyed by the same fileId startup uses).
  /// [blobRef] is what the signature is evidence for — the value whose bytes
  /// are now on disk. Null when that cannot be named: a union view is not any
  /// single value's content, and a reader must not treat it as one.
  void _setStat(String relPath, int mtimeMs, int sizeBytes, {String? blobRef}) {
    _statCache[relPath] = (
      mtimeMs: mtimeMs,
      sizeBytes: sizeBytes,
      blobRef: blobRef,
    );
    _sigStore?.set(_fileIdFor(relPath), mtimeMs, sizeBytes, blobRef: blobRef);
  }

  /// Per-file disk-write lines kept before the rest are counted instead of
  /// logged, and the counter behind it.
  ///
  /// One line per file is the right amount of detail for an ordinary pull and
  /// the wrong amount for a first sync: 9000 files is 9000 lines, and a real
  /// report came back 98% one INFO line with two other faults evicted from it.
  /// A slow write is exempt — that is the line anyone is actually looking for,
  /// and there are never many of them.
  static const int _maxWriteSamples = 20;
  static const int _alwaysLogAboveMs = 200;
  int _writeSamples = 0;

  /// Whether this disk-write line is worth keeping: the first few of a run, or
  /// any that took long enough to be the answer to a question.
  bool _sampleWriteLine(int elapsedMs) =>
      elapsedMs >= _alwaysLogAboveMs || ++_writeSamples <= _maxWriteSamples;

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
  /// Same shape as the persisted signature, so the two are interchangeable at
  /// the read site and carry the same evidence.
  final Map<String, ({int mtimeMs, int sizeBytes, String? blobRef})>
  _statCache = {};

  /// Reconciles [relPath] with on-disk state. Returns true when the
  /// reconcile produced a state mutation that should be pushed.
  ///
  /// [context] propagates an optional cancellation token. Cancellation
  /// is checked before any chunk upload and before the commit-to-store
  /// step; if it fires mid-flight, no local mutation is persisted, so
  /// the file stays "dirty on disk" and the next reconcile picks it up.
  Future<bool> reconcileWithDisk(String relPath, {RpcContext? context}) async {
    // Stat short-circuit: if neither mtime nor size moved since we last
    // ran reconcile for this path, disk is by definition still in sync
    // with what the store knows. POSIX mtime is reliable for "did the
    // file change?" in practice — false negatives require an adversarial
    // overwrite-with-same-mtime+size, which doesn't happen with normal
    // editors.
    final absPath = '$vaultPath/$relPath';

    // Path admission (per-device folder filter): a path the user put out of
    // scope is invisible to this device — no read, no upload, and crucially no
    // tombstone when it vanishes from disk. Deletes reach this method too
    // (the engine reconciles the deleted path), so gating here is what keeps
    // "I only sync Work/ now" from propagating as a delete of everything else.
    final scope = _pathScope();
    if (!scope.allows(relPath)) {
      _emit(SyncFileOutOfScope(path: relPath));
      return false;
    }

    // Ours, and never the server's — a diagnostic report lives in the vault
    // only so the user can share it. Unconditional, so no filter setting can
    // let it through, and ahead of every other admission test.
    if (isNeverSynced(relPath)) return false;

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
      _emit(
        SyncFileSizeBlocked(
          path: relPath,
          sizeBytes: stat.sizeBytes,
          limitBytes: limit,
        ),
      );
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
      // Null while the register is contested — store.get collapses to null on
      // a conflict, and disk then holds a view rather than a value.
      _setStat(
        relPath,
        postStat.mtimeMs,
        postStat.sizeBytes,
        blobRef: store.get(_fileIdFor(relPath))?.blobRef,
      );
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
  /// Whether the file on disk provably holds [state]'s content already.
  ///
  /// The proof has two halves and needs both. The signature says which blob
  /// the file held when it was last written by this device, and the stat says
  /// the file has not moved since. Either alone is not enough — and the
  /// tempting shortcut of comparing the signature against the value in the
  /// STORE is the unsound one: by the time this runs the register has already
  /// joined the incoming record, so the stored value IS the peer's, and a
  /// stale signature would then vouch for content the disk has never seen.
  /// That mistake drops a peer's edit silently, which is why the blobRef is
  /// carried on the signature itself.
  ///
  /// Conservative everywhere else too: a signature written before that field
  /// existed, or taken for a multi-value union view, carries no blobRef and
  /// proves nothing, so this falls through to the download-and-compare path
  /// that shipped before it.
  Future<bool> _diskAlreadyHolds(FileState state) async {
    if (state.blobRef.isEmpty || state.tombstone) return false;
    final sig =
        _statCache[state.path] ?? _sigStore?.get(_fileIdFor(state.path));
    if (sig == null || sig.blobRef != state.blobRef) return false;
    final stat = await io.statFile('$vaultPath/${state.path}');
    if (stat == null) return false;
    return stat.mtimeMs == sig.mtimeMs && stat.sizeBytes == sig.sizeBytes;
  }

  Future<bool> writeFileToDisk(FileState state, {RpcContext? context}) async {
    // (1) Already materialised by this device — skip everything.
    final lastRef = store.lastSyncedBlobRefFor(state.fileId);
    if (state.blobRef.isNotEmpty && state.blobRef == lastRef) {
      if (_sampleWriteLine(0)) {
        _log.info(
          'disk write bytes=0 '
          'assemble=0ms compare=0ms write=0ms total=0ms '
          'result=skipped-already-synced',
          data: {'path': LogPath(state.path)},
        );
      }
      return true;
    }

    // (1b) Our own work coming back. The guard above cannot catch it: a push
    // deliberately does not advance the LCA, so the first pull that hands our
    // record back finds it cold and fetches the blob to compare it against the
    // very file it was made from.
    //
    // This IS the convergence point the LCA is for — the server holds this
    // value and so do we — so recording it here is not a shortcut but the step
    // that was missing. Every later pull then stops at (1).
    if (await _diskAlreadyHolds(state)) {
      store.recordSyncedBlobRef(state.fileId, state.blobRef);
      if (_sampleWriteLine(0)) {
        _log.info(
          'disk write bytes=0 '
          'assemble=0ms compare=0ms write=0ms total=0ms '
          'result=skipped-own-echo',
          data: {'path': LogPath(state.path)},
        );
      }
      return true;
    }

    final swWriteTotal = Stopwatch()..start();
    Uint8List? bytes;
    final chunkedIO = _chunkedIOBuilder();
    // Time to have the bytes in hand, whatever that took. Reported as
    // `assemble` and not `download` because in the pull path it usually is
    // not one: the prefetch has already put every chunk in the batch's
    // staging area, so this is a concatenation. It read as a network cost
    // that had not been paid — 286ms of "download" for a file that never
    // touched the wire — which is exactly the reading that sends someone
    // looking for a slow link.
    final swDownload = Stopwatch();
    final monitor = state.sizeBytes >= _transferMonitorMinBytes;
    // Set when the download refused on size, so the report below can tell a
    // refusal from a loss. Both arrive here as a null.
    ({int sizeBytes, int limitBytes})? tooLarge;
    if (chunkedIO != null) {
      swDownload.start();
      try {
        bytes = await chunkedIO.download(
          state.blobRef,
          context: context,
          onTooLarge: (sizeBytes, limitBytes) =>
              tooLarge = (sizeBytes: sizeBytes, limitBytes: limitBytes),
          onProgress: monitor
              ? (sent, total) => _emit(
                  SyncBlobTransfer(
                    path: state.path,
                    upload: false,
                    sentBytes: sent,
                    totalBytes: total,
                    done: false,
                  ),
                )
              : null,
        );
      } on UnsupportedCipherVersion catch (e) {
        // The blob is sealed in an envelope this build has no cipher for —
        // written by a NEWER client. Identical in kind to an unknown blob tag,
        // so it gets the same treatment: say so, leave the file alone, and do
        // not advance the LCA, so an updated client materialises it later with
        // no repair step.
        //
        // Without this the exception fell into the generic catch below, became
        // "download failed", and the file retried forever with nothing to
        // explain why.
        _log.error(
          'Refusing to write: $e — update this client',
          data: {'path': LogPath(state.path)},
        );
        _emit(SyncFileFormatUnsupported(path: state.path));
      } catch (e) {
        _log.warning(
          'Chunked download failed: $e',
          data: {'path': LogPath(state.path)},
        );
      } finally {
        if (monitor) {
          _emit(
            SyncBlobTransfer(
              path: state.path,
              upload: false,
              sentBytes: state.sizeBytes,
              totalBytes: state.sizeBytes,
              done: true,
            ),
          );
        }
      }
      swDownload.stop();
    }
    if (bytes == null) {
      // A refusal and a loss both arrive as null and must not read alike. The
      // second is "your data may be gone"; the first is "this device will not
      // carry a file this big", which loses nothing and is not a repair.
      final refused = tooLarge;
      if (refused != null) {
        _log.warning(
          'File too large to fetch: ${refused.sizeBytes} B of '
          '${refused.limitBytes} B',
          data: {'path': LogPath(state.path)},
        );
        _emit(
          SyncFileTooLargeToFetch(
            path: state.path,
            sizeBytes: refused.sizeBytes,
            limitBytes: refused.limitBytes,
          ),
        );
        return false;
      }
      final tag = state.blobRef.length < 8
          ? state.blobRef
          : state.blobRef.substring(0, 8);
      _log.warning(
        'Blob not available: $tag',
        data: {'path': LogPath(state.path)},
      );
      // The one place in the engine that learns a referenced blob is really
      // gone, and until now the only thing it did with that was write a line.
      //
      // The heal already exists — VerifyBlobsUseCase probes the server and
      // re-uploads from the local cache or straight from the file on disk —
      // but it runs in the lowest maintenance tier, and a device stuck
      // re-pulling never reaches an idle moment to run it in. One report shows
      // 394 files warning here twice each, on a vault whose disk copies were
      // all intact: every one of them was healable and none was healed.
      //
      // Reporting is all that belongs here. Whether to sweep, and when, is the
      // engine's call — this class has no scheduler and should not grow one.
      _onBlobUnavailable(state.blobRef, state.path);
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
    final kind = classifyBlob(bytes, isTextPath: isTextPath);
    final fugue = kind == BlobKind.fugue ? _tryDecodeFugueBlob(bytes) : null;
    swDecode.stop();
    if (fugue != null) {
      // Only text files consult the tree on the push path, so only they need
      // it cached; a now-binary file just needs the projected bytes.
      if (isTextPath) {
        fugueStore.set(state.fileId, fugue);
        await fugueStore.persistOne(state.fileId);
        // Refresh the frontmatter cache from the same bytes when the peer that
        // wrote them carried it. Absent is ordinary, not an error.
        final fm = readFmTail(bytes);
        if (fm != null) {
          _fmStore?.set(state.fileId, fm);
          await _fmStore?.persistOne(state.fileId);
        }
      }
      // Yield to the host event loop before the projection — for big
      // trees `.values.join()` runs hundreds of ms on the main JS
      // thread, freezing Obsidian when chaining files.
      await Future<void>.delayed(Duration.zero);
      final swProject = Stopwatch()..start();
      bytes = Uint8List.fromList(utf8.encode(fugue.values.join()));
      swProject.stop();
      _log.info(
        'fugue materialise '
        'elements=${fugue.elementCount} '
        'decode=${swDecode.elapsedMilliseconds}ms '
        'project=${swProject.elapsedMilliseconds}ms '
        'projected=${bytes.length}B',
        data: {'path': LogPath(state.path)},
      );
    } else if (kind == BlobKind.legacySequence) {
      // A pre-Fugue Sequence blob from a not-yet-upgraded peer. Its bytes
      // are NOT document text — writing them would corrupt the note. Skip
      // without advancing the LCA so a reseed (from this device's own
      // reconcile-from-disk, or an upgraded peer) replaces it.
      _log.warning(
        'Skipping legacy Sequence blob — awaiting reseed',
        data: {'path': LogPath(state.path)},
      );
      return false;
    } else if (kind == BlobKind.unknownTagged) {
      // Written by a newer client in a format this build has no decoder for.
      // This is the branch that used to fall through to "write as-is" and put
      // serialised CRDT state inside the user's note — the only path that
      // corrupts the vault rather than merely showing something unreadable.
      //
      // Not advancing the LCA is deliberate: an updated client re-materialises
      // it later without any repair step.
      _log.error(
        'Refusing to write: blob is in an unsupported format '
        '(written by a newer client) — update this client',
        data: {'path': LogPath(state.path)},
      );
      _emit(SyncFileFormatUnsupported(path: state.path));
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
          // Record the signature, exactly as the write path below does.
          //
          // We have just PROVEN the disk holds this blobRef — by comparing
          // every byte, which is the strongest form of the claim the
          // signature makes. Not recording it threw that proof away, and the
          // cost of throwing it away is not one wasted comparison:
          //
          // Without a signature `_diskAlreadyHolds` cannot answer, so the next
          // pull's pre-join reconcile treats the file as locally edited, seeds
          // a Fugue tree from disk under this device's clock, and that seed is
          // concurrent with the remote by construction. Every note then goes
          // through the text resolver — two uploads and a merge, measured at
          // 2.3 to 4.8 seconds each, for files whose bytes were identical.
          //
          // It stayed hidden while the database was losing its state rows: the
          // pre-reconcile is gated on `store.get(fileId) != null`, so an empty
          // store skipped it. Durable state switched the path on, and the
          // missing signature turned it into an upload storm.
          final stat = await io.statFile(fullPath);
          if (stat != null) {
            _setStat(
              state.path,
              stat.mtimeMs,
              stat.sizeBytes,
              blobRef: state.blobRef,
            );
          }
          swWriteTotal.stop();
          if (_sampleWriteLine(swWriteTotal.elapsedMilliseconds)) {
            _log.info(
              'disk write bytes=${bytes.length} '
              'assemble=${swDownload.elapsedMilliseconds}ms '
              'compare=${swCompare.elapsedMilliseconds}ms '
              'write=0ms '
              'total=${swWriteTotal.elapsedMilliseconds}ms '
              'result=skipped-identical',
              data: {'path': LogPath(state.path)},
            );
          }
          return true;
        }
      } catch (_) {
        swCompare.stop();
      }
      // (2b) The file is on disk, holds something ELSE, and the engine has
      // never taken custody of those bytes: no pull materialised them
      // (`lastRef` is null) AND no reconcile ever read them (no stat
      // signature). That combination means a vault copied onto a new machine,
      // or edits made while the local database was gone. Writing now destroys
      // them with nothing to recover from.
      //
      // BOTH halves are required. `lastRef` alone is not "we have never seen
      // this file": a push deliberately never advances the synced LCA, so a
      // note this device CREATED and published still has a null lastRef. On
      // that alone the guard would refuse every peer edit to it, for ever — the
      // file would simply stop updating here. The stat signature is what tells
      // the two apart, and it survives a restart via [_sigStore].
      //
      // Refusing hands the file to the path that is meant to have it. The LCA
      // stays unset, so the next pass still treats the file as unmaterialised;
      // by then `store.get(fileId)` is non-null (the record was applied above
      // us), which is exactly the condition that lets the applier's pre-join
      // reconcile capture the disk content as a concurrent value. The register
      // then goes multi-value and the ordinary text resolver merges both sides
      // instead of one silently winning. StateStartupDiff does the same on a
      // cold start — and once either has read the file, the signature exists
      // and this guard steps out of the way.
      //
      // Costs nothing in the case the old behaviour was written for: after a
      // local wipe the disk content EQUALS the remote, so (2) already returned.
      final everRead =
          _statCache[state.path] != null ||
          _sigStore?.get(_fileIdFor(state.path)) != null;
      if (lastRef == null && !everRead) {
        swWriteTotal.stop();
        _log.warning(
          'Not overwriting: it holds content this device never '
          'synced (${bytes.length}B incoming). Kept on disk so the next pass '
          'merges it instead of replacing it.',
          data: {'path': LogPath(state.path)},
        );
        _emit(SyncFileKeptUnsynced(fileId: state.fileId, path: state.path));
        return false;
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
      _setStat(
        state.path,
        postWriteStat.mtimeMs,
        postWriteStat.sizeBytes,
        blobRef: state.blobRef,
      );
    }
    _emit(SyncFilePulled(fileId: state.fileId, nodeCount: 0, path: state.path));
    swWriteTotal.stop();
    if (_sampleWriteLine(swWriteTotal.elapsedMilliseconds)) {
      _log.info(
        'disk write bytes=${bytes.length} '
        'assemble=${swDownload.elapsedMilliseconds}ms '
        'compare=${swCompare.elapsedMilliseconds}ms '
        'write=${swWrite.elapsedMilliseconds}ms '
        'total=${swWriteTotal.elapsedMilliseconds}ms '
        'result=${skippedIdentical ? 'unreachable' : 'written'}',
        data: {'path': LogPath(state.path)},
      );
    }
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
      // Always the text path: this is only reached from the text reconcile.
      final kind = classifyBlob(bytes, isTextPath: true);
      final fugue = kind == BlobKind.fugue ? _tryDecodeFugueBlob(bytes) : null;
      swDecode.stop();
      if (fugue != null) {
        if (swDl.elapsedMilliseconds + swDecode.elapsedMilliseconds > 500) {
          _log.info(
            'seed fugue blob bytes=${bytes.length} '
            'dl=${swDl.elapsedMilliseconds}ms '
            'decode=${swDecode.elapsedMilliseconds}ms '
            'elements=${fugue.elementCount}',
            data: {'path': LogPath(relPath)},
          );
        }
        return fugue;
      }
      // A pre-Fugue Sequence blob (old format) is NOT document text — seeding
      // from its raw bytes would produce garbage. Return empty so the caller
      // reseeds from the current disk content instead.
      if (kind == BlobKind.legacySequence) {
        _log.info(
          'seed legacy Sequence blob — reseed from disk',
          data: {'path': LogPath(relPath)},
        );
        return Fugue<String>();
      }
      // A format this build cannot read. Unlike the legacy case there is no
      // safe fallback here: seeding from the raw bytes produces garbage, and
      // seeding EMPTY is worse — the caller would diff disk against an empty
      // tree, push a full-content blob in THIS build's format, and replace
      // state a newer client wrote. Refusing is the only branch that does not
      // destroy data, so it throws rather than returning a tree.
      if (kind == BlobKind.unknownTagged) {
        throw UnsupportedBlobFormatException(relPath);
      }
      // Genuine plain-text blob — seed deterministically. Two devices
      // independently seeding the same bytes converge by construction.
      final text = utf8.decode(bytes, allowMalformed: true);
      final swSeed = Stopwatch()..start();
      final seeded = FugueTextSync.seedFromText(text);
      swSeed.stop();
      _log.info(
        'seed plain-text chars=${text.length} '
        'dl=${swDl.elapsedMilliseconds}ms '
        'seed=${swSeed.elapsedMilliseconds}ms',
        data: {'path': LogPath(relPath)},
      );
      return seeded;
    } on UnsupportedBlobFormatException {
      // Must escape this catch-all. Swallowing it and returning an empty tree
      // is exactly the overwrite the throw exists to prevent.
      rethrow;
    } catch (e) {
      _log.warning('Fugue seed failed: $e', data: {'path': LogPath(relPath)});
      return Fugue<String>();
    }
  }

  /// Loads the composite document for [fileId]: the frontmatter state and the
  /// body tree.
  ///
  /// [fm] is null when the file has never been lifted — its blob is `fugue1`,
  /// or plain text, or it is new. That is not an error, it is the ordinary
  /// state of every note until something touches its frontmatter.
  Future<({FmState? fm, Fugue<String> body})> loadOrSeedDocument(
    String fileId,
    String relPath, {
    RpcContext? context,
  }) async {
    final cachedFm = await _fmStore?.get(fileId);
    final cachedBody = await fugueStore.get(fileId);
    // The body alone is enough. Requiring the frontmatter half too looked
    // symmetric and was not: [_persistDocument] writes the body ALWAYS and the
    // fm only when there is one to write, so a note that has never carried a
    // property is permanently body-cached and fm-empty — and that is most
    // notes. Each of them re-downloaded its own blob on EVERY reconcile: the
    // pre-join one on every pull, and the one behind every edit, purely to
    // read a tail that was never written. It is why a startup that uploaded
    // 188 notes turned around and fetched 185 of them straight back.
    //
    // The two rows are written together, so their absence together is the
    // honest reading: this note has no frontmatter state. The one case that
    // slips past is a crash between those two awaits, and it is already
    // handled downstream — a tail-less side is lifted from its own text under
    // its own clock, exactly as a peer predating the tail is.
    if (cachedBody != null) {
      return (fm: cachedFm, body: cachedBody);
    }

    final current = store.get(fileId);
    if (current == null || current.tombstone || current.blobRef.isEmpty) {
      return (fm: cachedFm, body: cachedBody ?? Fugue<String>());
    }
    final chunkedIO = _chunkedIOBuilder();
    if (chunkedIO == null) {
      return (fm: cachedFm, body: cachedBody ?? Fugue<String>());
    }

    final bytes = await chunkedIO.download(current.blobRef, context: context);
    if (bytes == null) {
      return (fm: cachedFm, body: cachedBody ?? Fugue<String>());
    }
    // The tree comes back through the ordinary path — the blob IS an ordinary
    // fugue1 blob. The tail is read off the same bytes, and its absence is not
    // an error: it means this note has no frontmatter state yet, which is true
    // of every note until one is written.
    final fm = readFmTail(bytes);
    return (
      fm: fm ?? cachedFm,
      body: await loadOrSeedSequence(fileId, relPath, context: context),
    );
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

  Future<bool> _reconcileBinary(String relPath, {RpcContext? context}) async {
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
      _log.warning(
        'Chunked IO unavailable (no remote storage)',
        data: {'path': LogPath(relPath)},
      );
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
            ? (sent, total) => _emit(
                SyncBlobTransfer(
                  path: relPath,
                  upload: true,
                  sentBytes: sent,
                  totalBytes: total,
                  done: false,
                ),
              )
            : null,
      );
    } finally {
      if (monitor) {
        _emit(
          SyncBlobTransfer(
            path: relPath,
            upload: true,
            sentBytes: bytes.length,
            totalBytes: bytes.length,
            done: true,
          ),
        );
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

    // The file must STILL be there. Existence was checked at the top of this
    // method, then reading, diffing and uploading spent real time — 2 s on a
    // BYO WebDAV backend, longer on mobile — and a rename or delete can land
    // inside that window. Committing now would publish a state for a path that
    // no longer exists, and nothing would ever tombstone it: the delete half of
    // the rename already ran, found no state (this one had not been committed
    // yet) and correctly did nothing. The result is an orphan on every OTHER
    // device — observed in the wild as a stray "Untitled.md" left behind by the
    // ordinary create-then-name flow.
    //
    // Abandoning here loses nothing: the new path reconciles on its own, and a
    // path the server never heard of needs no delete.
    if (!await io.fileExists(absPath)) {
      _log.info(
        'Abandoning reconcile: gone from disk during upload',
        data: {'path': LogPath(relPath)},
      );
      return false;
    }

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

  Future<bool> _reconcileText(String relPath, {RpcContext? context}) async {
    final outcome = await planTextReconcile(relPath, context: context);
    final plan = outcome.plan;
    if (plan == null) return outcome.changed;

    final chunkedIO = _chunkedIOBuilder();
    if (chunkedIO == null) {
      _log.warning(
        'Chunked IO unavailable (no remote storage)',
        data: {'path': LogPath(relPath)},
      );
      return false;
    }
    final swUpload = Stopwatch()..start();
    _log.info('text reconcile upload-begin', data: {'path': LogPath(relPath)});
    final result = await chunkedIO.upload(
      plan.blobBytes,
      _knownChunks(),
      context: context,
    );
    swUpload.stop();
    _log.info(
      'text reconcile upload-done upload=${swUpload.elapsedMilliseconds}ms',
      data: {'path': LogPath(relPath)},
    );
    return commitTextReconcile(
      plan,
      manifestHash: result.manifestHash,
      chunkHashes: result.chunkHashes,
      context: context,
    );
  }

  /// Everything a text reconcile decides before it touches the network.
  ///
  /// Split out so the startup pass can plan a group of files, upload them in
  /// one pair of requests, and commit them — the round-trip shape the binary
  /// path has always had. [_reconcileText] is now this, one upload, and
  /// [commitTextReconcile], in that order; the interactive path behaves
  /// exactly as it did.
  Future<TextReconcileOutcome> planTextReconcile(
    String relPath, {
    RpcContext? context,
  }) async {
    final absPath = '$vaultPath/$relPath';
    final fileId = _fileIdFor(relPath);
    final current = store.get(fileId);

    if (!await io.fileExists(absPath)) {
      if (current == null || current.tombstone) {
        return const TextReconcileOutcome.settled(false);
      }
      final hlc = store.nextHlc();
      store.applyLocal(
        current.copyWith(hlc: hlc, tombstone: true, blobRef: '', sizeBytes: 0),
      );
      await store.persistOne(fileId);
      await fugueStore.remove(fileId);
      return const TextReconcileOutcome.settled(true);
    }

    final swTotal = Stopwatch()..start();
    _log.info('text reconcile begin', data: {'path': LogPath(relPath)});
    final bytes = await io.readFile(absPath);

    // Skip empty new/tombstoned files — see _reconcileBinary. No Fugue seed
    // for a 0-byte note until it actually has content.
    if (bytes.isEmpty && (current == null || current.tombstone)) {
      return const TextReconcileOutcome.settled(false);
    }

    final newText = utf8.decode(bytes, allowMalformed: true);
    _log.info(
      'text reconcile read chars=${newText.length}',
      data: {'path': LogPath(relPath)},
    );

    final swSeed = Stopwatch()..start();
    final ({FmState? fm, Fugue<String> body}) document;
    try {
      document = await loadOrSeedDocument(fileId, relPath, context: context);
    } on UnsupportedBlobFormatException catch (e) {
      // The server holds this file in a format this build cannot read. Pushing
      // anything now would replace it, so the file is left alone entirely —
      // local edits stay on disk and reach the vault once the client is
      // updated. Returning false leaves the state untouched, exactly as an
      // unavailable blob does.
      _log.error(
        'Skipping text reconcile: $e',
        data: {'path': LogPath(relPath)},
      );
      _emit(SyncFileFormatUnsupported(path: relPath));
      return const TextReconcileOutcome.settled(false);
    }
    final oldSequence = document.body;
    swSeed.stop();

    // Frontmatter state travels alongside the text whenever there is any to
    // carry. Purely additive: the tree below holds the whole note either way,
    // so a peer that ignores the tail sees exactly what it sees today.
    final withFm = _fmStore != null;

    // The tree keeps the FULL note, frontmatter region included. That is what
    // makes the tail safe to ignore — the text alone is always the complete
    // answer to "what does this file look like".
    final split = splitFrontmatter(newText);

    _log.info(
      'text reconcile seed-done '
      'elements=${oldSequence.elementCount} '
      'fm=$withFm '
      'seed=${swSeed.elapsedMilliseconds}ms',
      data: {'path': LogPath(relPath)},
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
      deadlineSeconds: FugueTextSync.interactiveDiffBudget,
      oldFugue: oldSequence,
      newText: newText,
      clock: store.fugueClock,
    );

    // The frontmatter half. Diffed against the materialised state rather than
    // a remembered document, so a lost local store cannot make ingest re-add
    // every key and undo deletions that had already propagated (§8.3).
    FmState? newFm;
    var fmChanged = false;
    if (withFm) {
      final base =
          document.fm ??
          FmMapState(
            entries: const {},
            fmHlc: store.nextHlc(),
            trailHlc: store.nextHlc(),
          );
      final diskFm = split.region == null
          ? const FmMap([])
          : parseFrontmatterRegion(
              split.region!,
              // An emptied value keeps the type it had; without this an empty
              // list and an empty string read back the same and the kind flips
              // between devices forever (§6.5).
              priorKinds: _priorKinds(base),
              priorListKeys: _priorListKeys(base),
            );
      newFm = applyDiskFrontmatter(base, diskFm, store.nextHlc());
      fmChanged = materializeFm(newFm) != materializeFm(base);
      // A note that has never had a property carries nothing, and its blob
      // stays byte-for-byte what it is today. Tombstones still count as
      // something to carry, or a peer that missed a delete adds the keys back.
      // Reclaim deletions everyone has already seen — but only here, on a
      // write that is happening anyway. A sweep of its own would rewrite every
      // file in the vault, which is the mass re-upload this design avoids.
      final barrier = _fmGcBarrier();
      final seq = store.serverSeqFor(fileId);
      if (barrier != null && seq != null && seq <= barrier) {
        final pruned = pruneFmTombstones(newFm);
        if (!identical(pruned, newFm)) {
          _log.info(
            'fm gc seq=$seq barrier=$barrier',
            data: {'path': LogPath(relPath)},
          );
          newFm = pruned;
        }
      }
      if (!fmStateIsWorthStoring(newFm)) newFm = null;
    }
    swDiff.stop();
    _log.info(
      'text reconcile diff-done '
      'newElements=${newSequence.elementCount} '
      'diff=${swDiff.elapsedMilliseconds}ms',
      data: {'path': LogPath(relPath)},
    );
    // Unchanged content is a no-op for any TRACKED file. `current` is null
    // when the register is a multi-value conflict (store.get collapses to
    // null on conflict), so check hasConflict too — otherwise rendering the
    // union view to disk would look like a brand-new edit and applyLocal
    // would phantom-collapse the conflict under this device's HLC, diverging
    // peers. Only a genuinely new file (no register at all) falls through.
    if (identical(newSequence, oldSequence) &&
        !fmChanged &&
        (current != null || store.hasConflict(fileId))) {
      return const TextReconcileOutcome.settled(false);
    }

    swTotal.stop();
    _log.info(
      'text reconcile planned chars=${newText.length} '
      'elements=${newSequence.elementCount} '
      'seed=${swSeed.elapsedMilliseconds}ms '
      'diff=${swDiff.elapsedMilliseconds}ms '
      'plan=${swTotal.elapsedMilliseconds}ms',
      data: {'path': LogPath(relPath)},
    );

    return TextReconcileOutcome.needsUpload(
      TextReconcilePlan(
        relPath: relPath,
        fileId: fileId,
        blobBytes: _encodeSequenceBlob(newSequence, fm: newFm),
        sequence: newSequence,
        fm: newFm,
        charCount: newText.length,
      ),
    );
  }

  /// Records what [planTextReconcile] produced, now that its bytes are on the
  /// server. Returns whether the file's state changed.
  ///
  /// The order here is the invariant: the tree is written BEFORE the FileState
  /// that names its blob, so no persisted state ever references a blobRef whose
  /// tree is missing. That is what lets the upload skip the local blob cache —
  /// regeneration from the tree is a complete substitute.
  Future<bool> commitTextReconcile(
    TextReconcilePlan plan, {
    required String manifestHash,
    required List<String> chunkHashes,
    RpcContext? context,
  }) async {
    final relPath = plan.relPath;
    final fileId = plan.fileId;
    final absPath = '$vaultPath/$relPath';
    // Re-read rather than carried through the plan: the upload took real time
    // and a pull may have applied a peer's version of this file inside it.
    final current = store.get(fileId);

    // Last check before any persist — typing during upload aborts
    // here, leaving fugueStore and FileState untouched. Disk still
    // diverges → next reconcile picks the file up.
    context?.cancellationToken?.throwIfCancelled();

    // Same manifest hash as the current FileState — the tree changed
    // (new tombstones) but bytes didn't. Cache the tree, skip the
    // FileState bump.
    if (current != null &&
        current.blobRef == manifestHash &&
        !current.tombstone) {
      await _persistDocument(fileId, plan.sequence, plan.fm);
      return false;
    }

    // The file must STILL be there. Existence was checked at the top of this
    // method, then reading, diffing and uploading spent real time — 2 s on a
    // BYO WebDAV backend, longer on mobile — and a rename or delete can land
    // inside that window. Committing now would publish a state for a path that
    // no longer exists, and nothing would ever tombstone it: the delete half of
    // the rename already ran, found no state (this one had not been committed
    // yet) and correctly did nothing. The result is an orphan on every OTHER
    // device — observed in the wild as a stray "Untitled.md" left behind by the
    // ordinary create-then-name flow.
    //
    // Abandoning here loses nothing: the new path reconciles on its own, and a
    // path the server never heard of needs no delete.
    if (!await io.fileExists(absPath)) {
      _log.info(
        'Abandoning reconcile: gone from disk during upload',
        data: {'path': LogPath(relPath)},
      );
      return false;
    }

    await _persistDocument(fileId, plan.sequence, plan.fm);

    final hlc = store.nextHlc();
    store.applyLocal(
      FileState(
        fileId: fileId,
        path: relPath,
        blobRef: manifestHash,
        sizeBytes: plan.blobBytes.length,
        hlc: hlc,
        tombstone: false,
        chunks: chunkHashes,
      ),
    );
    await store.persistOne(fileId);
    // The signature, and what it is evidence for. [reconcileWithDisk] records
    // this at its tail for the interactive path, but the startup pass calls
    // plan/commit directly so it can batch its uploads — without this, every
    // note it pushed would be read in full again on the next start.
    final postStat = await io.statFile(absPath);
    if (postStat != null) {
      _setStat(
        relPath,
        postStat.mtimeMs,
        postStat.sizeBytes,
        blobRef: manifestHash,
      );
    }
    return true;
  }

  /// Serialises [seq] as a chunked blob via [ChunkedBlobIO]. Returns
  /// `null` when no remote storage is configured (offline-only run).
  /// Exposed for the conflict-resolution path in the engine; the same
  /// upload is used internally by [_reconcileText].
  Future<({String manifestHash, List<String> chunkHashes, int blobSize})?>
  uploadSequenceBlob(Fugue<String> seq, {FmState? fm, RpcContext? context}) =>
      _uploadSequenceBlob(seq, fm: fm, context: context);

  /// Exposed for the conflict-resolution path in the engine — needs
  /// to probe arbitrary blob bytes when reconstructing a Fugue
  /// loser-state during 3-way merge.
  Fugue<String>? tryDecodeFugueBlob(Uint8List bytes) =>
      _tryDecodeFugueBlob(bytes);

  /// Persists both halves. The body tree always; the frontmatter only when
  /// this file is a composite document.
  Future<void> _persistDocument(
    String fileId,
    Fugue<String> body,
    FmState? fm,
  ) async {
    fugueStore.set(fileId, body);
    await fugueStore.persistOne(fileId);
    if (fm == null) return;
    final fmStore = _fmStore;
    if (fmStore == null) return;
    fmStore.set(fileId, fm);
    await fmStore.persistOne(fileId);
  }

  /// Keys the state currently holds as a LIST, for §6.5. Separate from
  /// [_priorKinds] because a list has no [ScalarKind] to report, which is
  /// precisely why an emptied one used to come back as a string.
  Set<String> _priorListKeys(FmState state) {
    if (state is! FmMapState) return const {};
    return {
      for (final e in state.entries.entries)
        if (e.value.value is FmListValue) e.key,
    };
  }

  /// The kind each key currently holds, for §6.5.
  Map<String, ScalarKind> _priorKinds(FmState state) {
    if (state is! FmMapState) return const {};
    return {
      for (final e in state.entries.entries)
        if (e.value.value case final FmScalarValue v) e.key: v.kind,
    };
  }

  /// Serialises a tree (plus its frontmatter tail) to the exact bytes that go
  /// on the wire. Separated from the upload so a caller can plan several files
  /// and send them together.
  Uint8List _encodeSequenceBlob(Fugue<String> seq, {FmState? fm}) {
    final swEncode = Stopwatch()..start();
    // Magic-prefixed compact binary — self-identifying, ~2 B/char, so peers
    // decode it back with FugueStore.tryDecodeBlob and old clients reject it.
    var bytes = FugueStore.encodeBlob(seq);
    // Frontmatter state rides after the tree. A reader that does not know
    // about it decodes the tree and stops before reaching this, which is why
    // it costs nothing to add.
    if (fm != null) bytes = appendFmTail(bytes, fm);
    swEncode.stop();
    if (swEncode.elapsedMilliseconds > 50 || bytes.length > 256 * 1024) {
      _log.info(
        'fugue encode: elements=${seq.elementCount} bytes=${bytes.length} '
        'encode=${swEncode.elapsedMilliseconds}ms',
      );
    }
    return bytes;
  }

  Future<({String manifestHash, List<String> chunkHashes, int blobSize})?>
  _uploadSequenceBlob(
    Fugue<String> seq, {
    FmState? fm,
    RpcContext? context,
  }) async {
    final chunkedIO = _chunkedIOBuilder();
    if (chunkedIO == null) return null;
    final bytes = _encodeSequenceBlob(seq, fm: fm);
    final result = await chunkedIO.upload(
      bytes,
      _knownChunks(),
      context: context,
      // These bytes ARE the tree, which [_persistDocument] writes a few lines
      // below — BEFORE the FileState that names this blob. So no persisted
      // state ever references a blobRef whose tree is missing, which is what
      // makes regeneration a complete substitute for caching them here.
      //
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
