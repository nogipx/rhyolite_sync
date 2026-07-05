import 'package:rpc_dart/rpc_dart.dart';

/// Resolves the vault <-> principal relationship for the policy layer.
///
/// This is the seam between editions:
/// - managed binds it to the account service over HTTP (vault ownership
///   lives in a separate, horizontally-scaled store);
/// - self-host binds it to a local registry in the same database (one
///   instance, no external account service).
abstract interface class IVaultAuthRepository {
  Future<bool> userOwnsVault(String userId, String vaultId, {RpcContext? context});
  Future<void> createVaultForUser(String userId, String vaultId, {RpcContext? context});
}
