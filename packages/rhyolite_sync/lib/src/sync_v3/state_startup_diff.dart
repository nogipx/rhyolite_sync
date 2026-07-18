import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:uuid/uuid.dart';

import 'path_normalize.dart';

class StateStartupDiffResult {
  final int newFiles;
  final int modifiedFiles;

  /// File ids in the store whose path is no longer on disk. The engine
  /// treats these as candidate deletes (or simply missing).
  final List<String> missingFileIds;

  /// Binaries skipped this scan because they exceed the per-file size limit.
  /// The engine emits [SyncFileSizeBlocked] for each and seeds the shared
  /// blocked-set so a later delete/shrink can emit [SyncFileSizeUnblocked].
  final List<({String path, int sizeBytes, int limitBytes})> blocked;

  /// Files skipped this scan because their extension is on the per-device
  /// type-exclusion denylist. The engine emits [SyncFileTypeExcluded] for each.
  final List<({String path, String extension})> excluded;

  const StateStartupDiffResult({
    required this.newFiles,
    required this.modifiedFiles,
    required this.missingFileIds,
    this.blocked = const [],
    this.excluded = const [],
  });
}

/// Reconciles disk against the [FileStateStore].
///
/// For each file on disk:
/// - If not in store → new FileState, upload blob to remote.
/// - If in store but blobRef differs → updated FileState, upload blob.
///
/// For each fileId in store whose path is missing from disk: returned in
/// [StateStartupDiffResult.missingFileIds]. The engine decides whether
/// these are real deletes (so emit tombstones) or just files awaiting
/// pull from server.
class StateStartupDiff {
  final FileStateStore store;
  final LocalBlobStore blobStore;
  final IBlobStorage? remoteBlobStorage;
  final IPlatformIO io;
  final String vaultPath;
  final String vaultId;
  final String nodeId;

  /// Logical clock the engine maintains. Diff advances it for each state
  /// it creates / updates.
  Hlc Function() readClock;
  void Function(Hlc) writeClock;

  /// Optional logger used to surface progress during long blob uploads.
  final LogScope log;

  /// Optional progress hook. Fired after each chunk of blob uploads with
  /// (completed, total). Engine wires this to a [SyncStartupBlobUploadProgress]
  /// event so the UI can show a counter without polling.
  final void Function(int completed, int total)? onUploadProgress;

  /// Number of files uploaded in parallel. Defaults to 4 — single-thread
  /// CPU is still the bottleneck on dart2js, but a small pool hides
  /// network ack latency behind the next file's chunker/encrypt.
  final int uploadConcurrency;

  /// Reconciles a single text file through the engine's [DiskReconciler]
  /// (the Fugue path), returning whether it produced a state change.
  ///
  /// When provided, text files are routed here instead of being uploaded as
  /// raw bytes. Uploading text as raw diverged from the runtime Fugue
  /// format, so every startup saw all text files as "changed" (disk sha
  /// never matches the Fugue blob hash) and re-pushed them — a putStates
  /// storm. The reconciler skips the state bump when the Fugue blob is
  /// unchanged, so an unedited text file produces no push. Null falls back
  /// to the legacy raw path (binary-style), kept for tests / no-engine use.
  final Future<bool> Function(String relPath)? reconcileText;

  /// Per-vault blob-id HMAC subkey (null → raw sha256 for the no-engine / test
  /// path). Used BOTH for the binary fast-path change detection AND for the
  /// binary upload's [ChunkedBlobIO], so a file's uploaded chunk ids match the
  /// scheme its change detection recomputes — otherwise every binary looks
  /// changed and either re-uploads every startup or never persists.
  final Uint8List? _blobIdKey;
  final String Function(Uint8List) _hasher;

