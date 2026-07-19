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

/// Whether [relPath] is a safe vault-relative path — i.e. writing
/// `<vaultRoot>/<relPath>` cannot escape the vault directory.
///
/// A pulled record's path comes from the (decrypted) payload of a peer that
/// holds the vault key. A crafted `..`/absolute/NUL path would otherwise let a
/// malicious or compromised device write or delete files anywhere the client
/// process can reach (`~/.ssh/authorized_keys`, shell rc files, autostart
/// entries…). Every remote path is validated here BEFORE it enters the
/// FileStateStore, so the downstream disk writes (materialise, conflict-copy,
/// union) — which all derive their path from the stored FileState — are
/// confined by construction. This mirrors the settings-sync `classify()` guard.
///
/// An empty path is treated as safe: it carries no location and downstream
/// writers skip it (`if (path.isNotEmpty)`).
bool isSafeVaultRelPath(String relPath) {
  if (relPath.isEmpty) return true;
  if (relPath.contains('\x00')) return false; // NUL byte
  // Absolute paths escape the vault root: POSIX "/…", Windows "\…" / UNC
  // "\\host\share", and drive-qualified "C:\…".
  if (relPath.startsWith('/') || relPath.startsWith(r'\')) return false;
  if (RegExp(r'^[A-Za-z]:').hasMatch(relPath)) return false;
  // Any ".." segment (under either separator) can climb out of the vault.
  for (final segment in relPath.split(RegExp(r'[/\\]'))) {
    if (segment == '..') return false;
  }
  return true;
}
