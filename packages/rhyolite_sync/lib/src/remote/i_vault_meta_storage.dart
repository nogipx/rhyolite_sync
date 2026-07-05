/// Opaque per-vault metadata storage.
///
/// The sync engine uses this to persist a small encrypted blob — typically
/// the user's external blob storage config (S3/WebDAV credentials, etc.) —
/// somewhere durable so it survives reinstalls and travels to new devices
/// at sign-in time.
///
/// Implementation is up to the embedder. In the bundled Obsidian plugin
/// it is backed by the account server; embedders without an account
/// service can back it with anything (a local file, their own KV store,
/// or just `_NullVaultMetaStorage` to disable the feature).
abstract interface class IVaultMetaStorage {
  /// Returns the base64-encoded encrypted meta blob previously written
  /// for [vaultId], or null when nothing has been stored yet.
  Future<String?> getEncryptedMeta(String vaultId);

  /// Persists [encryptedMeta] for [vaultId]. Pass an empty string to
  /// clear the slot.
  Future<void> setEncryptedMeta(String vaultId, String encryptedMeta);
}
