import 'dart:convert';
import 'dart:typed_data';

import '../crypto/i_vault_cipher.dart';
import 'external_blob_config.dart';
import 'i_vault_meta_storage.dart';

/// Saves and loads encrypted vault metadata (e.g. external blob config)
/// via an [IVaultMetaStorage] backend. The backend stores only an opaque
/// encrypted byte string — `VaultMetaService` handles the crypto wrap.
///
/// [cipher] is REQUIRED. External storage credentials (S3 keys, WebDAV
/// passwords) must never reach the server in cleartext. Constructing
/// without a cipher used to silently fall back to a plaintext upload,
/// which is exactly the security hole this layer exists to prevent.
/// Callers must obtain the vault cipher (passphrase-derived) before
/// touching this service.
class VaultMetaService {
  VaultMetaService({
    required this.storage,
    required this.vaultId,
    required this.cipher,
  });

  final IVaultMetaStorage storage;
  final String vaultId;
  final IVaultCipher cipher;

  /// Encrypts and uploads [config] to the storage backend.
  Future<void> saveExternalBlobConfig(ExternalBlobConfig config) async {
    final json = jsonEncode(config.toJson());
    final encrypted = await cipher.encrypt(
      Uint8List.fromList(utf8.encode(json)),
    );
    await storage.setEncryptedMeta(vaultId, base64Encode(encrypted));
  }

  /// Downloads and decrypts the external blob config. Returns null if
  /// the server has no stored config, or if decryption fails (wrong
  /// passphrase, corrupted bytes, schema mismatch).
  Future<ExternalBlobConfig?> loadExternalBlobConfig() async {
    final payload = await storage.getEncryptedMeta(vaultId);
    if (payload == null || payload.isEmpty) return null;
    try {
      final encrypted = base64Decode(payload);
      final decrypted = await cipher.decrypt(encrypted);
      final json = jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>;
      return ExternalBlobConfig.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Removes stored config.
  Future<void> clearExternalBlobConfig() async {
    await storage.setEncryptedMeta(vaultId, '');
  }
}
