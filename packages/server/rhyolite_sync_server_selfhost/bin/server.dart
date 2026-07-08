import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:rhyolite_observability/rhyolite_observability.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart' show RhyoliteAuthKeys;
import 'package:rhyolite_sync_server_selfhost/rhyolite_sync_server_selfhost.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:rpc_data/rpc_data.dart';

/// Self-host sync server entry point.
///
/// One process owns everything: sync + blobs + single-tenant auth.
/// No account service, no billing, no per-vault ownership. State lives
/// in Postgres + MinIO, so the process itself stays stateless.
Future<void> main() async {
  // ignore: invalid_use_of_visible_for_testing_member
  final env = (DotEnv(includePlatformEnvironment: true)..load(['.env'])).map;

  final obs = await RhyoliteObservability.init(
    serviceName: 'rhyolite_sync-selfhost',
  );

  final logController = LogController(outputs: [ConsoleOutput()]);

  final sharedSecret = _resolveSharedSecret(env);

  final wsModule = WebSocketListenerModule();

  // Single principal — rate-limit per connection so multiple devices of
  // the one owner don't share a single bucket.
  final rateLimiter = RpcRateLimiter(
    perKeyFallback: RateLimit.slidingWindow(
      max: 200,
      window: Duration(seconds: 1),
    ),
    keyExtractor: (call) => 'conn:${call.endpoint.hashCode}',
  );

  await RpcApp.server(
    modules: [
      PostgresModule(),
      // Single process, single tenant: notify only fans out to this process's
      // own connected devices, so an in-memory bus is sufficient (and has no
      // network leg to go stale). Do not scale self-host past one replica.
      InMemoryNotifyModule(),
      MinioModule(),
      wsModule,
      // Self-host serves its own vault registry + encrypted meta (no account
      // service). The pure sync responders come from the shared module; the
      // registry responder is injected here.
      SyncServerModule(
        extraContracts: (c) => [
          LocalVaultRegistryResponder(client: c.get<IDataClient>()),
        ],
      ),
    ],
    server: (onEndpoint) => RpcWebSocketServer(
      connections: wsModule.connections,
      onEndpointCreated: onEndpoint,
      logController: logController,
    ),
    interceptors: [
      obs.rpcInterceptor,
      SharedSecretAuthInterceptor(sharedSecret: sharedSecret),
      UserIdSpanInterceptor(userIdKey: RhyoliteAuthKeys.userId),
      rateLimiter,
    ],
    config: RpcAppConfig(
      env: env,
      logController: logController,
      logger: logController.scope('rhyolite.sync.selfhost'),
    ),
  ).run();

  rateLimiter.dispose();
}

/// Resolves the required shared secret. Auth is always on — a self-host
/// server must be reachable only by clients holding the token.
String _resolveSharedSecret(Map<String, String> env) {
  final token = env['RHYOLITE_SYNC_TOKEN'];
  if (token == null || token.isEmpty) {
    stderr.writeln(
      '\n[selfhost] FATAL: RHYOLITE_SYNC_TOKEN is not set.\n'
      '           Set it to a long random secret '
      '(e.g. `openssl rand -hex 32`).\n',
    );
    exit(78); // EX_CONFIG
  }
  return token;
}
