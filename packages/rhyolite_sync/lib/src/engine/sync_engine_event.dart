sealed class SyncEngineEvent {
  SyncEngineEvent() : timestamp = DateTime.now();

  final DateTime timestamp;
}

class SyncStarted extends SyncEngineEvent {
  SyncStarted();
}

class SyncStopped extends SyncEngineEvent {
  SyncStopped();
}

class SyncLogMessage extends SyncEngineEvent {
  SyncLogMessage(this.message);

  final String message;
}

class SyncFileCreated extends SyncEngineEvent {
  SyncFileCreated(this.path);

  final String path;
}

class SyncFileModified extends SyncEngineEvent {
  SyncFileModified(this.path);

  final String path;
}

class SyncFileMoved extends SyncEngineEvent {
  SyncFileMoved({required this.fromPath, required this.toPath});

  final String fromPath;
  final String toPath;
}

class SyncFileDeleted extends SyncEngineEvent {
  SyncFileDeleted(this.path);

  final String path;
}

class SyncFilePushed extends SyncEngineEvent {
  SyncFilePushed(this.path);

  final String path;
}

/// A file was skipped because it exceeds the plan's per-file size limit. It is
/// not read/chunked/uploaded and stays local-only until it shrinks below the
/// limit (or the tier's limit rises).
class SyncFileSizeBlocked extends SyncEngineEvent {
  SyncFileSizeBlocked({
    required this.path,
    required this.sizeBytes,
    required this.limitBytes,
  });

  final String path;
  final int sizeBytes;
  final int limitBytes;
}

/// How far a pull has got, counted in FILES rather than in blobs.
///
/// The only progress a pull reported was [SyncBlobDownloadProgress], which
/// counts blobs still to fetch. That was the right measure when fetching was
/// the work; it is no longer. A pull now spends most of its time applying,
/// reconciling and pushing, and it emits nothing at all for a batch whose
/// files are already held locally — so on a vault where half the files were
/// already present the bar sat still through half the run and looked stuck.
///
/// Emitted per applied file, which is also the unit the user is counting.
class SyncPullProgress extends SyncEngineEvent {
  SyncPullProgress({required this.applied, required this.total});

  final int applied;
  final int total;
}

/// One batch of a pull has been applied and banked.
///
/// A DURABILITY checkpoint, not progress for display. A host whose storage
/// acknowledges writes before performing them (the plugin's SQLite sits on an
/// IndexedDB VFS) should drain its queue here.
///
/// It exists because the only such checkpoint used to be [SyncCursorAdvanced],
/// which a pull emits once, at the very end. A pull of a whole vault therefore
/// wrote for minutes into a queue nothing drained, and closing the host
/// mid-pull discarded every register row it had applied — so the next run
/// re-fetched every record and re-downloaded every blob, only to find the
/// content already on disk and write nothing.
///
/// Emitted per batch whether or not the CURSOR moved, which is the point: the
/// cursor is held back by the lowest unapplied serverSeq while files are
/// applied smallest-first, so it can sit still for most of a large pull with
/// real work banked behind it. The register rows are what make a resumed pull
/// cheap, not the cursor.
class SyncPullBatchApplied extends SyncEngineEvent {
  SyncPullBatchApplied({required this.cursor});

  /// Where the cursor stands now. May be unchanged since the last checkpoint.
  final int cursor;
}

/// A file on the SERVER is too large for this device to fetch, so it was not
/// materialised.
///
/// The mirror image of [SyncFileSizeBlocked] and deliberately not the same
/// event: that one is about a local file we decline to send, which stays safe
/// on disk. This one is about a file that exists and is not here, which is the
/// opposite reassurance and the opposite next step.
///
/// It exists because both cases reached the user as `Blob not available` — the
/// message for a blob the server LOST. Someone told their vault was missing
/// data goes looking for a recovery, when nothing was lost and the file is
/// intact on every device that could hold it.
class SyncFileTooLargeToFetch extends SyncEngineEvent {
  SyncFileTooLargeToFetch({
    required this.path,
    required this.sizeBytes,
    required this.limitBytes,
  });

  final String path;
  final int sizeBytes;
  final int limitBytes;
}

/// A previously size-blocked file is no longer blocked: it was deleted, shrank
/// below the limit, or the tier's limit rose. Paired with [SyncFileSizeBlocked]
/// so UI can drop it from the "too large" list instead of leaving it stuck.
class SyncFileSizeUnblocked extends SyncEngineEvent {
  SyncFileSizeUnblocked({required this.path});

  final String path;
}

