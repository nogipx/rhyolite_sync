import 'package:http/http.dart' as http;
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';

import '../plan_tracker.dart';
import '../server_rejections.dart';
import '../session_contracts.dart';

/// How much of the vault this device uploads at once during the first pass.
///
/// StartupDiff holds N x file_bytes in memory while uploading, and on mobile
/// RAM is tight — with attachments in the megabyte range, four at a time can
/// take the host process down.
int startupUploadConcurrency({required bool isMobile}) => isMobile ? 2 : 4;

/// Bytes of a pull batch this device may hold in memory at once.
///
/// The batch is the chunks fetched but not yet written to disk. It used to be
/// staged in SQLite, which on this host meant a gigabyte of transit data
/// through an IndexedDB VFS whose write queue then never drained — so nothing
/// the pull banked survived, and every session restarted from where the last
/// one had. In memory it costs heap instead, and heap is the one budget that
/// differs sharply between the two places this plugin runs.
///
/// Mobile is a WebView inside a host app the OS will kill for using too much;
/// desktop is Electron with room to spare.
///
/// Measured rather than guessed: on a vault of ~2 MB attachments a 24 MB
/// budget covered twelve files of a thirty-two file batch, and the other
/// twenty fell back to fetching one file at a time — 1.3 to 3.4 seconds each
/// against 27 to 43 ms from the staging area. The buffer is transient and
/// released the moment its batch is applied, so covering a whole batch is
/// worth more than the megabytes saved by not.
int pullBatchBudgetBytes({required bool isMobile}) =>
    isMobile ? 64 * 1024 * 1024 : 192 * 1024 * 1024;

/// The engine, plus the two policies wired into it.
///
/// The policies are returned, not just installed, and they are the SAME closure
/// objects the engine holds — the engine exposes neither, so this is the only
/// way to state what was wired rather than restate it beside the real thing.
/// Both are read long after boot and both decide something destructive.
class EngineBoot {
  const EngineBoot({
    required this.engine,
    required this.maxFileSizeBytes,
    required this.siblingLiveBlobIds,
  });

  final StateSyncEngine engine;

  /// The managed per-file cap in force, or null for "no cap applies" — which
  /// covers both "no answer from the account service" and "BYO storage".
  final int? Function() maxFileSizeBytes;

  /// What settings sync still references. Empty, null and a set are three
  /// different answers; see where it is built.
  final Set<String>? Function() siblingLiveBlobIds;
}

/// Builds the sync engine for one plugin load.
///
/// Every Obsidian-facing part arrives as a parameter — the IO, the change
/// stream, the HTTP client — so the graph the plugin runs is the graph a test
/// can construct. That is the whole point of the phase: two of the callbacks
/// wired here decide whether a device silently stops uploading and whether the
/// blob GC eats every plugin the user has, and neither could be checked before.
EngineBoot buildSyncEngine({
  required String serverUrl,
  required VaultConfig config,
  required IVaultCipher? cipher,
  required IDataClient dataClient,
  required IBlobRepository blobRepository,
  required IPlatformIO io,
  required IChangeProvider changeProvider,
  required IVaultMetaStorage? metaStorage,
  required http.Client? httpClient,
  required ITaskScheduler scheduler,
  required LogScope logger,
  required bool isMobile,
  required String platformTag,
  required String clientVersion,
  required bool selfHost,

  /// The plan, read live: a tier change is picked up without rebuilding the
  /// engine.
  required PlanTracker plans,

  /// Settings sync, read live and possibly absent. Rebuilt on every relaunch,
  /// so this must be a lookup and never a captured instance.
  required SessionConfigSync? Function() configSync,

  /// Whether the user has settings sync switched on at all.
  required bool Function() settingsSyncEnabled,

  /// Per-device filters, read live so a settings change takes effect on the
  /// next reconcile without rebuilding the engine.
  required Set<String> Function() excludedExtensions,
  required PathScope Function() pathScope,

  /// How large the local database is right now, and how to make its pending
  /// writes real. Both are host business — only the plugin knows the file is
  /// SQLite over an IndexedDB VFS, and only it can flush that VFS — so the
  /// engine is given them rather than reaching for them.
  ///
  /// Null for either means "cannot answer", which the engine reads as no
  /// opinion rather than no room. Nothing else is safe: the filesystem client
  /// passes neither and must not be throttled for it.
  Future<int?> Function()? databaseBytes,
  Future<void> Function()? flushDatabase,
}) {
  // Built as locals and handed to both the engine and the caller, so what a
  // test reads is what the engine got rather than a second copy of it.
  //
  // The managed per-file size limit governs managed storage and nothing else:
  // on BYO we never see the bytes and the plan has no say over them.
  //
  // Keyed on the non-secret marker rather than on the credentials, which are
  // never persisted — the boot-time config has `externalBlobConfig == null`
  // even on a BYO vault, and asking it applied the managed cap to storage the
  // plan does not govern.
  int? maxFileSizeBytes() => config.externalStorageKind != null
      ? null
      : plans.capabilities?.maxFileSizeBytes;

  // Settings sync stores plugin-code blobs in the SAME local cache under the
  // same vaultId, but the engine's blob GC builds its live set from notes
  // alone. Without this hook the next housekeeping pass evicts every plugin
  // blob in the vault.
  //
  // The three answers are distinct and none is interchangeable:
  //   * empty  — settings sync is off, so nothing of ours is worth keeping,
  //              including leftovers from when it was on;
  //   * null   — on, but the store has not loaded, so we cannot answer. The GC
  //              must skip rather than guess;
  //   * a set  — the live blobs.
  //
  // Resolved per call: settings sync is rebuilt wholesale on every relaunch,
  // and a captured instance would keep answering from the dead one.
  Set<String>? siblingLiveBlobIds() {
    if (!settingsSyncEnabled()) return const <String>{};
    return configSync()?.liveBlobIds();
  }

  final engine = StateSyncEngine(
    vaultPath: '',
    serverUrl: serverUrl,
    config: config.copyWith(
      clientName: 'Obsidian/$platformTag',
      clientVersion: clientVersion,
      // Reported with this device's head so the device-management UI and
      // support can tell editions apart.
      clientKind: selfHost ? 'obsidian-selfhost' : 'obsidian',
    ),
    cipher: cipher,
    dataClient: dataClient,
    blobStore: LocalBlobStore(blobRepository),
    io: io,
    changeProvider: changeProvider,
    metaStorage: metaStorage,
    httpClient: httpClient,
    logger: logger,
    rejectionFactory: pluginRejectionFactory,
    startupUploadConcurrency: startupUploadConcurrency(isMobile: isMobile),
    pullBatchBudgetBytes: pullBatchBudgetBytes(isMobile: isMobile),
    scheduler: scheduler,
    maxFileSizeBytes: maxFileSizeBytes,
    excludedExtensions: excludedExtensions,
    // Narrowing takes effect on the next reconcile; widening needs the restart
    // the settings callback performs.
    pathScope: pathScope,
    databaseBytes: databaseBytes,
    flushDatabase: flushDatabase,
  );

  engine.siblingLiveBlobIds = siblingLiveBlobIds;

  return EngineBoot(
    engine: engine,
    maxFileSizeBytes: maxFileSizeBytes,
    siblingLiveBlobIds: siblingLiveBlobIds,
  );
}
