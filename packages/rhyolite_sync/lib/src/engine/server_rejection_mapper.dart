import 'sync_engine_event.dart';

/// Maps raw server-side error strings (RpcException messages) into typed
/// [SyncServerRejected] envelopes, and classifies which are *fatal*.
///
/// This is pure, fragile string/regex logic extracted from
/// `StateSyncEngine` so it can be unit-tested directly — the engine only
/// ever sees `e.toString()` from the transport, so the mapping is the one
/// place a server contract change can silently break rejection handling.
class ServerRejectionMapper {
  const ServerRejectionMapper({ServerRejectionFactory? factory})
      : _factory = factory;

  final ServerRejectionFactory? _factory;

  /// True when [e] is a *fatal* server rejection — one that won't be fixed
  /// by retrying the same call (auth.* / app_policy.*). The engine stops on
  /// the first fatal rejection so the host UI isn't pounded by hundreds of
  /// identical failures (every file's pull/push/reconcile).
  ///
  /// Informational rejections (`feature.*`) are not fatal — they trigger
  /// reconfiguration (e.g. external blob discovery → restart), not shutdown.
  bool isFatal(Object e) {
    final r = fromException(e);
    if (r == null) return false;
    return r.code.startsWith('auth.') || r.code.startsWith('app_policy.');
  }

  /// Maps a raw server-side error into a [SyncServerRejected] with a
  /// standard code, or null when the error does not look like a policy/auth
  /// rejection (caller surfaces it as a `SyncError` instead).
  SyncServerRejected? fromException(Object e) {
    final msg = e.toString();
    final lower = msg.toLowerCase();
    String? code;
    Map<String, dynamic> params = const {};
    if (lower.contains('unauthenticated')) {
      code = 'auth.session_expired';
    } else if (lower.contains('payment_required')) {
      code = 'app_policy.subscription_required';
    } else if (lower.contains('permission_denied')) {
      code = 'auth.permission_denied';
    } else {
      // Server-defined app_policy codes carry the form
      // `app_policy.<dimension>:k1=v1,k2=v2`. Parse out structured params.
      final policyMatch = RegExp(
        r'(app_policy\.[a-z0-9_.]+)(?::(.*))?',
      ).firstMatch(msg);
      if (policyMatch != null) {
        code = policyMatch.group(1);
        params = _parseParams(policyMatch.group(2));
      }
    }
    if (code == null) return null;
    return build(code, msg, params);
  }

  /// Builds a [SyncServerRejected] for an explicit code/message/params,
  /// applying the optional [ServerRejectionFactory] upgrade. Used for
  /// engine-originated informational rejections (e.g. external-blob
  /// discovery) that do not originate from an exception.
  SyncServerRejected build(
    String code,
    String message,
    Map<String, dynamic> params,
  ) =>
      _factory?.call(code, message, params) ??
      SyncServerRejected(code: code, message: message, params: params);

  Map<String, dynamic> _parseParams(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    final out = <String, dynamic>{};
    for (final pair in raw.split(',')) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      out[pair.substring(0, eq)] = pair.substring(eq + 1);
    }
    return out;
  }
}
