/// Self-host edition of the Rhyolite sync server.
///
/// Single-tenant: one shared secret, no account service, no billing,
/// no per-vault ownership. Composes the shared
/// `rhyolite_sync_server_runtime` building blocks with a shared-secret
/// auth interceptor in `bin/server.dart`.
library;

export 'package:rhyolite_sync_server_runtime/rhyolite_sync_server_runtime.dart';

export 'src/interceptors/shared_secret_auth_interceptor.dart';
export 'src/responders/vault_registry_responder.dart';
