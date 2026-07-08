import 'package:rhyolite_sync/rhyolite_sync.dart';

/// User-triggered cleanup of historical blobs.
///
/// Two-phase: [scan] computes a [JanitorPlan] the UI can show as a
/// preview, then [execute] performs the actual deletes.
///
/// Algorithm:
/// 1. Fetch all history events for the vault.
/// 2. Split into to-delete (createdAtMs < now − olderThanDays) and
///    to-keep.
/// 3. Build live ref set = current file_state.blobRef ∪
///    lastSyncedBlobRef ∪ surviving events' blobRef.
/// 4. Orphan blobs = to-delete events' blobRef − live refs.
/// 5. Plan ships (eventIds, blobIds, stats).
///
/// During execute, blobs are deleted FIRST (via IBlobStorage —
/// transparently routes to our managed server or the user's
/// WebDAV/S3), then the corresponding history events. Failures in
/// either step are tolerated: a future cleanup will retry whatever
/// was missed.
class BlobJanitor {
  BlobJanitor({
    required this.historyCaller,
    required this.blobStorage,
    required this.store,
    required this.vaultId,
    this.maintenanceCaller,
  });

  final IHistoryContract historyCaller;
  final IBlobStorage blobStorage;
  final FileStateStore store;
  final String vaultId;

  /// Server-side maintenance RPC for the orphan sweep. Null when the engine
  /// isn't connected; [sweepOrphans] then returns null.
  final IVaultMaintenanceContract? maintenanceCaller;

  /// Reclaims blobs referenced by nothing on the server — the residue the
  /// age/window cleanup can't see (failed uploads, blobs stranded when a prior
  /// cleanup deleted an event but not its blob). The server computes the live
  /// set authoritatively (its own state + history), so this is safe against a
  /// stale local view. [dryRun] (default) only reports; pass false to delete.
  Future<SweepOrphanBlobsResponse?> sweepOrphans({bool dryRun = true}) async {
    final caller = maintenanceCaller;
    if (caller == null) return null;
    return caller.sweepOrphanBlobs(
      SweepOrphanBlobsRequest(vaultId: vaultId, dryRun: dryRun),
    );
  }

  /// Maximum events fetched per scan. For typical Obsidian vaults a
  /// single batch is sufficient. Larger vaults would need pagination —
  /// not yet implemented.
  static const int maxHistoryFetch = 100000;

