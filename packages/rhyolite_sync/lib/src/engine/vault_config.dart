import 'package:uuid/uuid.dart';

import '../auth/i_token_provider.dart';
import '../remote/external_blob_config.dart';

/// Throws [FormatException] if [value] does not look like a UUID v4.
String _requireUuid(String value, String field) {
  final uuidRe = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  if (!uuidRe.hasMatch(value)) {
    throw FormatException('VaultConfig: invalid UUID in field "$field"', value);
  }
  return value;
}

/// Strips ASCII control characters and limits length.
/// Throws [FormatException] if [value] is empty after sanitization or exceeds [maxLen].
String _sanitizeText(String value, String field, {int maxLen = 256}) {
  final sanitized = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
  if (sanitized.isEmpty) {
    throw FormatException(
      'VaultConfig: field "$field" is empty after sanitization',
    );
  }
  if (sanitized.length > maxLen) {
    throw FormatException(
      'VaultConfig: field "$field" exceeds $maxLen characters',
    );
  }
  return sanitized;
}

/// Validates that [value] contains only base64 characters (+ padding).
/// Throws [FormatException] otherwise.
String _requireBase64(String value, String field) {
  final b64Re = RegExp(r'^[A-Za-z0-9+/=]+$');
  if (!b64Re.hasMatch(value)) {
    throw FormatException(
      'VaultConfig: field "$field" contains invalid base64 characters',
      value,
    );
  }
  return value;
}

class VaultConfig {
  const VaultConfig({
    required this.vaultId,
    required this.vaultName,
    this.verificationToken,
    this.pullIntervalSeconds = 5,
    this.tokenProvider,
    this.deviceId,
    this.clientName,
    this.clientVersion,
    this.clientKind,
    this.externalBlobConfig,
    this.externalStorageKind,
  });

  factory VaultConfig.newVault({
    required String vaultName,
    int pullIntervalSeconds = 5,
  }) => VaultConfig(
    vaultId: const Uuid().v4(),
    vaultName: vaultName,
    pullIntervalSeconds: pullIntervalSeconds,
  );

  factory VaultConfig.fromJson(Map<String, dynamic> json) {
    final rawToken = json['verificationToken'] as String?;
    // MIGRATION: older data.json stored the full (secret-bearing)
    // externalBlobConfig in cleartext. We still read it so the current session
    // has a fallback, but it is NEVER re-serialised (see [toJson]) — the
    // caller re-saves on boot to strip the cleartext, and the secret is
    // henceforth sourced only from the E2EE server config.
    final legacy = ExternalBlobConfig.fromJson(
      json['externalBlobConfig'] as Map<String, dynamic>?,
    );
    return VaultConfig(
      vaultId: _requireUuid(json['vaultId'] as String, 'vaultId'),
      vaultName: _sanitizeText(json['vaultName'] as String, 'vaultName'),
      verificationToken: rawToken != null
          ? _requireBase64(rawToken, 'verificationToken')
          : null,
      pullIntervalSeconds: ((json['pullIntervalSeconds'] as int? ?? 5)).clamp(
        5,
        3600,
      ),
      externalBlobConfig: legacy,
      // Non-secret marker: prefer the explicit field, else derive from a legacy
      // cleartext config during migration.
      externalStorageKind:
          (json['externalStorageKind'] as String?) ?? legacy?.kind,
    );
  }

  final String vaultId;
  final String vaultName;

  /// Encrypted verification token — used to validate the passphrase without
  /// storing the raw key. Base64 of encrypt("rhyolite-verify").
  final String? verificationToken;
  final int pullIntervalSeconds;

  /// Optional token provider. When set, a [BearerTokenInterceptor] is
  /// added to the RPC endpoint to attach Bearer tokens to every call.
  /// Not serialized to/from JSON — must be set in code.
  final ITokenProvider? tokenProvider;

  /// This install's identity for THIS vault, supplied by the host.
  ///
  /// The sync database used to own it, which meant every reset, restore or
  /// recovery minted a new one and left a phantom device head on the server —
  /// and a phantom head holds `min(headSeq)` down, freezing tombstone GC for
  /// the whole stale window. Hosts that persist this outside the database
  /// (the plugin keeps a per-vault map in `data.json`) keep one head per
  /// install no matter what happens to local storage.
  ///
  /// Per vault on purpose: two vaults on the same machine get unrelated ids,
  /// so a server operator cannot tell they belong to one person. Null keeps
  /// the old behaviour — the store mints and remembers its own.
  final String? deviceId;

  /// Optional client identifier sent as x-client-name header on every request.
  /// Not serialized to/from JSON — must be set in code.
  final String? clientName;

  /// Client version (e.g. "3.4.3") reported with the device head for the
  /// device-management UI + support diagnostics. Code-set, not serialized.
  final String? clientVersion;

  /// Client kind (`obsidian` / `cli` / `selfhost`) reported with the device
  /// head. Code-set, not serialized.
  final String? clientKind;

  /// Optional external blob storage config (secret-bearing). When set, the
  /// client uploads/downloads blobs directly instead of proxying through the
  /// sync server. Supports S3 and WebDAV backends.
  ///
  /// **Never persisted to `data.json`** (see [toJson]) — the secret is stored
  /// only in the E2EE server config and re-fetched into memory each session.
  /// The local, non-secret [externalStorageKind] marks the vault as BYO.
  final ExternalBlobConfig? externalBlobConfig;

  /// Non-secret BYO marker (`s3` / `webdav` / null), safe to persist locally.
  /// Lets a device know it is BYO even before the secret [externalBlobConfig]
  /// is fetched from the server — so a failed fetch pauses sync instead of
  /// silently falling back to the managed backend (which would upload the
  /// user's blobs to the wrong place).
  final String? externalStorageKind;

  VaultConfig copyWith({
    String? vaultId,
    String? vaultName,
    String? verificationToken,
    int? pullIntervalSeconds,
    ITokenProvider? tokenProvider,
    String? deviceId,
    String? clientName,
    String? clientVersion,
    String? clientKind,
    ExternalBlobConfig? externalBlobConfig,
    String? externalStorageKind,
  }) => VaultConfig(
    vaultId: vaultId ?? this.vaultId,
    vaultName: vaultName ?? this.vaultName,
    verificationToken: verificationToken ?? this.verificationToken,
    pullIntervalSeconds: pullIntervalSeconds ?? this.pullIntervalSeconds,
    tokenProvider: tokenProvider ?? this.tokenProvider,
    deviceId: deviceId ?? this.deviceId,
    clientName: clientName ?? this.clientName,
    clientVersion: clientVersion ?? this.clientVersion,
    clientKind: clientKind ?? this.clientKind,
    externalBlobConfig: externalBlobConfig ?? this.externalBlobConfig,
    externalStorageKind: externalStorageKind ?? this.externalStorageKind,
  );

  Map<String, dynamic> toJson() => {
    'vaultId': vaultId,
    'vaultName': vaultName,
    if (verificationToken != null) 'verificationToken': verificationToken,
    'pullIntervalSeconds': pullIntervalSeconds,
    // NOTE: externalBlobConfig (the SECRET) is deliberately NOT serialised —
    // it lives only in the E2EE server config. Only the non-secret marker is
    // persisted locally.
    if (externalStorageKind != null) 'externalStorageKind': externalStorageKind,
  };
}
