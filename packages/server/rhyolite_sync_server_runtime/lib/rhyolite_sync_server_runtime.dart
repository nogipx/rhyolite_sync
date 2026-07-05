/// Shared server composition for Rhyolite sync.
///
/// Edition-agnostic building blocks reused by both the managed
/// (`rhyolite_sync_server_managed`) and self-host
/// (`rhyolite_sync_server_selfhost`) editions:
/// - infra modules: Postgres, MinIO, WebSocket listener
/// - [SyncServerModule]: the pure sync responders (policy-free)
/// - [StateRecordSizeInterceptor]: OOM guard (not a billing gate)
///
/// Auth / subscription / vault-ownership / quota policy is NOT here —
/// each edition composes its own interceptor pipeline in `bin/server.dart`.
library;

export 'src/modules/in_memory_notify_module.dart';
export 'src/modules/minio_module.dart';
export 'src/modules/postgres_module.dart';
export 'src/modules/sync_server_module.dart';
export 'src/modules/websocket_listener_module.dart';
export 'src/interceptors/state_record_size_interceptor.dart';
