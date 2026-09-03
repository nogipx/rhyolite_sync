import '../crypto/i_vault_cipher.dart';
import '../scheduler/i_task_scheduler.dart';
import '../use_cases/conflict_list_use_case.dart';
import '../use_cases/vault_stats_use_case.dart';
import 'vault_config.dart';
import 'sync_engine_event.dart';

/// Common interface for sync engines.
///
/// Both [SyncEngine] (graph-based) and [CrdtSyncEngine] (CRDT-based)
/// implement this, allowing plugin.dart and UI components to work
/// with either implementation.
/// The outcome of [ISyncEngine.probe].
enum EngineProbe {
  /// The roundtrip completed. The connection is usable.
  alive,

  /// The engine is running but the roundtrip failed or timed out. May be a
  /// dead socket, may be a busy one — the probe cannot tell, and the host's
  /// recovery ladder decides by how recently the engine spoke.
  unreachable,

  /// The engine is not running. Nothing to wait for and nothing to nudge: no
  /// amount of patience turns a stopped engine into a live one.
  stopped,
}

abstract interface class ISyncEngine {
  Stream<SyncEngineEvent> get events;

  /// The engine's current session config/cipher. Exposed as getters so
  /// host UI (e.g. the settings tab) can read the LIVE values after a vault
  /// switch instead of a snapshot captured at registration time.
  VaultConfig get config;
  set config(VaultConfig config);
  IVaultCipher? get cipher;
  set cipher(covariant IVaultCipher? cipher);

  /// Starts a sync session.
  ///
  /// [token] lets the caller abandon a start that is no longer wanted — the
  /// host schedules lifecycle work on a single lane, so a start that hangs
  /// delays every later one, including the user pressing Resume. The engine
  /// checks it between phases and threads it into the cancellable RPCs.
  Future<void> start({TaskCancelToken? token});
  Future<void> stop();
  Future<void> dispose();

  /// Read-only aggregate snapshot of the local store (file/blob counts, size,
  /// server cursor). Null when the engine has no store yet (not started).
  /// Cheap — in-memory, safe to poll from UI.
  VaultStats? statsSnapshot();

  /// Files whose register currently has more than one surviving value —
  /// i.e. an unresolved multi-value conflict. Empty when not started.
  List<ConflictedFile> conflictSnapshot();

  Future<void> triggerPull();
  Future<void> triggerReset();
  Future<void> triggerRestoreFromServer();
  Future<void> triggerRepair();

  /// Wipes every local trace of the currently-configured vault: the file
  /// state store, the fugue tree store, and the local blob cache. Does
  /// NOT talk to the server. Intended for the "disconnect from vault"
  /// flow so a later reconnect — to the same or a different vault —
  /// starts from a clean local slate. Engine must be stopped first.
  Future<void> wipeLocalState();

  /// Cheap roundtrip to verify the engine's connection is alive.
  ///
  /// Prefer [probe], which distinguishes the two ways this returns false. This
  /// stays for callers that only need a yes/no.
  Future<bool> healthCheck({Duration timeout = const Duration(seconds: 5)});

  /// What a health probe found.
  ///
  /// [healthCheck] collapses two opposite facts into `false`: the socket did
  /// not answer, and the engine is not running at all. They call for opposite
  /// responses — wait out a slow socket, restart a stopped engine — and the
  /// host could not tell them apart, so it read the second as the first. In
  /// one report an engine that answered `stopped` in zero milliseconds was
  /// classified "alive, do not disturb" four times running while the vault sat
  /// broken.
  Future<EngineProbe> probe({Duration timeout = const Duration(seconds: 5)});

  /// Re-establishes the live server-notify subscription on the current
  /// connection, idempotently. Notify is a best-effort push channel; its
  /// server-stream can go silent (e.g. a logical stream closed while the
  /// socket stays alive) without a connection-state transition to trigger the
  /// engine's own reissue. Hosts call this on resume-from-background when
  /// [healthCheck] passed (socket alive) to keep push-driven pulls flowing.
  /// No-op when the engine is not started.
  Future<void> reissueNotify();
}
