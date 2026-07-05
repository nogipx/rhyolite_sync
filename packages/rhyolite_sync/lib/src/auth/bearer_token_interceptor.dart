import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import 'i_token_provider.dart';

/// Client-side interceptor that injects a Bearer token into every
/// outgoing request. Works with any auth backend (Supabase JWT, PASETO,
/// HMAC) — token retrieval and refresh is delegated to [ITokenProvider].
class BearerTokenInterceptor implements IRpcInterceptor {
  BearerTokenInterceptor(this._provider);

  final ITokenProvider _provider;

  Future<RpcContext> _withToken(RpcMiddlewareContext call) async {
    final token = await _provider.getToken();
    return RpcContextBuilder.inheritFrom(
      call.context,
    ).withBearerAuth(token).build();
  }

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    call.updateContext(await _withToken(call));
    return next(call.context, request);
  }

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    call.updateContext(await _withToken(call));
    return next(call.context, request);
  }

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    call.updateContext(await _withToken(call));
    return next(call.context, requests);
  }

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    call.updateContext(await _withToken(call));
    return next(call.context, requests);
  }
}
