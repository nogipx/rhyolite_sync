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

/// A previously size-blocked file is no longer blocked: it was deleted, shrank
/// below the limit, or the tier's limit rose. Paired with [SyncFileSizeBlocked]
/// so UI can drop it from the "too large" list instead of leaving it stuck.
class SyncFileSizeUnblocked extends SyncEngineEvent {
  SyncFileSizeUnblocked({required this.path});

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

/// Emitted on the boolean transition between "fully synced" and
/// "has local edits the engine has not yet pushed". Indicator paints
/// idle differently while pending so the user can tell their work
/// hasn't reached the server yet.
class SyncPending extends SyncEngineEvent {
  SyncPending({required this.hasPending});

  final bool hasPending;
}

class SyncFilePulled extends SyncEngineEvent {
  SyncFilePulled({required this.fileId, required this.nodeCount, this.path = ''});

  final String fileId;
  final int nodeCount;
  final String path;
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
typedef ServerRejectionFactory = SyncServerRejected? Function(
  String code,
  String message,
  Map<String, dynamic> params,
);


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
  SyncStartupBlobUploadDone({required this.totalUploaded, required this.elapsed});

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
