import 'dart:async';
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
/// Entry point, with the one thing standing between a stray async error and
/// a dead replica.
///
/// There was no zone handler here, so ANY error that escaped an async gap
/// took the process with it — and one did: both replicas exited 255 within
/// hours of each other on
/// `RpcCancelledException: last subscriber left`, a reason string that
/// originates in a CLIENT abandoning a coalesced blob download and travels
/// back in the cancellation. A peer hanging up must not be able to end a
/// server, and the fanout it took down with it (the Redis notify bus dies
/// with the process) is how it became visible at all.
///
/// It logs the STACK, which the bare crash did not: the exception line alone
/// named the reason and not the raiser, and that is why the path was still
/// unidentified after the incident.
///
/// Deliberately not a catch-all over startup: errors from the awaited run
/// still propagate to the await below. This handler sees only what would
/// otherwise have gone unhandled.
Future<void> main() async {
  final done = Completer<void>();
  runZonedGuarded(
    () async {
      try {
        await _run();
      } finally {
        if (!done.isCompleted) done.complete();
      }
    },
    (Object error, StackTrace stack) {
      stderr.writeln('[sync] UNHANDLED async error (process kept alive): '
          '$error\n$stack');
    },
  );
  await done.future;
}

Future<void> _run() async {
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
    perService: {
      // Same reasoning as the managed edition: bulk blob transfer is bursty by
      // nature and must not be measured against a control-plane budget. The
      // 200/conn below is already four times more generous and keyed per
      // device rather than per account, so this edition was never as exposed —
      // but a first sync of a large vault has the same shape here, and finding
      // that out from a self-hoster is worse than the three lines it costs.
      'RhyoliteBlob': RateLimit.tokenBucket(
        max: 300,
        window: Duration(seconds: 1),
        burst: 600,
      ),
    },
    perKeyFallback: RateLimit.slidingWindow(
      max: 200,
      window: Duration(seconds: 1),
    ),
    keyExtractor: (call) => 'conn:${call.endpoint.hashCode}',
  );

  await RpcApp.server(
    modules: [
      PostgresModule(logger: logController.scope('rhyolite.sync.selfhost')),
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
