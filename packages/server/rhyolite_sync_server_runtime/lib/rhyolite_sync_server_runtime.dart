/// Shared server composition for Rhyolite sync.
///
/// Edition-agnostic building blocks reused by both the managed
/// (`rhyolite_sync_server_managed`) and self-host
/// (`rhyolite_sync_server_selfhost`) editions:
/// - infra modules: Postgres, MinIO, WebSocket listener
/// - [SyncServerModule]: the pure sync responders (policy-free), including a
///   per-item record-size OOM guard (rejects over-cap putStates items
///   individually instead of failing the whole batch)
///
/// Auth / subscription / vault-ownership / quota policy is NOT here —
/// each edition composes its own interceptor pipeline in `bin/server.dart`.
library;

export 'src/modules/in_memory_notify_module.dart';
export 'src/modules/minio_module.dart';
export 'src/modules/postgres_module.dart';
export 'src/modules/sync_server_module.dart';
export 'src/modules/websocket_listener_module.dart';
