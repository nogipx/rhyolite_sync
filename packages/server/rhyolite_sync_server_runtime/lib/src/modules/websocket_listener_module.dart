import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'minio_module.dart';
import 'postgres_module.dart';

/// Binds an HTTP server and upgrades incoming WebSocket connections.
///
/// Create once before [RpcApp.server] and pass [connections] to the
/// transport server factory:
/// ```dart
/// final wsModule = WebSocketListenerModule();
/// await RpcApp.server(
///   modules: [..., wsModule],
///   server: (onEndpoint) => RpcWebSocketServer(
///     connections: wsModule.connections,
///     onEndpointCreated: onEndpoint,
///   ),
/// ).run();
/// ```
///
/// The HTTP server is bound in [onStart] — after all data modules are ready —
/// so clients cannot connect until the full stack is initialised.
class WebSocketListenerModule extends RpcModule {
  WebSocketListenerModule({LogScope? logger}) : _log = logger ?? LogScope.noop;

  final LogScope _log;

  @override
  String get name => 'WebSocketListenerModule';

  @override
  List<Type> get dependencies => [PostgresModule, MinioModule];

  final _controller = StreamController<WebSocketChannel>.broadcast();

  /// Stream of accepted WebSocket connections. Pass to [RpcWebSocketServer].
  Stream<WebSocketChannel> get connections => _controller.stream;

  late int _port;
  HttpServer? _httpServer;

  @override
  void configureWithEnv(RpcContainer container, RpcEnvConfig env) {
    _port = env.getInt('WS_PORT') ?? 9765;
  }

  @override
  Future<void> onStart(RpcContainer container) async {
    _httpServer = await HttpServer.bind('0.0.0.0', _port, shared: true);
    _httpServer!.listen(
      (req) async {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          final ws = await WebSocketTransformer.upgrade(req);
          _controller.add(IOWebSocketChannel(ws));
        } else {
          req.response.statusCode = 426;
          await req.response.close();
        }
      },
      onError: (Object e) => _log.error('listener error', error: e),
    );
  }

  @override
  Future<void> onStop() async {
    await _httpServer?.close();
    await _controller.close();
  }
}
