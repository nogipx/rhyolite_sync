import 'dart:async';

import 'package:rhyolite_sync/rhyolite_sync.dart' show RhyoliteAuthKeys;
import 'package:rpc_dart/rpc_dart.dart';

/// Single-tenant auth for the self-host edition.
///
/// The whole instance is owned by one principal, so there is no account
/// service, no token minting and no per-vault ownership: the only
/// question is "does the caller hold the shared secret?". On success the
/// caller is stamped as a fixed principal so downstream code
/// (rate-limiter keying, logging) has a stable userId.
///
/// Why auth is always on: end-to-end encryption protects content
/// confidentiality only. An unauthenticated, internet-exposed sync
/// endpoint still leaks vault existence/metadata and lets anyone delete
/// or overwrite blobs (integrity) or exhaust storage (availability).
class SharedSecretAuthInterceptor implements IRpcInterceptor {
  SharedSecretAuthInterceptor({
    required String sharedSecret,
    String principalId = 'local',
    Set<String> publicMethods = const {},
  })  : _sharedSecret = sharedSecret,
        _principalId = principalId,
        _publicMethods = publicMethods;

  /// The expected Bearer token.
  final String _sharedSecret;
  final String _principalId;
  final Set<String> _publicMethods;

  bool _isPublic(RpcMiddlewareContext call) =>
      _publicMethods.contains('${call.serviceName}/${call.methodName}') ||
      _publicMethods.contains(call.methodName);

  RpcContext _authenticate(RpcMiddlewareContext call) {
    final authHeader = call.context.getHeader('authorization');
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      throw RpcException(
        'unauthenticated: missing or invalid Authorization header',
      );
    }
    final token = authHeader.substring('Bearer '.length);
    if (!_constantTimeEquals(token, _sharedSecret)) {
      throw RpcException('unauthenticated: invalid token');
    }
    return call.context.withValue(RhyoliteAuthKeys.userId, _principalId);
  }

  /// Length-independent constant-time comparison to avoid leaking the
  /// secret's length/prefix via response timing.
  static bool _constantTimeEquals(String a, String b) {
    final ab = a.codeUnits;
    final bb = b.codeUnits;
    var diff = ab.length ^ bb.length;
    final n = ab.length < bb.length ? ab.length : bb.length;
    for (var i = 0; i < n; i++) {
      diff |= ab[i] ^ bb[i];
    }
    return diff == 0;
  }

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    if (!_isPublic(call)) call.updateContext(_authenticate(call));
    return next(call.context, request);
  }

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    if (!_isPublic(call)) call.updateContext(_authenticate(call));
    return next(call.context, request);
  }

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    if (!_isPublic(call)) call.updateContext(_authenticate(call));
    return next(call.context, requests);
  }

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    if (!_isPublic(call)) call.updateContext(_authenticate(call));
    return next(call.context, requests);
  }
}
