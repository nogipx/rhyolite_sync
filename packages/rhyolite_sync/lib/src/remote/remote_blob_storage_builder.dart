import 'package:http/http.dart' as http;
import 'package:rpc_dart/rpc_dart.dart';

import '../contract/blob_contract.dart';
import '../crypto/i_vault_cipher.dart';
import '../engine/vault_config.dart';
import 'encrypted_blob_storage.dart';
import 'gzip_blob_storage.dart';
import 'i_blob_storage.dart';
import 'remote_blob_storage.dart';

/// Assembles the *inner* remote [IBlobStorage] for a session (the engine
/// then wraps the result in a `BlobTransferHub`).
///
/// Injected into `StateSyncEngine` so engine tests can hand back a fake
/// blob backend instead of one bound to a real transport. Production omits
/// it and the engine falls back to [defaultRemoteBlobStorageBuilder].
///
/// [endpoint] is the live RPC endpoint (null before connect); it is only
/// consulted on the self-hosted gRPC path. Returns null when no backend
/// can be reached yet.
typedef RemoteBlobStorageBuilder =
    IBlobStorage? Function({
      required VaultConfig config,
      required IVaultCipher? cipher,
      required http.Client? httpClient,
      required RpcCallerEndpoint? endpoint,
    });

/// Default production stack: gzip-over-encrypt-over-backend.
///
/// Layer order matters: gzip MUST sit above whatever does encryption,
/// because ChaCha20 / AES-GCM ciphertext is high-entropy and not
/// compressible. On the external-blob path [EncryptedBlobStorage] owns the
/// encrypt step; on the self-hosted gRPC path [RemoteBlobStorage] encrypts
/// internally before streaming. In both branches we wrap the
/// encryption-aware storage in [GzipBlobStorage] so the plaintext gets
/// compressed before encryption.
IBlobStorage? defaultRemoteBlobStorageBuilder({
  required VaultConfig config,
  required IVaultCipher? cipher,
  required http.Client? httpClient,
  required RpcCallerEndpoint? endpoint,
}) {
  final extConfig = config.externalBlobConfig;
  if (extConfig != null) {
    return GzipBlobStorage(
      inner: EncryptedBlobStorage(
        inner: extConfig.createBlobStorage(
          vaultId: config.vaultId,
          httpClient: httpClient,
        ),
        cipher: cipher,
      ),
    );
  }
  if (endpoint == null) return null;
  return GzipBlobStorage(
    inner: RemoteBlobStorage(
      caller: BlobContractCaller(endpoint),
      vaultId: config.vaultId,
      cipher: cipher,
    ),
  );
}