  StateStartupDiff({
    required this.store,
    required this.blobStore,
    required this.io,
    required this.vaultPath,
    required this.vaultId,
    required this.nodeId,
    required this.readClock,
    required this.writeClock,
    this.remoteBlobStorage,
    this.onUploadProgress,
    this.uploadConcurrency = 4,
    this.reconcileText,
    this.sigStore,
    Uint8List? blobIdKey,
    int? Function()? maxFileSizeBytes,
    Set<String> Function()? excludedExtensions,
    LogScope? logger,
  })  : _blobIdKey = blobIdKey,
        _hasher = ChunkedBlobIO.hasherFor(blobIdKey),
        _maxFileSizeBytes = maxFileSizeBytes ?? (() => null),
        _excludedExtensions = excludedExtensions ?? (() => const <String>{}),
        log = logger ?? LogScope.noop;

  /// Live per-device denylist of extensions (no dot) not synced on this device.
  final Set<String> Function() _excludedExtensions;

  /// Current per-file upload size limit in bytes (null = unlimited). Over-limit
  /// binaries are skipped (not read/chunked/uploaded) to avoid re-freezing on
  /// every startup; the server would reject the blob anyway.
  final int? Function() _maxFileSizeBytes;

  /// Persisted per-file disk signatures. When present, an unchanged text file
  /// (same mtime+size as last sync, with a live state) is skipped before the
  /// reconcile delegate — so it is not read, not Fugue-diffed, and not counted
  /// in the startup upload progress. Null → every text file is delegated
  /// (pre-signature behavior).
  final StatSigStore? sigStore;

