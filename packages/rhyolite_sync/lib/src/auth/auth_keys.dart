import 'package:rpc_dart/rpc_dart.dart';

/// Context keys populated by the auth interceptor after a Bearer token
/// is verified. Everything here is a snapshot frozen at session-mint
/// time — staleness window = access token TTL.
///
/// These keys live in the engine (not in any edition package) so both
/// the managed PASETO verifier and the self-host shared-secret auth
/// interceptor write to the SAME context keys, and the policy
/// interceptors read them uniformly.
abstract final class RhyoliteAuthKeys {
  static const String userId = 'rhyolite.userId';
  static const String userToken = 'rhyolite.userToken';

  /// User role string. Compare via `UserRole.isAdmin(...)`.
  static const String role = 'rhyolite.role';

  /// Plan id active at session-mint time. `null` if the user has no
  /// active subscription (signed up but never paid / trialled).
  static const String planId = 'rhyolite.planId';

  /// Capability snapshot for the active plan, stored as an opaque
  /// value. The concrete type lives in the edition that mints tokens
  /// (managed). Self-host never sets this key.
  static const String caps = 'rhyolite.caps';

  /// Unix-seconds expiry of the active subscription period. `null`
  /// when no active plan. Lets per-request gates detect mid-token
  /// subscription expiry without a DB lookup.
  static const String subscriptionExpiresAt = 'rhyolite.subExp';
}

/// Dependency-free accessors over [RpcContext] for the auth claims set
/// by the auth interceptor. Pure indirection — no IO, no plan/billing
/// types. Billing-bound accessors (caps, subscription) live in the
/// managed edition alongside the capability model.
extension RhyoliteAuthContext on RpcContext {
  String? get rhyoliteUserId => getValue<String>(RhyoliteAuthKeys.userId);
  String? get rhyoliteUserToken => getValue<String>(RhyoliteAuthKeys.userToken);
  String? get rhyoliteRole => getValue<String>(RhyoliteAuthKeys.role);
  String? get rhyolitePlanId => getValue<String>(RhyoliteAuthKeys.planId);
}
