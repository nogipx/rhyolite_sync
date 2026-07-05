import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

import 'models/plan_capabilities.dart';

/// The dependency-free auth surface (keys + userId/role/planId getters)
/// now lives in the engine (`rhyolite_sync`) so both editions share it.
/// Re-exported here for backward compatibility with existing account
/// consumers.
export 'package:rhyolite_sync/rhyolite_sync.dart'
    show RhyoliteAuthKeys, RhyoliteAuthContext;

/// Billing-bound auth claims. Kept in the managed edition because they
/// depend on [PlanCapabilities]; the engine stays free of the
/// capability/billing model.
extension RhyoliteAuthCapsContext on RpcContext {
  /// Returns the capability snapshot or [PlanCapabilities.deny] when
  /// no plan claim is present (no active subscription).
  PlanCapabilities get rhyoliteCaps =>
      getValue<PlanCapabilities>(RhyoliteAuthKeys.caps) ??
      PlanCapabilities.deny;

  /// `true` when an active subscription claim exists and the current
  /// time is before its embedded expiry. Fully stateless.
  bool get rhyoliteSubscriptionActive {
    final exp = getValue<int>(RhyoliteAuthKeys.subscriptionExpiresAt);
    if (exp == null) return false;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 < exp;
  }
}
