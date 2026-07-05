import 'package:rpc_dart/rpc_dart.dart';

import '../models/plan.dart';

abstract interface class ISubscriptionRepository {
  /// Quick liveness check used by [VaultPolicyInterceptor] to gate
  /// requests before they touch a responder. Returns `true` iff the
  /// user has any active paid plan, trial or promo.
  Future<bool> hasActiveSubscription(
    String userId, {
    required String userJwt,
    RpcContext? context,
  });

  /// Resolves the user's current [Plan] (capabilities + billing
  /// metadata). Returns `null` when no active subscription exists —
  /// daemon interceptors treat null as default-deny via
  /// [PlanCapabilities.deny].
  ///
  /// Implementations should cache the result for a short interval
  /// (~minutes) to avoid an extra RTT on every request.
  Future<Plan?> getPlan(
    String userId, {
    required String userJwt,
    RpcContext? context,
  });
}
