import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth/bearer_token_interceptor.dart';
import '../auth/i_token_provider.dart';
import '../contract/history_contract.dart';
import '../contract/state_sync_contract.dart';

/// Connection lifecycle transitions the engine reacts to, distilled from
/// rpc_dart's richer `RpcClientState` into the three cases the engine
/// actually branches on.
enum SyncConnState { connecting, online, offline }

/// The live RPC surface for one sync session: an authenticated transport
/// plus the contract callers built on it.
///
/// Extracted from `StateSyncEngine` so the engine's orchestration can be
/// driven against a fake connection in tests instead of a real WebSocket.
/// The production implementation is [WebSocketSyncConnection]; tests
/// supply their own with canned [IStateSyncContract] / [IHistoryContract]
/// callers.
///
/// The callers are exposed as their hand-written interfaces (not the
/// generated `*Caller` classes) precisely so a fake is a plain
/// `implements IStateSyncContract` — no transport stubbing required.
abstract interface class SyncConnection {
  /// Opens the transport and returns once online. Throws if the initial
  /// connect fails — the engine maps that to a `SyncError` / rejection.
  Future<void> connect();

  /// The live endpoint. Used to build the blob caller, wire notify, and
  /// share the authenticated socket with the settings-sync sibling.
  /// Valid only after [connect] has completed.
  RpcCallerEndpoint get endpoint;

  IStateSyncContract get stateCaller;
  IHistoryContract get historyCaller;

  /// Transport transitions AFTER the initial connect. The engine reissues
  /// the notify subscription + a catch-up pull on each return to
  /// [SyncConnState.online] — rpc_dart does not carry in-flight calls
  /// across a reconnect, so the notify server-stream goes silent until
  /// it is reissued on the fresh transport.
  Stream<SyncConnState> get stateChanges;

  Future<void> dispose();
}

/// Builds the [SyncConnection] for a session. Injected into
/// `StateSyncEngine` so tests can swap in a fake; production omits it and
/// the engine falls back to [WebSocketSyncConnection].
typedef SyncConnectionFactory =
    SyncConnection Function({
      required String serverUrl,
      ITokenProvider? tokenProvider,
      LogScope? logger,
    });

/// Production [SyncConnection]: a reconnecting WebSocket transport with the
/// retry + bearer-token interceptor stack and the generated contract
/// callers.
class WebSocketSyncConnection implements SyncConnection {
  WebSocketSyncConnection({
    required this.serverUrl,
    this.tokenProvider,
    LogScope? logger,
  }) : _log = logger ?? LogScope.noop;

  /// Matches [SyncConnectionFactory] so it can be passed directly as the
  /// engine's default connection factory.
  static SyncConnection factory({
    required String serverUrl,
    ITokenProvider? tokenProvider,
    LogScope? logger,
  }) => WebSocketSyncConnection(
    serverUrl: serverUrl,
    tokenProvider: tokenProvider,
    logger: logger,
  );

  final String serverUrl;
  final ITokenProvider? tokenProvider;
  final LogScope _log;

  RpcClientConnection? _connection;
  RpcCallerEndpoint? _endpoint;
  StateSyncContractCaller? _stateCaller;
  HistoryContractCaller? _historyCaller;

  @override
  Future<void> connect() async {
    final wsUri = _toWsUri(serverUrl);
    final connection = RpcClientConnection(
      transportFactory: () async {
        final ch = WebSocketChannel.connect(wsUri);
        await ch.ready;
        _log.info('WebSocket connected to $wsUri');
        return RpcWebSocketCallerTransport(ch);
      },
      maxAttempts: 3,
      shouldReconnect: (_) => true,
    );
    _connection = connection;
    connection.connect();
    await connection.state.firstWhere(
      (s) => s is RpcClientOnline || s is RpcClientDisconnected,
    );
    if (connection.currentState is RpcClientDisconnected) {
      throw Exception('Failed to connect to server');
    }

    final endpoint = RpcCallerEndpoint(transport: connection.transport);
    // Outermost interceptor (added first -> wraps the whole call): retry
    // transient unary failures with backoff — the server's rate limit
    // (RESOURCE_EXHAUSTED) under parallel startup, and UNAVAILABLE. Covers
    // unary calls only; the blob upload is a client-stream and is retried
    // inside RemoteBlobStorage.upload instead.
    endpoint.addInterceptor(
      RpcRetryInterceptor(
        maxAttempts: 5,
        backoff: const ExponentialBackoff(
          baseDelay: Duration(milliseconds: 200),
          maxDelay: Duration(seconds: 5),
        ),
      ),
    );
    if (tokenProvider != null) {
      endpoint.addInterceptor(BearerTokenInterceptor(tokenProvider!));
    }
    _endpoint = endpoint;
    _stateCaller = StateSyncContractCaller(endpoint);
    _historyCaller = HistoryContractCaller(endpoint);
  }

  @override
  RpcCallerEndpoint get endpoint => _endpoint!;

  @override
  IStateSyncContract get stateCaller => _stateCaller!;

  @override
  IHistoryContract get historyCaller => _historyCaller!;

  @override
  Stream<SyncConnState> get stateChanges =>
      _connection!.state.expand((s) {
        final mapped = _mapState(s);
        return mapped == null ? const <SyncConnState>[] : [mapped];
      });

  @override
  Future<void> dispose() async {
    _connection?.dispose();
    _connection = null;
    _endpoint = null;
    _stateCaller = null;
    _historyCaller = null;
  }

  /// Maps rpc_dart's connection state onto [SyncConnState]. Returns null
  /// for states the engine ignores (e.g. `RpcClientIdle`), which the
  /// [stateChanges] stream then drops.
  static SyncConnState? _mapState(RpcClientConnectionState s) {
    if (s is RpcClientConnecting) return SyncConnState.connecting;
    if (s is RpcClientOnline) return SyncConnState.online;
    if (s is RpcClientDisconnected) return SyncConnState.offline;
    return null;
  }

  static Uri _toWsUri(String url) {
    var u = url;
    if (u.startsWith('https://')) u = 'wss://${u.substring(8)}';
    if (u.startsWith('http://')) u = 'ws://${u.substring(7)}';
    if (!u.startsWith('ws')) u = 'wss://$u';
    return Uri.parse(u);
  }
}
