import 'dart:async';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Caps the size of a single state record on `putStates`.
///
/// `encryptedState` is opaque end-to-end-encrypted ciphertext — the server
/// never decrypts it, so it cannot validate the contents (e.g. that a notes
/// record holds only blob hashes). Size is the ONLY property the server can
/// enforce, so a crafted client can otherwise push a multi-MB record that
/// bloats the shared sync server on `MvRegister.join` + serialize and OOMs it
/// for EVERY vault. The transport's 16 MiB message cap and the 50 rps rate
/// limit raise the bar but don't prevent it.
///
/// This is NOT a billing/quota gate — it protects the server process from
/// OOM and applies in every edition (managed and self-host).
///
/// Per-keyspace limits, because legitimate sizes differ:
/// - **config** (`RhyoliteStateSync_config`): the `.obsidian` keyspace inlines
///   file content (and double-base64s it, so a record is ~1.8x the raw file),
///   but real settings records are kilobytes — [configMaxBytes] defaults to
///   3 MiB (~1.7 MB raw file), headroom for a heavy plugin's data.json.
/// - **notes** (`RhyoliteStateSync`): records are tiny manifests (blob hash +
///   chunk hashes); the limit only guards the opaque-ciphertext vector and must
///   stay above the largest legitimate manifest — [notesMaxBytes] defaults to
///   5 MiB.
///
/// Throws `RpcException('app_policy.quota.state_size:current=N,limit=M')`.
class StateRecordSizeInterceptor implements IRpcInterceptor {
  const StateRecordSizeInterceptor({
    this.notesMaxBytes = 5 << 20,
    this.configMaxBytes = 3 << 20,
  });

  /// Max bytes for one notes record's encrypted state (its base64 length).
  final int notesMaxBytes;

  /// Max bytes for one config (settings) record's encrypted state.
  final int configMaxBytes;

  static final String _notesService = StateSyncContractNames.service;
  static final String _configService =
      StateSyncContractNames.instance('config');

  /// The record-size limit for [serviceName], or null if it is not a
  /// state-sync `putStates` service.
  int? _limitFor(String serviceName) {
    if (serviceName == _notesService) return notesMaxBytes;
    if (serviceName == _configService) return configMaxBytes;
    return null;
  }

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) {
    final limit = _limitFor(call.serviceName);
    if (limit != null && request is StatePutRequest) {
      for (final item in request.items) {
        final size = item.encryptedState.length;
        if (size > limit) {
          throw RpcException(
            'app_policy.quota.state_size:current=$size,limit=$limit',
          );
        }
      }
    }
    return next(call.context, request);
  }

  // State sync is unary only; stream paths have nothing to enforce.
  @override
  FutureOr<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) =>
      next(call.context, request);

  @override
  FutureOr<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) =>
      next(call.context, requests);

  @override
  Future<TResponse> interceptClientStream<TRequest, TResponse>(
    RpcMiddlewareContext call,
    Stream<TRequest> requests,
    RpcClientStreamNext<TRequest, TResponse> next,
  ) =>
      next(call.context, requests);
}
