/// The vault-auth seam now lives in the engine (`rhyolite_sync`) so both
/// editions can implement it without depending on the account package.
/// Re-exported here for backward compatibility.
export 'package:rhyolite_sync/rhyolite_sync.dart' show IVaultAuthRepository;
