import 'dart:convert';
import 'dart:typed_data';

import '../crypto/i_vault_cipher.dart';
import 'external_blob_config.dart';
import 'i_vault_meta_storage.dart';

/// Saves and loads encrypted vault metadata via an [IVaultMetaStorage]
/// backend. The backend stores only an opaque encrypted byte string — one
/// slot per vault — so `VaultMetaService` packs every vault-global setting
/// into a single JSON map and handles the crypto wrap.
///
/// Currently the map carries two things:
///   * the external blob config (S3/WebDAV BYO credentials), spread at the
///     TOP LEVEL under its own `type` discriminator, and
///   * [_forcedBinaryKey]: the user's force-binary extension list.
///
/// The layout is FORWARD-COMPATIBLE by design: an older client only ever
/// reads the external blob config, and [ExternalBlobConfig.fromJson] keys off
/// `type` — it ignores the extra [_forcedBinaryKey] entry, and returns null
/// when there is no BYO config (no `type`). So a new client writing the
/// combined map never breaks an old client's credential load. Writers
/// read-modify-write to preserve the sibling field.
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

  /// Top-level key holding the vault-global force-binary extension list
  /// (lowercase, no dot). Kept OUT of the external-blob namespace so an old
  /// client parsing the map for BYO credentials ignores it.
  static const _forcedBinaryKey = 'forcedBinaryExtensions';

  /// Encrypts and uploads [config], preserving any stored policy.
  Future<void> saveExternalBlobConfig(ExternalBlobConfig config) async {
    final current = await _loadRaw();
    final next = <String, dynamic>{
      ...config.toJson(),
      if (current[_forcedBinaryKey] != null)
        _forcedBinaryKey: current[_forcedBinaryKey],
    };
    await _saveRaw(next);
  }

  /// Downloads and decrypts the external blob config. Returns null if
  /// the server has no stored config, or if decryption fails (wrong
  /// passphrase, corrupted bytes, schema mismatch).
  Future<ExternalBlobConfig?> loadExternalBlobConfig() async =>
      ExternalBlobConfig.fromJson(await _loadRaw());

  /// The vault-global force-binary extension set (lowercase, no dot), or
  /// empty when none is stored / the payload can't be read.
  Future<Set<String>> loadForcedBinaryExtensions() async {
    final raw = (await _loadRaw())[_forcedBinaryKey];
    if (raw is! List) return const <String>{};
    return {
      for (final e in raw)
        if (e is String && e.trim().isNotEmpty) e.trim().toLowerCase(),
    };
  }

  /// Persists the force-binary extension set, preserving any external blob
  /// config. Values are normalised (trimmed, lowercased, leading dot dropped);
  /// an empty set removes the policy from the slot.
  Future<void> saveForcedBinaryExtensions(Set<String> extensions) async {
    final normalized = (extensions
          .map(_normalizeExtension)
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList())
      ..sort();
    final next = <String, dynamic>{...await _loadRaw()};
    if (normalized.isEmpty) {
      next.remove(_forcedBinaryKey);
    } else {
      next[_forcedBinaryKey] = normalized;
    }
    await _saveRaw(next);
  }

  /// Removes the external blob config, preserving any stored policy.
  Future<void> clearExternalBlobConfig() async {
    final current = await _loadRaw();
    final next = <String, dynamic>{
      if (current[_forcedBinaryKey] != null)
        _forcedBinaryKey: current[_forcedBinaryKey],
    };
    await _saveRaw(next);
  }

  /// Decrypts and decodes the raw meta map, or `{}` when absent/unreadable.
  Future<Map<String, dynamic>> _loadRaw() async {
    final payload = await storage.getEncryptedMeta(vaultId);
    if (payload == null || payload.isEmpty) return <String, dynamic>{};
    try {
      final decrypted = await cipher.decrypt(base64Decode(payload));
      final json = jsonDecode(utf8.decode(decrypted));
      return json is Map<String, dynamic> ? json : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Encrypts and stores [json]; an empty map clears the slot.
  Future<void> _saveRaw(Map<String, dynamic> json) async {
    if (json.isEmpty) {
      await storage.setEncryptedMeta(vaultId, '');
      return;
    }
    final encrypted = await cipher.encrypt(
      Uint8List.fromList(utf8.encode(jsonEncode(json))),
    );
    await storage.setEncryptedMeta(vaultId, base64Encode(encrypted));
  }

  static String _normalizeExtension(String raw) {
    var e = raw.trim().toLowerCase();
    while (e.startsWith('.')) {
      e = e.substring(1);
    }
    return e;
  }
}