  Future<StateStartupDiffResult> call() async {
    var newFiles = 0;
    var modifiedFiles = 0;

    final diskFiles = await io.listFiles(vaultPath);
    final diskRelPaths = <String>{};
    log.info(
      'StartupDiff: scanning ${diskFiles.length} file(s) on disk against '
      '${store.fileIds.length} tracked',
    );

    final swScan = Stopwatch()..start();
    var shaSkipped = 0;
    var processedSinceYield = 0;

    // Per-category pending counters, to surface the "text files always
    // re-upload because fast-path compares disk content to Fugue blob
    // hash" pathology directly in the scan summary.
    var pendingText = 0;
    var pendingBinary = 0;
    var pendingNew = 0;
    var pendingTombstoneRevive = 0;
    var pendingMissingChunks = 0;
    final typeDetector = const FileTypeDetector();
    final blocked = <({String path, int sizeBytes, int limitBytes})>[];
    final excluded = <({String path, String extension})>[];
    final denylist = _excludedExtensions();

    // First pass: scan disk, collect which files need upload and read
    // their bytes. We don't upload yet so we know how many to push and
    // can emit accurate per-file progress.
    final pending =
        <
          ({String relPath, String fileId, Uint8List bytes, FileState? current})
        >[];
    // Text files reconciled through the Fugue delegate (see [reconcileText]).
    final pendingTextPaths = <String>[];
    for (final absPath in diskFiles) {
      // Yield every 16 files so the host event loop gets a turn —
      // sha256 of a 1MB file on dart2js is ~50-100ms of synchronous CPU,
      // and listFiles can return thousands of paths. Without yields the
      // whole scan pins the main thread and Obsidian's UI freezes
      // through the entire StartupDiff phase.
      processedSinceYield += 1;
      if (processedSinceYield >= 16) {
        processedSinceYield = 0;
        await Future<void>.delayed(Duration.zero);
      }

      final relPath = normalizeVaultPath(absPath.substring(vaultPath.length + 1));
      if (_isHidden(relPath)) continue;
      diskRelPaths.add(relPath);

      // Type admission (per-device denylist): skip excluded extensions — not
      // read/uploaded, and no stat signature written, so a re-included type is
      // re-evaluated on the next scan. Reported so the engine surfaces the list.
      if (denylist.isNotEmpty) {
        final ext = FileTypeDetector.extensionOf(relPath);
        if (ext.isNotEmpty && denylist.contains(ext)) {
          excluded.add((path: relPath, extension: ext));
          continue;
        }
      }

      // Text files go through the Fugue reconciler, not the raw sha
      // fast-path below: disk sha never equals the Fugue blob hash, so the
      // fast-path would never skip and the raw upload would diverge from
      // the runtime format. The reconciler reads/diffs the file itself and
      // only bumps state when the Fugue blob actually changed.
      if (reconcileText != null && typeDetector.isText(relPath)) {
        final fileId = _deterministicFileId(relPath);
        // Cross-restart skip: on-disk signature unchanged since the last sync
        // AND we still hold a live (non-tombstone) state for it → nothing to
        // do. Don't read or Fugue-diff it, and don't count it in progress.
        // Same mtime+size trust the reconciler's short-circuit already uses.
        final sig = sigStore?.get(fileId);
        if (sig != null) {
          final current = store.get(fileId);
          final stat = await io.statFile(absPath);
          if (current != null &&
              !current.tombstone &&
              stat != null &&
              stat.mtimeMs == sig.mtimeMs &&
              stat.sizeBytes == sig.sizeBytes) {
            shaSkipped += 1;
            continue;
          }
          // Had a signature but couldn't skip — surface why, so a set of files
          // that re-delegate every startup is diagnosable (conflict register,
          // tombstone, or an actual mtime/size drift).
          final reason = current == null
              ? (store.hasConflict(fileId) ? 'conflict' : 'no-state')
              : current.tombstone
                  ? 'tombstone'
                  : stat == null
                      ? 'no-stat'
                      : stat.sizeBytes != sig.sizeBytes
                          ? 'size disk=${stat.sizeBytes} sig=${sig.sizeBytes}'
                          : 'mtime disk=${stat.mtimeMs} sig=${sig.mtimeMs}';
          log.info('StartupDiff: text re-delegated path=$relPath reason=$reason');
        }
        pendingTextPaths.add(relPath);
        continue;
      }

      // Size admission: skip binaries over the plan's per-file limit — don't
      // read or chunk them (that re-freezes the UI every startup) and the
      // server would reject the blob anyway.
      final limit = _maxFileSizeBytes();
      if (limit != null && limit > 0) {
        final stat = await io.statFile(absPath);
        if (stat != null && stat.sizeBytes > limit) {
          log.info('StartupDiff: skip oversize $relPath '
              'size=${stat.sizeBytes} limit=$limit');
          blocked.add((
            path: relPath,
            sizeBytes: stat.sizeBytes,
            limitBytes: limit,
          ));
          continue;
        }
      }

      final fileId = _deterministicFileId(relPath);
      final current = store.get(fileId);

      final Uint8List bytes;
      try {
        bytes = await io.readFile(absPath);
      } catch (_) {
        continue;
      }

      // Skip empty files with no live state — mirrors DiskReconciler. Obsidian
      // mints 0-byte notes on "new note"; they shouldn't create sync records.
      // A legacy already-synced empty file (current live, sizeBytes 0) falls
      // through to the fast-path skip below and stays untouched.
      if (bytes.isEmpty && (current == null || current.tombstone)) {
        continue;
      }

      // Fast-path checks. Three patterns to short-circuit:
      //
      //   (a) Empty file: bytes are zero and the stored state reflects
      //       zero size. No chunks, no upload, no work.
      //
      //   (b) Single-chunk file: stored chunks list is exactly one
      //       hash, compare it against sha256 of the whole disk content.
      //       Cheap and exact.
      //
      //   (c) Multi-chunk file: stored chunks list is N>1 hashes. If
      //       disk size doesn't match state.sizeBytes the file has
      //       definitely changed — fall through to re-upload. If sizes
      //       match, re-chunk the disk content locally and compare the
      //       full ordered hash list. ContentDefinedChunker is
      //       deterministic, so an unchanged file produces an identical
      //       chunk list. This catches the large-binary case (PDFs,
      //       attachments) where the previous logic re-uploaded the
      //       whole multi-megabyte file every startup.
      if (current != null && !current.tombstone) {
        // (a) Empty file.
        if (bytes.isEmpty && current.sizeBytes == 0) {
          shaSkipped += 1;
          continue;
        }

        final wholeHash = _hasher(bytes);

        // (b) Single-chunk.
        if (current.chunks.length == 1 && current.chunks.first == wholeHash) {
          shaSkipped += 1;
          continue;
        }

        // (c) Multi-chunk: re-chunk if size matches.
        if (current.chunks.length > 1 && current.sizeBytes == bytes.length) {
          final result = await ContentDefinedChunker(blobIdHasher: _hasher)(bytes);
          final freshHashes = result.manifest.chunks
              .map((c) => c.hash)
              .toList(growable: false);
          if (freshHashes.length == current.chunks.length) {
            var allMatch = true;
            for (var i = 0; i < freshHashes.length; i++) {
              if (freshHashes[i] != current.chunks[i]) {
                allMatch = false;
                break;
              }
            }
            if (allMatch) {
              shaSkipped += 1;
              continue;
            }
          }
        }

        // Diagnostic: explain why no fast path matched.
        final isText = typeDetector.isText(relPath);
        if (isText) {
          pendingText++;
        } else {
          pendingBinary++;
        }
        if (current.chunks.isEmpty) pendingMissingChunks++;

        final chunkPrev = current.chunks.isEmpty
            ? '<empty>'
            : current.chunks.first.substring(0, 8);
        final reason = current.chunks.isEmpty
            ? 'chunks-empty'
            : current.chunks.length == 1 && current.chunks.first != wholeHash
                ? (isText
                    ? 'text-blob-hash-vs-content-hash-mismatch'
                    : 'single-chunk-hash-mismatch')
                : current.sizeBytes != bytes.length
                    ? 'size-mismatch'
                    : 'chunk-list-mismatch';
        log.info(
          'StartupDiff: pending path=$relPath isText=$isText reason=$reason '
          'diskBytes=${bytes.length} diskHash=${wholeHash.substring(0, 8)} '
          'chunks.len=${current.chunks.length} chunks[0]=$chunkPrev '
          'state.blobRef=${current.blobRef.length < 8 ? current.blobRef : current.blobRef.substring(0, 8)} '
          'state.sizeBytes=${current.sizeBytes}',
        );
      } else {
        // Two distinct sub-cases:
        //   (i)  current == null — store has no entry for this fileId.
        //        Either a real new file, or fileId churn (path
        //        normalization, vaultId change between sessions).
        //   (ii) current != null && current.tombstone — store has a
        //        tombstoned entry, but the file is back on disk. This
        //        is the "revive" case: previous delete propagated, file
        //        re-created. Upload will un-tombstone locally but
        //        whether that sticks depends on HLC vs server.
        final isText = typeDetector.isText(relPath);
        if (isText) {
          pendingText++;
        } else {
          pendingBinary++;
        }
        if (current == null) {
          pendingNew++;
          log.info(
            'StartupDiff: pending-new path=$relPath isText=$isText '
            'fileId=$fileId diskBytes=${bytes.length}',
          );
        } else {
          // Tombstoned but on disk.
          pendingTombstoneRevive++;
          log.info(
            'StartupDiff: pending-revive path=$relPath isText=$isText '
            'fileId=$fileId diskBytes=${bytes.length} '
            'state.hlc=${current.hlc} state.path=${current.path} '
            'state.blobRef=${current.blobRef.length < 8 ? current.blobRef : current.blobRef.substring(0, 8)} '
            'state.sizeBytes=${current.sizeBytes}',
          );
        }
      }

      pending.add((
        relPath: relPath,
        fileId: fileId,
        bytes: bytes,
        current: current,
      ));
    }
    swScan.stop();
    log.info(
      'StartupDiff: scan done in ${swScan.elapsedMilliseconds}ms — '
      '$shaSkipped sha-skipped, ${pending.length} binary-pending '
      '(text=$pendingText binary=$pendingBinary '
      'new=$pendingNew tombstone-revive=$pendingTombstoneRevive '
      'chunks-empty=$pendingMissingChunks), '
      '${pendingTextPaths.length} text-delegated',
    );

    // Upload + manifest write per file. ChunkedBlobIO handles chunk
    // dedup against [knownChunks]; we keep growing the set as we go.
    final chunkedIO = remoteBlobStorage == null
        ? null
        : ChunkedBlobIO(
            blobStore: blobStore,
            remoteBlobStorage: remoteBlobStorage!,
            vaultId: vaultId,
            blobIdKey: _blobIdKey,
          );

    final knownChunks = <String>{};
    for (final state in store.all) {
      knownChunks.addAll(state.chunks);
    }

    // One job per pending unit: binary files upload their raw blob here;
    // text files are reconciled through the Fugue delegate. Both run in the
    // same bounded pool so progress is a single counter.
    final jobs = <Future<void> Function()>[];
    if (chunkedIO != null) {
      for (final item in pending) {
        jobs.add(() async {
          final result = await chunkedIO.upload(item.bytes, knownChunks);
          // knownChunks is a plain Set — additions from concurrent
          // workers race-free under Dart's single-threaded event loop.
          // Mid-upload concurrent files may submit the same chunk hash;
          // BlobTransferHub dedups so each chunk is uploaded once.
          knownChunks.addAll(result.chunkHashes);
          final hlc = store.nextHlc();
          if (item.current == null) {
            store.upsert(
              FileState(
                fileId: item.fileId,
                path: item.relPath,
                blobRef: result.manifestHash,
                sizeBytes: item.bytes.length,
                hlc: hlc,
                chunks: result.chunkHashes,
              ),
            );
            newFiles++;
          } else {
            store.upsert(
              item.current!.copyWith(
                path: item.relPath,
                blobRef: result.manifestHash,
                sizeBytes: item.bytes.length,
                hlc: hlc,
                tombstone: false,
                chunks: result.chunkHashes,
              ),
            );
            modifiedFiles++;
          }
        });
      }
    }
    final reconcile = reconcileText;
    if (reconcile != null) {
      for (final relPath in pendingTextPaths) {
        jobs.add(() async {
          // The reconciler writes its own FileState (Fugue blob) and only
          // bumps when the content actually changed — an unedited text file
          // produces no push, which is the whole point of this path.
          final changed = await reconcile(relPath);
          if (changed) modifiedFiles++;
        });
      }
    }

    final total = jobs.length;
    if (total > 0) {
      log.info(
        'StartupDiff: processing $total file(s) '
        '(${pending.length} binary upload, ${pendingTextPaths.length} text '
        'reconcile) with concurrency=$uploadConcurrency…',
      );
      onUploadProgress?.call(0, total);
      final swatch = Stopwatch()..start();
      var done = 0;
      var nextIndex = 0;

      // Bounded-concurrency worker pool. CPU work (CDC chunker, encrypt,
      // Fugue diff) is single-threaded on dart2js, but each job spends most
      // of its wall time on network ack — a few in flight hides that latency.
      // BlobTransferHub caps inner RPCs and dedups shared chunk hashes.
      Future<void> worker() async {
        while (true) {
          final i = nextIndex++;
          if (i >= jobs.length) return;
          await jobs[i]();
          done++;
          onUploadProgress?.call(done, total);
        }
      }

      final workerCount = uploadConcurrency.clamp(1, total);
      await Future.wait(List.generate(workerCount, (_) => worker()));
      log.info(
        'StartupDiff: processing of $total file(s) done in '
        '${swatch.elapsed.inSeconds}s',
      );
    }

    final missingFileIds = <String>[];
    for (final fileId in store.fileIds.toList()) {
      final state = store.get(fileId);
      if (state == null || state.tombstone) continue;
      if (!diskRelPaths.contains(state.path)) {
        missingFileIds.add(fileId);
      }
    }

    return StateStartupDiffResult(
      newFiles: newFiles,
      modifiedFiles: modifiedFiles,
      missingFileIds: missingFileIds,
      blocked: blocked,
      excluded: excluded,
    );
  }

  String _deterministicFileId(String relativePath) =>
      const Uuid().v5(vaultId, normalizeVaultPath(relativePath));

  static bool _isHidden(String relPath) =>
      relPath.split('/').any((s) => s.startsWith('.'));
}
