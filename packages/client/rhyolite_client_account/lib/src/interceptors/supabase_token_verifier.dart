import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:rpc_dart/rpc_dart.dart';

import '../auth_keys.dart';

class SupabaseTokenVerifier implements IRpcInterceptor {
  SupabaseTokenVerifier({
    required String supabaseUrl,
    required String supabaseServiceRoleKey,
    Set<String> publicMethods = const {},
  }) : _supabaseUrl = supabaseUrl,
       _serviceRoleKey = supabaseServiceRoleKey,
       _publicMethods = publicMethods;

  final String _supabaseUrl;
  final String _serviceRoleKey;
  final Set<String> _publicMethods;

  bool _isPublic(RpcMiddlewareContext call) =>
      _publicMethods.contains('${call.serviceName}/${call.methodName}') ||
      _publicMethods.contains(call.methodName);

  Future<RpcContext> _authenticate(RpcMiddlewareContext call) async {
    final authHeader = call.context.getHeader('authorization');
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      throw RpcException(
        'unauthenticated: missing or invalid Authorization header',
      );
    }

    final token = authHeader.substring('Bearer '.length);

    final uri = Uri.parse('$_supabaseUrl/auth/v1/user');
    final response = await http.get(
      uri,
      headers: {'apikey': _serviceRoleKey, 'Authorization': 'Bearer $token'},
    );

    if (response.statusCode != 200) {
      throw RpcException('unauthenticated: invalid token');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final userId = body['id'] as String?;
    if (userId == null) {
      throw RpcException('unauthenticated: user id not found in token');
    }

    return call.context
        .withValue(RhyoliteAuthKeys.userId, userId)
        .withValue(RhyoliteAuthKeys.userToken, token);
  }

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    if (!_isPublic(call)) call.updateContext(await _authenticate(call));
    return next(call.context, request);
  }

  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async {
    if (!_isPublic(call)) call.updateContext(await _authenticate(call));
    return next(call.context, request);
  }

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) async {
    if (!_isPublic(call)) call.updateContext(await _authenticate(call));
    return next(call.context, requests);
  }

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async {
    if (!_isPublic(call)) call.updateContext(await _authenticate(call));
    return next(call.context, requests);
  }
}