/// A file was skipped by the per-device file-type exclusion filter — its
/// extension is on the user's denylist, so it is neither uploaded (local) nor
/// materialised (remote). Surfaced so the UI can show "N files excluded". The
/// filter is device-local (data.json, not synced): each device chooses what it
/// can afford to sync. Emitted for every excluded path during the startup scan
/// and whenever a reconcile / apply touches one.
class SyncFileTypeExcluded extends SyncEngineEvent {
  SyncFileTypeExcluded({required this.path, required this.extension});

  final String path;

  /// The lowercase extension (no dot) that matched the denylist, e.g. `pdf`.
  final String extension;
}

/// Files this device once held and no longer does, found at startup.
///
/// Deleted while nothing was watching — Obsidian closed, sync paused, the
/// plugin off. NOT acted on: an unmounted vault produces exactly the same
/// list, and no local signal tells the two apart, so propagating these
/// deletes is the user's call. Keyed by fileId so the host can hand the
/// approved subset back to `confirmVanishedDeletes`.
class SyncFilesVanished extends SyncEngineEvent {
  SyncFilesVanished(this.pathsByFileId);

  final Map<String, String> pathsByFileId;
}

/// A file lies outside this device's [PathScope] — the user restricted sync to
/// a set of folders and this path is not in them. Neither uploaded (local) nor
/// materialised (remote), and a local delete of it is not propagated.
///
/// Device-local like [SyncFileTypeExcluded], and equally non-destructive: the
/// file stays on disk, stays on the server, and peers keep syncing it. Emitted
/// for every out-of-scope path during the startup scan and whenever a
/// reconcile / apply touches one, so the UI can rebuild its list from truth.
class SyncFileOutOfScope extends SyncEngineEvent {
  SyncFileOutOfScope({required this.path});

  final String path;
}

/// A file is stored in a blob format this build has no decoder for — written
/// by a NEWER client. It is neither materialised to disk nor re-pushed, so the
/// newer state stays intact until this client is updated.
///
/// Its own event rather than a [SyncError] because the two are not the same
/// kind of thing. An error is transient and the UI clears it after a few
/// seconds; this is a standing per-file condition that recurs on every
/// reconcile and only ends when the user updates. Same shape as
/// [SyncFileSizeBlocked] for that reason: a named file, a reason, and a list
/// the UI can show.
class SyncFileFormatUnsupported extends SyncEngineEvent {
  SyncFileFormatUnsupported({required this.path});

  final String path;
}

/// Live per-file blob transfer progress, for an "active transfers" monitor.
/// Emitted as a file's content blob is uploaded or downloaded through
/// [ChunkedBlobIO]. [sentBytes]/[totalBytes] are coarse (dedup-skipped chunks
/// count instantly), so the bar can jump; [done] marks the transfer finished
/// (success or failure) so the UI drops it from the active list.
class SyncBlobTransfer extends SyncEngineEvent {
  SyncBlobTransfer({
    required this.path,
    required this.upload,
    required this.sentBytes,
    required this.totalBytes,
    required this.done,
  });

  final String path;
  final bool upload;
  final int sentBytes;
  final int totalBytes;
  final bool done;
}

/// Emitted immediately before the engine fires a putStates RPC.
/// Indicator surfaces this so a hung push is visually distinguishable
/// from idle.
class SyncPushing extends SyncEngineEvent {
  SyncPushing({required this.fileCount});

  final int fileCount;
}

/// Emitted immediately before the engine fires a getStates RPC.
class SyncPulling extends SyncEngineEvent {
  SyncPulling();
}

/// Whether the engine is inside an operation the user must not interrupt.
///
/// A UI cannot infer this from the other events. Hosts previously kept a short
/// idle debounce and called anything within it "syncing" — which made the
/// indicator depend on how densely a phase happens to report progress, not on
/// whether it is running. Batching the pull's prefetch spread its progress
/// events from every ~150 ms to roughly every 5 s, and the indicator started
/// falling back to "up to date" in the middle of a 47-second download. A user
/// who believes that and closes the app loses the rest of it.
///
/// So the engine states it. Emitted only on the transition, and guaranteed
/// from a `finally` on every exit — success, failure, and cancellation alike.
/// The failure mode is deliberately "stuck busy" rather than "stuck idle":
/// telling someone work is still going when it is not costs them a wait,
/// while the reverse costs them their edits.
class SyncBusy extends SyncEngineEvent {
  SyncBusy({required this.busy});

  final bool busy;
}

/// Emitted on the boolean transition between "fully synced" and
/// "has local edits the engine has not yet pushed". Indicator paints
/// idle differently while pending so the user can tell their work
/// hasn't reached the server yet.
class SyncPending extends SyncEngineEvent {
  SyncPending({required this.hasPending});

