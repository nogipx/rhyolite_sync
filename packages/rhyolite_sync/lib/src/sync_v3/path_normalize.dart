import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// NFC-normalizes a vault-relative path.
///
/// A file's identity is derived from its relative path — `HMAC-SHA256(recordIdKey,
/// "vaultId|relPath")` once a vault key exists (keyless fallback: `Uuid().v5`) —
/// and its stored FileState.path is written back to disk verbatim.
/// Filesystems disagree on Unicode form: macOS/APFS and iOS commonly return
/// decomposed (NFD) filenames, while Linux/Windows keep whatever bytes they
/// were given. Without normalization the *same* logical file — e.g. a Russian
/// name containing «й»/«ё» or accented Latin, all of which decompose — hashes
/// to two different fileIds across devices and churns forever (phantom
/// create/delete that never converges).
///
/// Normalizing every path the engine ingests to NFC makes both the fileId and
/// the stored path stable regardless of the platform's form. Pure ASCII paths
/// are unchanged (NFC is a no-op on them), so the common case pays nothing.
String normalizeVaultPath(String relPath) => unorm.nfc(relPath);
