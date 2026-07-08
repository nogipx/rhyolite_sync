import '../crypto/i_vault_cipher.dart';
import '../use_cases/conflict_list_use_case.dart';
import '../use_cases/vault_stats_use_case.dart';
import 'vault_config.dart';
import 'sync_engine_event.dart';

/// Common interface for sync engines.
///
/// Both [SyncEngine] (graph-based) and [CrdtSyncEngine] (CRDT-based)
/// implement this, allowing plugin.dart and UI components to work
/// with either implementation.
abstract interface class ISyncEngine {
  Stream<SyncEngineEvent> get events;

  /// The engine's current session config/cipher. Exposed as getters so
  /// host UI (e.g. the settings tab) can read the LIVE values after a vault
  /// switch instead of a snapshot captured at registration time.
  VaultConfig get config;
  set config(VaultConfig config);
  IVaultCipher? get cipher;
  set cipher(covariant IVaultCipher? cipher);

  Future<void> start();
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

  /// Cheap roundtrip to verify the engine's connection is alive. Returns
  /// false on timeout or any error — the caller is expected to follow up
  /// with `stop()` + `start()` to rebuild the underlying transport.
  ///
  /// Intended for resume-from-background flows where the WebSocket may
  /// have died silently while the host process was suspended.
  Future<bool> healthCheck({Duration timeout = const Duration(seconds: 5)});

  /// Re-establishes the live server-notify subscription on the current
  /// connection, idempotently. Notify is a best-effort push channel; its
  /// server-stream can go silent (e.g. a logical stream closed while the
  /// socket stays alive) without a connection-state transition to trigger the
  /// engine's own reissue. Hosts call this on resume-from-background when
  /// [healthCheck] passed (socket alive) to keep push-driven pulls flowing.
  /// No-op when the engine is not started.
  Future<void> reissueNotify();
}