  final bool hasPending;
}

class SyncFilePulled extends SyncEngineEvent {
  SyncFilePulled({
    required this.fileId,
    required this.nodeCount,
    this.path = '',
  });

  final String fileId;
  final int nodeCount;
  final String path;
}

/// The blob backend refused this device — wrong credentials, or no permission.
///
/// Distinct from [SyncError], which is a thing that went wrong; this is a
/// thing that will keep going wrong. Nothing retries its way out of a 401, so
/// a host should treat it as a missing precondition — name it, offer the way
/// to fix it — rather than as a failure to report and move past.
class SyncStorageRefused extends SyncEngineEvent {
  SyncStorageRefused(this.detail);

  final String detail;
}

/// The local database is at its limit and reclaiming did not help.
///
/// Emitted once per pull, not per file: at this point the space is live data
/// rather than staging, so nothing the engine does on its own will change it —
/// the host decides whether to offer compaction, and the user decides whether
/// to take it. Syncing continues, because a stale vault is worse than a full
/// database.
class SyncDatabaseFull extends SyncEngineEvent {
  SyncDatabaseFull({required this.bytes, required this.limitBytes});

  final int bytes;
  final int limitBytes;
}

class SyncError extends SyncEngineEvent {
  SyncError(this.message);

  final String message;
}

class SyncConnecting extends SyncEngineEvent {
  SyncConnecting({required this.attempt});

  final int attempt;
}

class SyncConnected extends SyncEngineEvent {
  SyncConnected();
}

class SyncDisconnected extends SyncEngineEvent {
  SyncDisconnected();
}

/// Emitted when the server signals a vault reset.
/// The engine wipes local state and re-uploads from disk.
class SyncVaultReset extends SyncEngineEvent {
  SyncVaultReset();
}

/// The local sync database came up empty even though the HOST still
/// remembers a deviceId for this vault — i.e. this install has synced
/// before and its database is gone, not fresh.
///
/// The engine recovers on its own (cursor 0 → full pull → every blob
/// re-downloaded), so this is not an error. It is emitted because the
/// recovery is expensive and, from the user's seat, indistinguishable from a
/// bug: "why is it downloading my whole vault again?". It also has one real
/// consequence worth surfacing — a delete made on THIS device whose tombstone
/// never reached the server is undone by the restore, so the file reappears.
///
/// On a host that keeps its database in browser storage (the Obsidian plugin
/// — OPFS, with an IndexedDB fallback and a silent in-memory last resort) the
/// usual cause is the OS evicting that storage while the app sat unused, or
/// the storage failing to open at all. Hosts should surface this and, where
/// the platform allows it, ask for persistent storage (`navigator.storage
/// .persist()`).
class SyncLocalStateLost extends SyncEngineEvent {
  SyncLocalStateLost({required this.deviceId});

  /// The host-persisted device identity that outlived the database.
  final String deviceId;

  @override
  String toString() => 'SyncLocalStateLost(deviceId: $deviceId)';
}