  /// Compute what cleanup would do without performing it.
  ///
  /// [olderThanDays] is the user's chosen "delete events older than" window.
  /// [deviceTtlDays] decides which device heads still count as "alive": any
  /// device whose head has not been refreshed within this window is treated
  /// as abandoned and excluded from the safe-head computation. Default 30.
  Future<JanitorPlan> scan({
    required int olderThanDays,
    int deviceTtlDays = 30,
  }) async {
    if (olderThanDays < 0) {
      throw ArgumentError.value(
        olderThanDays,
        'olderThanDays',
        'must be >= 0 (0 = delete all history the device-safety head allows)',
      );
    }

    final headsResponse = await historyCaller.getHistoryHeads(
      GetHistoryHeadsRequest(vaultId: vaultId),
    );
    final response = await historyCaller.getHistory(
      HistoryGetRequest(vaultId: vaultId, limit: maxHistoryFetch),
    );
    final all = response.events;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    final thresholdMs = nowMs - olderThanDays * 86400000;
    final deviceTtlMs = deviceTtlDays * 86400000;

    // minSafeHead: the smallest serverSeq among devices that have checked
    // in within deviceTtl. Events with serverSeq > minSafeHead are still
    // unreplicated to some active device and must NOT be deleted.
    final activeHeads = headsResponse.heads
        .where((h) => nowMs - h.updatedAtMs <= deviceTtlMs)
        .toList();
    final int? minSafeHead = activeHeads.isEmpty
        ? null
        : activeHeads.map((h) => h.headSeq).reduce((a, b) => a < b ? a : b);

    final toDelete = <HistoryEvent>[];
    final toKeep = <HistoryEvent>[];
    var protectedByHead = 0;
    DateTime? oldestKept;
    DateTime? newestKept;
    DateTime? oldestDel;
    DateTime? newestDel;
    for (final event in all) {
      final tooYoung = event.createdAtMs >= thresholdMs;
      // If minSafeHead is null (no active devices) we treat ALL events
      // as eligible for the age check alone. Otherwise we additionally
      // require event.serverSeq <= minSafeHead before allowing delete.
      final aboveSafeHead =
          minSafeHead != null && event.serverSeq > minSafeHead;
      if (tooYoung || aboveSafeHead) {
        toKeep.add(event);
        if (aboveSafeHead && !tooYoung) protectedByHead++;
        final d = DateTime.fromMillisecondsSinceEpoch(event.createdAtMs);
        oldestKept = (oldestKept == null || d.isBefore(oldestKept))
            ? d
            : oldestKept;
        newestKept = (newestKept == null || d.isAfter(newestKept))
            ? d
            : newestKept;
        continue;
      }
      toDelete.add(event);
      final d = DateTime.fromMillisecondsSinceEpoch(event.createdAtMs);
      oldestDel = (oldestDel == null || d.isBefore(oldestDel)) ? d : oldestDel;
      newestDel = (newestDel == null || d.isAfter(newestDel)) ? d : newestDel;
    }

    // Live refs: every blob that any surviving artefact references.
    //  - Every TaggedValue in every MvRegister (doc §9): a multi-value
    //    register pins all of its concurrent versions' blobs until the
    //    resolver collapses it.
    //  - lastSyncedBlobRef: past manifest kept as 3-way merge base.
    //  - Surviving events: manifest + chunks for retention-window history.
    // Tombstones contribute nothing (blobRef empty, chunks empty).
    final live = <String>{};
    for (final state in store.allValuesFlat) {
      if (state.blobRef.isNotEmpty) live.add(state.blobRef);
      live.addAll(state.chunks);
    }
    for (final fileId in store.fileIds) {
      final synced = store.lastSyncedBlobRefFor(fileId);
      if (synced != null && synced.isNotEmpty) live.add(synced);
    }
    for (final event in toKeep) {
      if (event.blobRef.isNotEmpty) live.add(event.blobRef);
      live.addAll(event.chunks);
    }

    final orphanBlobs = <String>{};
    void considerOrphan(String ref) {
      if (ref.isEmpty) return;
      if (live.contains(ref)) return;
      orphanBlobs.add(ref);
    }

    for (final event in toDelete) {
      considerOrphan(event.blobRef);
      for (final chunk in event.chunks) {
        considerOrphan(chunk);
      }
    }

    return JanitorPlan(
      olderThanDays: olderThanDays,
      totalEvents: all.length,
      eventsToDelete: toDelete.length,
      eventsToKeep: toKeep.length,
      orphanBlobCount: orphanBlobs.length,
      eventIds: toDelete.map((e) => e.eventId).toList(),
      blobIds: orphanBlobs.toList(),
      oldestDeletedAt: oldestDel,
      newestDeletedAt: newestDel,
      oldestRemainingAt: oldestKept,
      newestRemainingAt: newestKept,
      knownDevices: headsResponse.heads,
      activeDeviceCount: activeHeads.length,
      minSafeHead: minSafeHead,
      eventsProtectedByHead: protectedByHead,
    );
  }

  /// Max blob ids per delete RPC. A big orphan set (a video's many chunks +
  /// every historical version) in one call risks a rejected/rate-limited
  /// request; batching keeps each request small and lets partial progress
  /// through.
  static const int _deleteBatchSize = 500;

