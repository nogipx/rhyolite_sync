import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

import 'disk_reconciler.dart';
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

  /// Files skipped this scan because they fall outside the per-device
  /// [PathScope]. The engine emits [SyncFileOutOfScope] for each.
  final List<String> outOfScope;

  /// Upload groups this pass gave up on and carried past.
  ///
  /// Non-zero means some files are still unsynced despite the pass finishing:
  /// they stay pending and the next pass retries them.
  final int skippedGroups;

  /// How many files the scan actually saw on disk.
  ///
  /// The one signal that separates "the user deleted things" from "the vault
  /// did not mount". Both look identical through [missingFileIds] alone, and
  /// acting on the second would broadcast a mass delete to every device.
  final int diskFileCount;

  /// Set when the blob backend refused this device outright.
  ///
  /// Carried out rather than thrown, so everything the pass banked before the
  /// refusal still counts and the engine still starts. But it must leave the
  /// pass SOMEHOW: a refusal is not a skipped group, it is every future group
  /// skipped, and swallowing it is how a vault with a mistyped storage
  /// password went on pulling on schedule, showing a green dot, while not one
  /// byte it wrote ever left the device.
  final String? storageRefused;

  const StateStartupDiffResult({
    required this.newFiles,
    required this.modifiedFiles,
    required this.missingFileIds,
    this.blocked = const [],
    this.excluded = const [],
    this.outOfScope = const [],
    this.diskFileCount = 0,
    this.skippedGroups = 0,
    this.storageRefused,
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

  /// How long the server may be left behind what has actually been uploaded.
  ///
  /// A time budget, not a file count. Files are not comparable: two hundred
  /// notes is a couple of seconds and two hundred PDFs is ten minutes, so a
  /// count says nothing about the thing that matters — how stale the server
  /// is allowed to get. This codebase has made that mistake before and fixed
  /// it in the cooperative yielder for the same reason; the comment on the
  /// scan's yield still explains why.
  ///
  /// Ten seconds costs at most six round trips a minute during a pass, and
  /// bounds what an interruption throws away to the last ten seconds of work
  /// rather than the whole hour.
  final Duration publishInterval;

  /// Called at most once per [publishInterval], so the states of what has been
  /// uploaded can be published while the rest is still going.
  ///
  /// The engine used to push only after this whole pass returned. On a large
  /// vault that is an hour in which the server learns nothing — one report
  /// showed 780 blob uploads and not one state record — and an interruption
  /// anywhere in it left the server exactly as empty as before.
  ///
  /// Awaited, so a slow publish paces the pass rather than piling up behind
  /// it. Failures are the engine's to swallow: this pass must not end because
  /// a push was refused.
  final Future<void> Function()? onProgressPublished;

  /// Reports the DISK SCAN's progress, before any upload begins.
  ///
  /// The scan walks every file and hashes the ones whose signature moved. On a
  /// large vault that is a minute of work during which the engine emitted
  /// nothing at all — so the UI could say nothing true, and the host's health
  /// check, which reads silence as death, tore the engine down mid-scan and
  /// made the next attempt start the same minute over.
  ///
  /// Fired on a time budget rather than per file: the point is a heartbeat,
  /// and one event per file on a 9000-file vault is thousands of no-ops
  /// competing for the thread the scan is already saturating.
  final void Function(int scanned, int total)? onScanProgress;

  /// Reports ONE file's upload as its chunks go out, so the active-transfers
  /// list can name what is moving.
  ///
  /// [onUploadProgress] above is a file counter; it says 40 of 251 and nothing
  /// about the 27 MB one that has held position 41 for a minute. The
  /// interactive reconcile has narrated large files all along — this path,
  /// which is the one a re-upload of the whole vault takes, did not.
  final void Function(String relPath, int sent, int total, bool done)?
  onFileTransfer;

  /// Files per upload request-pair. The round trips a group costs no longer
  /// scale with its size, so a small group only means more of them; this is
  /// the download side's [_prefetchGroupSize] read backwards.
  static const int _uploadGroupSize = 8;

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

  /// The two halves of [reconcileText], so a group of notes can share one pair
  /// of upload requests instead of paying two each.
  ///
  /// Supplied together or not at all; without them this falls back to
  /// [reconcileText] one file at a time, which is what an offline run or a
  /// test with no remote storage gets.
  final Future<TextReconcileOutcome> Function(String relPath)?
  planTextReconcile;
  final Future<bool> Function(
    TextReconcilePlan plan,
    String manifestHash,
    List<String> chunkHashes,
  )?
  commitTextReconcile;

  /// Per-vault blob-id HMAC subkey (null → raw sha256 for the no-engine / test
  /// path). Used BOTH for the binary fast-path change detection AND for the
  /// binary upload's [ChunkedBlobIO], so a file's uploaded chunk ids match the
  /// scheme its change detection recomputes — otherwise every binary looks
  /// changed and either re-uploads every startup or never persists.
  final Uint8List? _blobIdKey;
  final String Function(Uint8List) _hasher;

  /// Per-vault record-id HMAC subkey ([VaultCipher.deriveRecordIdKey]). MUST
  /// match the engine/reconciler scheme: change detection here does
  /// `store.get(_deterministicFileId(relPath))`, and the store is keyed by the
  /// engine's keyed id. With the old unkeyed uuid.v5 the lookup always missed,
  /// so every binary looked new — re-uploaded and pushed under a second, wrong
  /// fileId (split-brain vs the runtime keyed record). Null → legacy uuid.v5
  /// (no-engine / test path).
  final Uint8List? _recordIdKey;

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
    this.onScanProgress,
    this.onProgressPublished,
    this.publishInterval = const Duration(seconds: 10),
    this.onFileTransfer,
    this.uploadConcurrency = 4,
    this.reconcileText,
    this.planTextReconcile,
    this.commitTextReconcile,
    this.sigStore,
    Uint8List? blobIdKey,
    Uint8List? recordIdKey,
    int? Function()? maxFileSizeBytes,
    Set<String> Function()? excludedExtensions,
    PathScope Function()? pathScope,
    Set<String> Function()? forcedBinaryExtensions,
    LogScope? logger,
  }) : _blobIdKey = blobIdKey,
       _recordIdKey = recordIdKey,
       _hasher = ChunkedBlobIO.hasherFor(blobIdKey),
       _maxFileSizeBytes = maxFileSizeBytes ?? (() => null),
       _excludedExtensions = excludedExtensions ?? (() => const <String>{}),
       _pathScope = pathScope ?? (() => PathScope.everything),
       _forcedBinaryExtensions =
           forcedBinaryExtensions ?? (() => const <String>{}),
       log = logger ?? LogScope.noop;

  /// Live per-device denylist of extensions (no dot) not synced on this device.
  final Set<String> Function() _excludedExtensions;

  /// Live per-device folder filter. Out-of-scope paths are not read or
  /// uploaded, and leave no stat signature — so widening the scope makes the
  /// next scan re-evaluate them from scratch.
  final PathScope Function() _pathScope;

  /// Live vault-global set of extensions (no dot) forced onto the binary path.
  final Set<String> Function() _forcedBinaryExtensions;

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

  /// Per-file scan lines kept before the rest are counted instead of logged.
  static const int _maxScanSamples = 20;

  /// How often the scan reports where it has got to.
  ///
  /// A heartbeat, not a progress bar: often enough that nothing watching can
  /// mistake the scan for a hang, rare enough to cost nothing on the thread
  /// the scan is already saturating.
  static const Duration _scanHeartbeat = Duration(milliseconds: 500);

  /// Consecutive group failures that end a pass.
  ///
  /// One is a transient; a run of them is systemic and every remaining group
  /// would fail identically.
  static const int _maxConsecutiveGroupFailures = 5;

  Future<StateStartupDiffResult> call() async {
    var newFiles = 0;
    var modifiedFiles = 0;
    var skippedGroups = 0;
    String? refused;

    final diskFiles = await io.listFiles(vaultPath);
    final diskRelPaths = <String>{};
    log.info(
      'StartupDiff: scanning ${diskFiles.length} file(s) on disk against '
      '${store.fileIds.length} tracked',
    );

    // Per-file scan diagnostics are SAMPLED.
    //
    // They used to be unconditional, and on a first sync every file is new —
    // so one report's log was 40322 of these lines out of 40988, 98% of
    // everything the device had recorded. That is not a cost in disk alone:
    // it pushed whole sessions out of the rotation, and two other faults in
    // that same report could not be diagnosed because the segment holding
    // them had been evicted by this line. A diagnostic that destroys the
    // diagnosis is worse than none.
    //
    // A sample keeps what the line was for — seeing WHICH files, with sizes —
    // while the summary at the end of the scan carries the counts, which is
    // the part that was ever true in bulk.
    var scanSamples = 0;
    bool sampleScanLine() => ++scanSamples <= _maxScanSamples;

    final swScan = Stopwatch()..start();
    final scanYielder = TimeBudgetYielder();
    final scanBeat = Stopwatch()..start();
    var scanned = 0;
    var shaSkipped = 0;

    // Per-category pending counters, to surface the "text files always
    // re-upload because fast-path compares disk content to Fugue blob
    // hash" pathology directly in the scan summary.
    var pendingText = 0;
    var pendingBinary = 0;
    var pendingNew = 0;
    var pendingTombstoneRevive = 0;
    var pendingMissingChunks = 0;
    final typeDetector = FileTypeDetector(
      extraBinaryExtensions: _forcedBinaryExtensions(),
    );
    final blocked = <({String path, int sizeBytes, int limitBytes})>[];
    final excluded = <({String path, String extension})>[];
    final outOfScope = <String>[];
    final denylist = _excludedExtensions();
    final scope = _pathScope();

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
      // Yield so the host event loop gets a turn — sha256 of a 1MB file on
      // dart2js is ~50-100ms of synchronous CPU, listFiles can return
      // thousands of paths, and without yields the whole scan pins the main
      // thread and Obsidian's UI freezes through the entire StartupDiff phase.
      //
      // Measured in time, not files: the 16 this used to count was one guess
      // covering both a file skipped on its signature and one hashed in full.
      await scanYielder.maybeYield();
      scanned++;
      if (onScanProgress != null &&
          (scanBeat.elapsed >= _scanHeartbeat || scanned == diskFiles.length)) {
        scanBeat.reset();
        onScanProgress!(scanned, diskFiles.length);
      }

      final relPath = normalizeVaultPath(
        absPath.substring(vaultPath.length + 1),
      );
      if (_isHidden(relPath)) continue;
      diskRelPaths.add(relPath);

      // Path admission (per-device folder filter): out of scope means the file
      // is not read, hashed or uploaded. Recorded in [diskRelPaths] first, so
      // an out-of-scope file that IS on disk never lands in [missingFileIds].
      if (!scope.allows(relPath)) {
        outOfScope.add(relPath);
        continue;
      }

      // Type admission (per-device denylist): skip excluded extensions — not
      // read/uploaded, and no stat signature written, so a re-included type is
      // re-evaluated on the next scan. Reported so the engine surfaces the list.
      if (isNeverSynced(relPath)) continue;
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
          log.info(
            'StartupDiff: text re-delegated reason=$reason',
            data: {'path': LogPath(relPath)},
          );
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
          log.info(
            'StartupDiff: skip oversize '
            'size=${stat.sizeBytes} limit=$limit',
            data: {'path': LogPath(relPath)},
          );
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

      // Cross-restart skip for BINARIES, the same one text has had.
      //
      // Without it every tracked binary is READ IN FULL on every scan, and a
      // multi-chunk one is re-chunked on top of that, purely to conclude it
      // has not changed. That cost is paid by tracked files, so the scan gets
      // slower the more of the vault is synced — one report shows it climbing
      // from 24s to 46s as the tracked count went from 392 to 6560, on a scan
      // that runs at every single start.
      //
      // mtime+size is a weaker signal than re-hashing, and knowingly so: it is
      // the trust the reconciler's own short-circuit and the text path above
      // already run on. A file edited without its mtime moving is missed here
      // and caught by the next real change to it.
      // Cross-restart skip for BINARIES, the same one text has had.
      //
      // Without it every tracked binary is READ IN FULL on every scan, and a
      // multi-chunk one is re-chunked on top of that, purely to conclude it
      // has not changed. That cost is paid by tracked files, so the scan gets
      // slower the more of the vault is synced — one report shows it climbing
      // from 24s to 46s as the tracked count went from 392 to 6560, on a scan
      // that runs at every single start.
      //
      // mtime+size is a weaker signal than re-hashing, and knowingly so: it is
      // the trust the reconciler's own short-circuit and the text path above
      // already run on. A file edited without its mtime moving is missed here
      // and caught by the next real change to it.
      final binSig = sigStore?.get(fileId);
      if (binSig != null && current != null && !current.tombstone) {
        final stat = await io.statFile(absPath);
        if (stat != null &&
            stat.mtimeMs == binSig.mtimeMs &&
            stat.sizeBytes == binSig.sizeBytes) {
          shaSkipped += 1;
          continue;
        }
      }

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
        // Whatever the fast path concludes below, this file has just been
        // read and its stat is what it is — so record it. Without this the
        // signature only ever existed for text, and every binary paid a full
        // read on every scan forever.
        Future<void> rememberSig() async {
          final store = sigStore;
          if (store == null) return;
          final stat = await io.statFile(absPath);
          if (stat != null) store.set(fileId, stat.mtimeMs, stat.sizeBytes);
        }

        // (a) Empty file.
        if (bytes.isEmpty && current.sizeBytes == 0) {
          shaSkipped += 1;
          await rememberSig();
          continue;
        }

        final wholeHash = _hasher(bytes);

        // (b) Single-chunk.
        if (current.chunks.length == 1 && current.chunks.first == wholeHash) {
          shaSkipped += 1;
          await rememberSig();
          continue;
        }

        // (c) Multi-chunk: re-chunk if size matches.
        if (current.chunks.length > 1 && current.sizeBytes == bytes.length) {
          final result = await ContentDefinedChunker(blobIdHasher: _hasher)(
            bytes,
          );
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
              await rememberSig();
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
        if (sampleScanLine())
          log.info(
            'StartupDiff: pending isText=$isText reason=$reason '
            'diskBytes=${bytes.length} diskHash=${wholeHash.substring(0, 8)} '
            'chunks.len=${current.chunks.length} chunks[0]=$chunkPrev '
            'state.blobRef=${current.blobRef.length < 8 ? current.blobRef : current.blobRef.substring(0, 8)} '
            'state.sizeBytes=${current.sizeBytes}',
            data: {'path': LogPath(relPath)},
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
          if (sampleScanLine())
            log.info(
              'StartupDiff: pending-new isText=$isText '
              'fileId=$fileId diskBytes=${bytes.length}',
              data: {'path': LogPath(relPath)},
            );
        } else {
          // Tombstoned but on disk.
          pendingTombstoneRevive++;
          log.info(
            'StartupDiff: pending-revive isText=$isText '
            'fileId=$fileId diskBytes=${bytes.length} '
            'state.hlc=${current.hlc} '
            'state.blobRef=${current.blobRef.length < 8 ? current.blobRef : current.blobRef.substring(0, 8)} '
            'state.sizeBytes=${current.sizeBytes}',
            data: {
              'path': LogPath(relPath),
              'state.path': LogPath(current.path),
            },
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
    if (scanSamples > _maxScanSamples) {
      log.info(
        'StartupDiff: ${scanSamples - _maxScanSamples} more per-file line(s) '
        'withheld — the counts below are the whole picture',
      );
    }
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
    //
    // Counted in FILES, not jobs. A job used to be one file; grouping the
    // uploads made it up to eight, and the counter followed — the log read
    // "processing 2 file(s)" for sixteen, and the progress bar advanced in
    // steps of eight. The unit the user sees must not depend on how the work
    // happens to be packed.
    final totalFiles = pending.length + pendingTextPaths.length;
    var doneFiles = 0;
    var publishedSomething = false;
    final publishBeat = Stopwatch()..start();
    void creditFile() {
      doneFiles++;
      publishedSomething = true;
      onUploadProgress?.call(doneFiles, totalFiles);
    }

    /// Publishes what has landed, if enough has landed since the last time.
    ///
    /// Called from BOTH job kinds. It lived in the binary one first, which
    /// meant a vault of notes — where every file takes the text path —
    /// published nothing until the pass ended, and the whole point was lost
    /// for exactly the vaults most likely to be large.
    Future<void> maybePublish() async {
      final publish = onProgressPublished;
      // Nothing new is worth a round trip however long it has been.
      if (publish == null || !publishedSomething) return;
      if (publishBeat.elapsed < publishInterval) return;
      publishedSomething = false;
      publishBeat.reset();
      await publish();
    }

    final jobs = <Future<void> Function()>[];
    if (chunkedIO != null) {
      // A GROUP per job, not a file: upload paid a request for a file's chunks
      // and another for its manifest, so a re-upload of 251 files cost 502
      // round trips. uploadAll sends a group's chunks together and then its
      // manifests together — same manifest-last guarantee, made stricter
      // across the group, at two requests per group instead of per file.
      for (var i = 0; i < pending.length; i += _uploadGroupSize) {
        final group = pending.sublist(
          i,
          i + _uploadGroupSize > pending.length
              ? pending.length
              : i + _uploadGroupSize,
        );
        jobs.add(() async {
          final results = await chunkedIO.uploadAll(
            [for (final item in group) item.bytes],
            knownChunks,
            onFileProgress: (index, sent, total) {
              final item = group[index];
              // Same threshold the reconcile path uses, so a file that names
              // itself when edited also names itself on a re-upload.
              if (item.bytes.length < DiskReconciler.transferMonitorMinBytes) {
                return;
              }
              onFileTransfer?.call(item.relPath, sent, total, false);
            },
          );
          for (var j = 0; j < group.length; j++) {
            final item = group[j];
            final result = results[j];
            if (item.bytes.length >= DiskReconciler.transferMonitorMinBytes) {
              // Retire it from the active list; without this it sits there at
              // whatever fraction the last chunk left it on.
              onFileTransfer?.call(
                item.relPath,
                item.bytes.length,
                item.bytes.length,
                true,
              );
            }
            // knownChunks is a plain Set — additions from concurrent
            // workers race-free under Dart's single-threaded event loop.
            // Mid-upload concurrent groups may submit the same chunk hash;
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
            // Durable NOW, not after the whole scan.
            //
            // This used to live only in memory, and the push that followed the
            // diff was what wrote it down — so any failure before that point
            // discarded every byte of progress. A vault of 9119 files tripped
            // the server's blob rate limit part-way through, died, was
            // restarted by the health check five minutes later, and re-scanned
            // all 9119 from `0 tracked`. Forever: it never once finished, so it
            // never once persisted, so it never once started from anywhere but
            // the beginning.
            //
            // A row is safe to write before it is pushed. The blob is already
            // uploaded when we get here, so the state is true; the push simply
            // has not happened, which is exactly what `_collectDirty` looks for
            // on the next run. And it is what makes the next scan's fast path
            // skip this file — that path compares disk against the stored
            // chunk list, so without the row there is nothing to compare to.
            await store.persistOne(item.fileId);
            // So the next scan skips it on its stat instead of reading it
            // again. A file uploaded here and never signed would be read in
            // full on every start for the rest of its life.
            final sigs = sigStore;
            if (sigs != null) {
              final stat = await io.statFile('$vaultPath/${item.relPath}');
              if (stat != null) {
                sigs.set(
                  item.fileId,
                  stat.mtimeMs,
                  stat.sizeBytes,
                  blobRef: result.manifestHash,
                );
              }
            }
            creditFile();
          }
          // The causal context, once per group.
          //
          // NOT the clock: `load` rebuilds `_ownLatestHlc` by scanning the
          // rows it just read, so the hlc recovers on its own. `_ownContext`
          // does not — it is read from the meta row and from nowhere else,
          // while `upsert` advances it per file. Persisting the rows and not
          // this would leave a restart claiming to have seen less than it has
          // already written, so the next write would carry a context missing
          // its own predecessors and the server's join could read it as
          // concurrent with them rather than dominating.
          //
          // Affordable only because the per-file maps left this row earlier
          // today; while it still carried an entry per file this would have
          // been a 1.8 MB rewrite per group.
          await store.persistMeta();
          await maybePublish();
        });
      }
    }
    final planText = planTextReconcile;
    final commitText = commitTextReconcile;
    if (chunkedIO != null && planText != null && commitText != null) {
      // A GROUP per job, exactly as for binaries above. Text used to be one
      // job per file, and each of those did its own two-request upload: 188
      // notes cost 376 round trips where 188 binaries cost 48. On the managed
      // backend the request is cheap and nobody saw it; on a BYO WebDAV a
      // vault of 188 notes took seven minutes, and the per-file timings said
      // `upload=4823ms` for a 2 KB blob — queue time, not transfer.
      for (var i = 0; i < pendingTextPaths.length; i += _uploadGroupSize) {
        final group = pendingTextPaths.sublist(
          i,
          i + _uploadGroupSize > pendingTextPaths.length
              ? pendingTextPaths.length
              : i + _uploadGroupSize,
        );
        jobs.add(() async {
          // Plan first: reading, seeding and diffing are local, and most files
          // settle here without needing the network at all.
          final plans = <TextReconcilePlan>[];
          for (final relPath in group) {
            final outcome = await planText(relPath);
            final plan = outcome.plan;
            if (plan == null) {
              if (outcome.changed) modifiedFiles++;
              creditFile();
              continue;
            }
            plans.add(plan);
          }
          if (plans.isEmpty) {
            await maybePublish();
            return;
          }
          final results = await chunkedIO.uploadAll(
            [for (final plan in plans) plan.blobBytes],
            knownChunks,
            // These bytes ARE the tree, which the commit writes before the
            // FileState naming them — so caching a second copy in the same
            // database buys nothing. Same reason the per-file path passes it.
            cacheLocally: false,
          );
          for (var j = 0; j < plans.length; j++) {
            final changed = await commitText(
              plans[j],
              results[j].manifestHash,
              results[j].chunkHashes,
            );
            if (changed) modifiedFiles++;
            creditFile();
          }
          await maybePublish();
        });
      }
    } else if (reconcileText != null) {
      // No chunked IO (offline runs, tests): one file at a time, as before.
      final reconcile = reconcileText!;
      for (final relPath in pendingTextPaths) {
        jobs.add(() async {
          // The reconciler writes its own FileState (Fugue blob) and only
          // bumps when the content actually changed — an unedited text file
          // produces no push, which is the whole point of this path.
          final changed = await reconcile(relPath);
          if (changed) modifiedFiles++;
          creditFile();
          await maybePublish();
        });
      }
    }

    if (totalFiles > 0) {
      log.info(
        'StartupDiff: processing $totalFiles file(s) '
        '(${pending.length} binary upload in ${jobs.length} group(s), '
        '${pendingTextPaths.length} text reconcile) '
        'with concurrency=$uploadConcurrency…',
      );
      onUploadProgress?.call(0, totalFiles);
      final swatch = Stopwatch()..start();
      var nextIndex = 0;
      var consecutiveFailures = 0;
      // Set once by whichever worker trips the threshold; every worker checks
      // it, so the pass ends rather than each worker ending separately.
      var abort = false;
      Object? lastGroupError;

      // Bounded-concurrency worker pool. CPU work (CDC chunker, encrypt,
      // Fugue diff) is single-threaded on dart2js, but each job spends most
      // of its wall time on network ack — a few in flight hides that latency.
      // BlobTransferHub caps inner RPCs and dedups shared chunk hashes.
      Future<void> worker() async {
        while (true) {
          if (abort) return;
          final i = nextIndex++;
          if (i >= jobs.length) return;
          try {
            // Progress is credited per file from inside the job, so a group
            // advances the bar eight times rather than once at the end.
            await jobs[i]();
            consecutiveFailures = 0;
          } catch (e) {
            // A preemption is not a group failure — it aborts the whole run
            // by design, and swallowing it would keep working after the host
            // asked us to stop.
            if (e is RpcCancelledException) rethrow;
            // Neither is a disposed hub. It does not say this group failed, it
            // says the SESSION that owned the transfers is gone: a newer start
            // replaced this one, or the engine stopped. Every later group will
            // fail identically, and continuing means doing work for a session
            // that no longer exists — a real pass burned 26 groups discovering
            // that one at a time.
            if (e is BlobTransferHubDisposed) rethrow;
            // Nor is a refused storage. 401 is not this group's bad luck, it
            // is the backend declining to hold anything at all: retrying it
            // 9000 times over produces 9000 identical refusals and one very
            // busy laptop. Stop, and carry the reason out so the host can say
            // which credentials to fix — the run keeps whatever it banked.
            if (e is BlobStorageRefused) {
              refused ??= '$e';
              abort = true;
              log.error('StartupDiff: $e — stopping this pass');
              return;
            }
            skippedGroups++;
            consecutiveFailures++;
            lastGroupError = e;
            log.warning('StartupDiff: group $i failed, continuing: $e');
            // One group failing is a transient — a rate-limited batch, a
            // dropped chunk upload — and the run should carry on and bank
            // everything else. A RUN of them is systemic: a refused token or
            // a server that is down fails every group identically, and
            // grinding through thousands of them would freeze the host to
            // reach the same answer. Abort and keep what is banked; the
            // host's self-heal retries later, and by then the diff has less
            // to do than it did.
            if (consecutiveFailures >= _maxConsecutiveGroupFailures) {
              // Shared, because `throw` ends only THIS worker. Without it the
              // other three carried on pulling jobs and each tripped the
              // threshold in turn — the log said "stopping this pass" while
              // the pass visibly continued, four times over.
              abort = true;
            }
            if (abort) {
              log.error(
                'StartupDiff: $consecutiveFailures groups failed in a row — '
                'stopping this pass',
              );
              rethrow;
            }
          }
        }
      }

      final workerCount = uploadConcurrency.clamp(1, jobs.length);
      await Future.wait(List.generate(workerCount, (_) => worker()));
      log.info(
        'StartupDiff: processing of $totalFiles file(s) done in '
        '${swatch.elapsed.inSeconds}s'
        '${skippedGroups > 0 ? ', $skippedGroups group(s) skipped '
                  '(last: $lastGroupError)' : ''}',
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
      outOfScope: outOfScope,
      diskFileCount: diskRelPaths.length,
      skippedGroups: skippedGroups,
      storageRefused: refused,
    );
  }

  String _deterministicFileId(String relativePath) =>
      deterministicFileId(_recordIdKey, vaultId, relativePath);

  static bool _isHidden(String relPath) =>
      relPath.split('/').any((s) => s.startsWith('.'));
}