/// Generic envelope for server-side rejections that originate from
/// application policy (auth, quota, subscription, feature gates) or
/// from product-specific protocol extensions.
///
/// This is the OCP escape hatch: new business rules added on the
/// server reach the consumer via this single event type, identified by
/// a stable hierarchical [code]. Adding a new policy never requires
/// editing `rhyolite_sync` — the server emits a new code, the consumer
/// pattern-matches on it.
///
/// Standard codes (embedders may define more):
///
/// - `auth.session_expired` — refresh token invalid; user must re-sign-in.
///   The engine stops after emitting this code.
/// - `auth.token_missing` — no token was attached to the call (the host's
///   token provider is unbound, or the server saw no Authorization
///   header). The session on disk may be perfectly good, so a host must
///   NOT discard it on this code — rebind the provider and restart.
/// - `auth.permission_denied` — caller does not own the vault.
/// - `app_policy.subscription_required` — no active subscription. The
///   engine stops after emitting this code.
/// - `app_policy.quota.<dimension>` — quota exceeded
///   (e.g. `app_policy.quota.storage`, `app_policy.quota.file_size`,
///   `app_policy.quota.vault_count`, `app_policy.quota.daily_bandwidth`).
/// - `app_policy.rate.<dimension>` — rate-limited
///   (e.g. `app_policy.rate.push`, `app_policy.rate.pull`).
/// - `feature.<name>` — generic feature-level signal from the server
///   (e.g. `feature.external_blob_config_discovered` carries the
///   discovered config in [params] under key `config`).
///
/// [params] carries structured data the consumer can render
/// (e.g. `{current: 5368709120, limit: 5368709120}` for storage
/// quota, or `{config: {...}}` for external blob config).
///
/// ## Typed subclasses (recommended)
///
/// This class is intentionally **not** `final`, so consumers can define
/// typed subclasses for the codes they care about and have switch
/// statements pattern-match on the type instead of the string code:
///
/// ```dart
/// // Defined in your app code, not in rhyolite_sync:
/// class SessionExpired extends SyncServerRejected {
///   SessionExpired(String message)
///     : super(code: 'auth.session_expired', message: message);
/// }
///
/// class StorageQuotaExceeded extends SyncServerRejected {
///   StorageQuotaExceeded({
///     required this.currentBytes,
///     required this.limitBytes,
///     required String message,
///   }) : super(
///     code: 'app_policy.quota.storage',
///     message: message,
///     params: {'current': '$currentBytes', 'limit': '$limitBytes'},
///   );
///   final int currentBytes;
///   final int limitBytes;
/// }
/// ```
///
/// Then wire a [ServerRejectionFactory] into the engine constructor so
/// the engine emits typed instances instead of the raw envelope:
///
/// ```dart
/// final engine = StateSyncEngine(
///   ...,
///   rejectionFactory: (code, message, params) => switch (code) {
///     'auth.session_expired' => SessionExpired(message),
///     'app_policy.quota.storage' => StorageQuotaExceeded(
///       currentBytes: int.parse(params['current'] ?? '0'),
///       limitBytes: int.parse(params['limit'] ?? '0'),
///       message: message,
///     ),
///     _ => null, // unknown code → engine emits raw SyncServerRejected
///   },
/// );
///
/// engine.events.listen((event) {
///   switch (event) {
///     case StorageQuotaExceeded(:final currentBytes, :final limitBytes):
///       showStorageDialog(currentBytes, limitBytes);   // typed!
///     case SessionExpired():
///       refreshTokenAndRestart();
///     case SyncServerRejected(:final code):
///       log.info('unknown rejection: $code');           // fallback
///     // … other event types
///   }
/// });
/// ```
class SyncServerRejected extends SyncEngineEvent {
  SyncServerRejected({
    required this.code,
    required this.message,
    this.params = const {},
  });

  final String code;
  final String message;
  final Map<String, dynamic> params;
}

/// Optional factory that maps a raw server rejection (code + message +
/// params) into a typed subclass of [SyncServerRejected]. Return `null`
/// to let the engine emit the raw envelope.
///
/// Wired into [StateSyncEngine] via the `rejectionFactory` constructor
/// parameter. See [SyncServerRejected] for the full pattern.
typedef ServerRejectionFactory =
    SyncServerRejected? Function(
      String code,
      String message,
      Map<String, dynamic> params,
    );

/// Emitted while the startup diff is walking the vault, before any upload.
///
/// The scan is the longest silent stretch a sync has: it walks every file and
/// hashes the ones whose signature moved, which on a large vault is a minute
/// with nothing to show. That silence was read two ways, both wrong — the UI
/// had nothing to say, and the host's health check took it for a dead engine
/// and restarted one mid-scan, so the next attempt began the same minute over.
///
/// A heartbeat rather than a fine-grained bar: [scanned] climbs to [total] in
/// steps, on a time budget, because the scan already owns the thread.
class SyncStartupScanProgress extends SyncEngineEvent {
  SyncStartupScanProgress({required this.scanned, required this.total});

  final int scanned;
  final int total;
}

/// Emitted while the engine is uploading blobs as part of a startup diff
/// (typically right after a reset / re-upload). Carries (completed, total)
/// so the UI can render a progress bar or counter without polling.
class SyncStartupBlobUploadProgress extends SyncEngineEvent {
  SyncStartupBlobUploadProgress({required this.completed, required this.total});

  final int completed;
  final int total;
}

/// Emitted once startup blob upload finishes (whether it had work to do
/// or not). UI clears the progress indicator on this event.
class SyncStartupBlobUploadDone extends SyncEngineEvent {
  SyncStartupBlobUploadDone({
    required this.totalUploaded,
    required this.elapsed,
  });

  final int totalUploaded;
  final Duration elapsed;
}

/// Emitted while the engine is fetching blobs for a pull batch (typically
/// right after a restore from server). Carries (completed, total).
class SyncBlobDownloadProgress extends SyncEngineEvent {
  SyncBlobDownloadProgress({required this.completed, required this.total});

  final int completed;
  final int total;
}

/// Emitted once a pull-driven bulk blob download finishes.
class SyncBlobDownloadDone extends SyncEngineEvent {
  SyncBlobDownloadDone({required this.totalDownloaded, required this.elapsed});

