import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Whether this event means "local state has just been banked — drain the
/// write queue now".
///
/// The plugin's SQLite sits on an IndexedDB VFS, which acknowledges a write
/// and performs it afterwards from a queue. Between the two the database has
/// told us "committed" about bytes that exist only in RAM, and a host that
/// dies in that window rolls back to the last drain. So the engine's events
/// are what schedule the drain, and choosing them wrongly is invisible until
/// someone closes the app at the wrong moment.
///
/// **The rule: bank-time, not finish-time, and not acknowledgement.** It has
/// been got wrong twice, in the same shape both times, so it is written down
/// here rather than inline in a listener:
///
///   * Hooked to [SyncCursorAdvanced], which a pull emits ONCE at the end, a
///     whole vault's pull wrote for minutes with nothing draining it. Closing
///     the host mid-pull discarded every applied register row, and the next
///     run re-fetched every record and re-downloaded every blob to find the
///     content already on disk.
///   * The startup upload's only barrier was the periodic push
///     ([SyncFilePushed]) — which is the SERVER acknowledging, not us banking.
///     That push is best-effort and swallows its failures, so a server that
///     was refusing (rate limit, quota, offline) left rows banking with
///     nothing draining them. Which is the exact case the banking was written
///     for: a 9119-file vault that tripped the rate limit and restarted from
///     zero every time.
///
/// Frequency is not a reason to leave one out — the caller debounces. Being
/// too rare is the failure that costs a user their sync; being too often costs
/// a coalesced timer.
bool isDurabilityBarrier(SyncEngineEvent event) => switch (event) {
  // A pull batch is applied and its register rows are written.
  SyncPullBatchApplied() => true,
  // A startup-diff file's blob has landed and its row is persisted; this is
  // emitted from the same step that writes it.
  SyncStartupBlobUploadProgress() => true,
  // The server accepted a push, so lastSyncedBlobRef moved.
  SyncFilePushed() => true,
  // End-of-pass and end-of-pull convergence points. Neither is sufficient
  // alone — see above — but both are real.
  SyncStartupBlobUploadDone() => true,
  SyncCursorAdvanced() => true,
  // Everything else. Notably NOT the transfer/progress events that count
  // bytes in flight ([SyncBlobTransfer], [SyncBlobDownloadProgress]): they
  // say the network moved, which is not a claim about anything being written.
  _ => false,
};
