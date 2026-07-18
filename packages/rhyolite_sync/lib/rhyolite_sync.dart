/// Δ-state CRDT file sync engine with formal convergence properties.
///
/// Public surface for client integrations. Consumer is expected to
/// provide:
///   - `IPlatformIO` for filesystem access
///   - `IChangeProvider` for local file change events
///   - `IBlobStorage` for remote blob storage backend (or use one of
///     the bundled impls: `RemoteBlobStorage`, `HttpBlobStorage`,
///     `S3BlobStorage`)
///   - `IVaultMetaStorage` for external blob config persistence
///     (optional — only needed if you ship external blob storage)
///   - An `IDataClient` (rpc_data) for local key-value persistence
///   - An `IVaultCipher` for E2EE (or use the default `VaultCipher`)
///
/// See README.md for the full integration guide.
library;

// --- Wire protocol (contracts + DTOs) ----------------------------------
export 'src/contract/backup_contract.dart';
export 'src/contract/blob_contract.dart';
export 'src/contract/history_contract.dart';
export 'src/contract/vault_maintenance_contract.dart';
export 'src/contract/state_sync_contract.dart';
export 'src/contract/vault_registry_contract.dart';

// --- Platform interfaces (consumer implements) -------------------------
export 'src/changes/i_change_provider.dart';
export 'src/platform/i_platform_io.dart';

// --- Auth + transport interceptor --------------------------------------
export 'src/auth/auth_keys.dart';
export 'src/auth/bearer_token_interceptor.dart';
export 'src/auth/i_token_provider.dart';
export 'src/auth/i_vault_auth_repository.dart';

// --- Crypto ------------------------------------------------------------
export 'src/crypto/i_vault_cipher.dart';
export 'src/crypto/passphrase_validator.dart';
export 'src/crypto/vault_cipher.dart';

// --- Chunking ----------------------------------------------------------
export 'src/chunking/blob_manifest.dart';
export 'src/chunking/content_defined_chunker.dart';
export 'src/chunking/file_type_detector.dart';

// --- Blob storage interface + bundled backends -------------------------
export 'src/remote/blob_transfer_hub.dart';
export 'src/remote/i_blob_storage.dart';
export 'src/remote/i_vault_meta_storage.dart';
export 'src/remote/remote_blob_storage_builder.dart';
export 'src/remote/encrypted_blob_storage.dart';
export 'src/remote/gzip_blob_storage.dart';
export 'src/remote/remote_blob_storage.dart';
export 'src/remote/external_blob_config.dart';
export 'src/remote/http_blob_auth.dart';
export 'src/remote/http_blob_storage.dart';
export 'src/remote/s3_blob_storage.dart';
export 'src/remote/vault_meta_service.dart';
export 'src/local/local_blob_store.dart';
export 'src/local/local_blob_storage_adapter.dart';

// --- Sync engine + state types -----------------------------------------
export 'src/engine/i_sync_engine.dart';
export 'src/engine/server_rejection_mapper.dart';
export 'src/engine/sync_engine_event.dart';
export 'src/engine/vault_config.dart';
export 'src/sync_v3/blob_janitor.dart';
export 'src/sync_v3/chunked_blob_io.dart';
export 'src/sync_v3/content_materializer.dart';
export 'src/sync_v3/file_state.dart';
export 'src/sync_v3/file_state_store.dart';
export 'src/sync_v3/file_version_viewer.dart';
export 'src/sync_v3/fugue_store.dart';
export 'src/sync_v3/fugue_text_sync.dart';
export 'src/sync_v3/history_browser.dart';
export 'src/sync_v3/local_blob_gc.dart';
export 'src/sync_v3/notify_coordinator.dart';
export 'src/sync_v3/stat_sig_store.dart';
export 'src/sync_v3/state_conflict_resolver.dart';
export 'src/sync_v3/state_startup_diff.dart';
export 'src/sync_v3/state_sync_engine.dart';
export 'src/sync_v3/sync_connection.dart';

// --- Scheduler (host-owned task lane) ----------------------------------
export 'src/scheduler/priority_task_scheduler.dart';

// --- Settings sync (.obsidian config keyspace) -------------------------
export 'src/settings_sync/canonical_json.dart';
export 'src/settings_sync/resource_crdt_codec.dart';
export 'src/settings_sync/settings_store.dart';
export 'src/settings_sync/settings_sync.dart';

// --- Use cases (consumer-facing helpers) -------------------------------
export 'src/use_cases/conflict_list_use_case.dart';
export 'src/use_cases/device_registry_use_case.dart';
export 'src/use_cases/diff_text_use_case.dart';
export 'src/use_cases/export_vault_use_case.dart';
export 'src/use_cases/inspect_backup_use_case.dart';
export 'src/use_cases/repair_vault_use_case.dart';
export 'src/use_cases/restore_backup_use_case.dart';
export 'src/use_cases/vault_stats_use_case.dart';
export 'src/use_cases/verify_blobs_use_case.dart';