  /// Execute the plan: delete orphan blobs, then — ONLY if that fully
  /// succeeded — the history events. Deleting an event whose blob delete
  /// failed would strand the blob with no reference at all (an invisible
  /// orphan the janitor can never find again), so on any blob-delete failure
  /// the events are kept for a retry and the failure is surfaced.
  Future<JanitorResult> execute(JanitorPlan plan) async {
    var deletedBlobs = 0;
    var failedBlobs = 0;
    Object? firstError;

    for (var i = 0; i < plan.blobIds.length; i += _deleteBatchSize) {
      final end = (i + _deleteBatchSize) < plan.blobIds.length
          ? i + _deleteBatchSize
          : plan.blobIds.length;
      final batch = plan.blobIds.sublist(i, end);
      try {
        await blobStorage.deleteMany(batch);
        deletedBlobs += batch.length;
      } catch (e) {
        failedBlobs += batch.length;
        firstError ??= e;
      }
    }

    var deletedEvents = 0;
    if (failedBlobs == 0 && plan.eventIds.isNotEmpty) {
      try {
        final response = await historyCaller.deleteEvents(
          HistoryDeleteEventsRequest(vaultId: vaultId, eventIds: plan.eventIds),
        );
        deletedEvents = response.deleted;
      } catch (e) {
        firstError ??= e;
      }
    }

    return JanitorResult(
      deletedBlobs: deletedBlobs,
      deletedEvents: deletedEvents,
      failedBlobs: failedBlobs,
      firstError: firstError?.toString(),
    );
  }
}

/// Preview of what cleanup would do. UI uses this to show stats.
class JanitorPlan {
  final int olderThanDays;
  final int totalEvents;
  final int eventsToDelete;
  final int eventsToKeep;
  final int orphanBlobCount;
  final List<String> eventIds;
  final List<String> blobIds;
  final DateTime? oldestDeletedAt;
  final DateTime? newestDeletedAt;
  final DateTime? oldestRemainingAt;
  final DateTime? newestRemainingAt;

  /// All heads reported to the server, including stale ones. UI may show
  /// per-device last-seen so the user can see why something is protected.
  final List<DeviceHead> knownDevices;

  /// Number of devices that the cleanup considered alive (last-reported
  /// head within deviceTtl). When zero, only age-based deletion is in
  /// force — no head safety could be enforced.
  final int activeDeviceCount;

  /// The minimum head across all active devices. Events with
  /// serverSeq > this value were kept regardless of their age, because
  /// some live device has not yet processed them. Null when no active
  /// device exists.
  final int? minSafeHead;

  /// Number of events that would have been deletable by age but were
  /// kept because they sit above [minSafeHead].
  final int eventsProtectedByHead;

  const JanitorPlan({
    required this.olderThanDays,
    required this.totalEvents,
    required this.eventsToDelete,
    required this.eventsToKeep,
    required this.orphanBlobCount,
    required this.eventIds,
    required this.blobIds,
    this.oldestDeletedAt,
    this.newestDeletedAt,
    this.oldestRemainingAt,
    this.newestRemainingAt,
    this.knownDevices = const [],
    this.activeDeviceCount = 0,
    this.minSafeHead,
    this.eventsProtectedByHead = 0,
  });

  bool get isEmpty => eventsToDelete == 0 && orphanBlobCount == 0;
}

class JanitorResult {
  final int deletedBlobs;
  final int deletedEvents;

  /// Blob ids the backend refused to delete. When > 0 the history events were
  /// deliberately kept (see [BlobJanitor.execute]) so a re-run can retry
  /// instead of stranding those blobs as unreferenced.
  final int failedBlobs;

  /// First backend error encountered (blob or event delete), for surfacing to
  /// the user. Null on full success.
  final String? firstError;

  const JanitorResult({
    required this.deletedBlobs,
    required this.deletedEvents,
    this.failedBlobs = 0,
    this.firstError,
  });

  bool get hadFailures => failedBlobs > 0 || firstError != null;
}