  final int totalDownloaded;
  final Duration elapsed;
}

// ---------------------------------------------------------------------------
// Vault repair — surface progress of `engine.triggerRepair()` so the UI can
// show a counter and the user knows the operation is alive on multi-second
// reseeds.
// ---------------------------------------------------------------------------

/// Repair started — UI shows a progress modal or status line.
class SyncRepairStarted extends SyncEngineEvent {
  SyncRepairStarted({required this.totalFiles});

  final int totalFiles;
}

/// Per-file repair progress. Emitted after each text file has been
/// reseeded from disk and queued for push.
class SyncRepairProgress extends SyncEngineEvent {
  SyncRepairProgress({
    required this.completed,
    required this.total,
    required this.currentPath,
  });

  final int completed;
  final int total;
  final String currentPath;
}

/// Repair finished — UI dismisses the progress indicator and reports.
class SyncRepairDone extends SyncEngineEvent {
  SyncRepairDone({
    required this.repaired,
    required this.failed,
    required this.elapsed,
  });

  final int repaired;
  final int failed;
  final Duration elapsed;
}

// ---------------------------------------------------------------------------
// CRDT-layer events — surface MvRegister state transitions so UI can react
// without poking into engine internals.
// ---------------------------------------------------------------------------

/// Emitted when `applyRemote` produced a multi-value register for [fileId]
/// — i.e. two or more devices wrote concurrently. [valueCount] is the
/// number of surviving TaggedValues. The conflict resolver will collapse
/// it (eventually emitting [SyncConflictResolved]).
class SyncConflictAppeared extends SyncEngineEvent {
  SyncConflictAppeared({required this.fileId, required this.valueCount});

  final String fileId;
  final int valueCount;
}

/// Emitted after the resolver has chosen a winner for a previously
/// conflicting [fileId]. [strategy] is a short label of which branch
/// of `StateConflictResolver` fired: `'same-blob'`, `'tombstone-loses'`,
/// `'3-way-merge'` or `'lww'`.
class SyncConflictResolved extends SyncEngineEvent {
  SyncConflictResolved({
    required this.fileId,
    required this.strategy,
    this.winnerBlobRef = '',
  });

  final String fileId;
  final String strategy;
  final String winnerBlobRef;
}

/// Emitted when the resolver had to seal a conflict via LWW and the
/// loser's content was not recoverable (blob missing from local
/// cache, no usable remote). The winner is materialised normally;
/// the loser's bytes are gone.
///
/// UI should surface this as a hard warning — Bob's edits literally
/// disappeared. This is the audit-trail signal for what used to be a
/// silent failure inside the engine's conflict-copy file-write step.
class SyncDataLoss extends SyncEngineEvent {
  SyncDataLoss({
    required this.fileId,
    required this.path,
    required this.lostBlobRef,
    required this.lostNodeId,
    required this.reason,
  });

  final String fileId;
  final String path;
  final String lostBlobRef;
  final String lostNodeId;
  final String reason;
}

/// Emitted when a pull declined to overwrite a file that already held content
/// this device had never synced — a vault copied onto a new machine, or edits
/// made while the local database was missing.
///
/// Not an error and not a stall: the file is left alone precisely so the next
/// pass can capture it as a concurrent value and merge it, rather than
/// replacing it with the server's copy.
class SyncFileKeptUnsynced extends SyncEngineEvent {
  SyncFileKeptUnsynced({required this.fileId, required this.path});

  final String fileId;
  final String path;
}

/// Emitted when the engine refused to apply a pulled record because it
/// failed to decode (bad cipher key, schema mismatch, corrupted row).
/// The fileId continues syncing with the records that did decode.
class SyncRecordSkipped extends SyncEngineEvent {
  SyncRecordSkipped({
    required this.fileId,
    required this.hlcPacked,
    required this.reason,
  });

  final String fileId;
  final String hlcPacked;
  final String reason;
}

/// Emitted after a successful `applyRemote` for [fileId] so UI can react
/// to specific files updating without parsing log lines.
class SyncRegisterJoined extends SyncEngineEvent {
  SyncRegisterJoined({
    required this.fileId,
    required this.incomingCount,
    required this.finalCardinality,
  });

  final String fileId;
  final int incomingCount;
  final int finalCardinality;
}

/// Emitted whenever the engine's pull cursor moves forward. Lets UI
/// surface "last synced" timestamps without polling.
class SyncCursorAdvanced extends SyncEngineEvent {
  SyncCursorAdvanced({required this.cursor, required this.recordCount});

  final int cursor;
  final int recordCount;
}
