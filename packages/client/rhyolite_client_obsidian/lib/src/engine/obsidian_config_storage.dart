import 'dart:convert';

import 'package:crypto/crypto.dart' as pc;
import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import 'data_json_writer.dart';

/// Adapts the Obsidian [PluginHandle] to the testable [RawDataStore] seam.
class _PluginRawDataStore implements RawDataStore {
  _PluginRawDataStore(this._plugin);

  final PluginHandle _plugin;

  @override
  Future<Object?> load() => _plugin.loadData();

  @override
  Future<void> save(Map<String, dynamic> data) => _plugin.saveData(data);
}

/// Account service configuration — stored in plaintext plugin data.
class AuthConfig {
  const AuthConfig({required this.accountServiceUrl});

  final String accountServiceUrl;

  bool get isConfigured => accountServiceUrl.isNotEmpty;

  Map<String, dynamic> toJson() => {'accountServiceUrl': accountServiceUrl};

  factory AuthConfig.fromJson(Map<String, dynamic> json) {
    final url = json['accountServiceUrl'] as String? ?? '';

    if (url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri == null || uri.host.isEmpty) {
        throw FormatException(
          'AuthConfig: accountServiceUrl must be a valid URL',
          url,
        );
      }
    }

    return AuthConfig(accountServiceUrl: url);
  }

  AuthConfig copyWith({String? accountServiceUrl}) => AuthConfig(
    accountServiceUrl: accountServiceUrl ?? this.accountServiceUrl,
  );
}

class ObsidianConfigStorage {
  ObsidianConfigStorage(this._plugin)
      : _data = DataJsonWriter(_PluginRawDataStore(_plugin));

  final PluginHandle _plugin;

  /// All data.json reads/writes funnel through here so concurrent writers
  /// can't clobber each other and nested keys round-trip intact.
  final DataJsonWriter _data;

  static const _configKey = 'vaultConfig';
  static const _selfHostKey = 'selfHost';
  static const _rawKeySecret = 'rhyolite-vault-key';
  static const _sessionSecret = 'rhyolite-auth-token';
  static const _selfHostTokenSecret = 'rhyolite-selfhost-token';

  SecretStorageHandle get _secrets => _plugin.app.secretStorage;

  /// The vault encryption key is stored per rhyolite-vault: the keychain secret
  /// name carries a short hash of the vaultId. Without this, connecting a
  /// different rhyolite vault inside the same Obsidian vault would overwrite the
  /// previous vault's remembered key. A 16-hex-char sha256 prefix is collision-
  /// safe for the handful of vaults one device holds and doesn't leak the raw
  /// vaultId into the keychain entry name.
  static String _vaultKeySecretName(String vaultId) {
    final tag = pc.sha256.convert(utf8.encode(vaultId)).toString();
    return '$_rawKeySecret-${tag.substring(0, 16)}';
  }

  // ---------------------------------------------------------------------------
  // Load / create
  // ---------------------------------------------------------------------------

  Future<VaultConfig?> tryLoad() async {
    try {
      final config = (await _data.read())[_configKey];
      if (config == null) return null;
      // _data.read() already deep-converted, so this is a Dart map.
      return VaultConfig.fromJson(Map<String, dynamic>.from(config as Map));
    } catch (_) {
      return null;
    }
  }

  /// Attempts to unlock the vault cipher without a passphrase (remembered
  /// key), verifying it against [verificationToken] before use. Returns null
  /// when no valid key is stored — the caller then prompts for the passphrase.
  ///
  /// The keychain secret is keyed per rhyolite-vault (see [_vaultKeySecretName]),
  /// so different vaults in one Obsidian vault keep independent remembered keys.
  /// The verification still guards a stale key. Boot previously used the stored
  /// key blind, which would then fail to decrypt.
  Future<VaultCipher?> tryUnlockFromStorage(
    String vaultId,
    String verificationToken,
  ) async {
    final secretName = _vaultKeySecretName(vaultId);
    final rawKeyB64 = await _secrets.getSecret(secretName);
    if (rawKeyB64 == null) return null;
    final VaultCipher cipher;
    try {
      cipher = VaultCipher.fromRawKey(base64Decode(rawKeyB64));
    } catch (_) {
      await _secrets.deleteSecret(secretName);
      return null;
    }
    if (verificationToken.isNotEmpty &&
        !await cipher.verifyToken(verificationToken)) {
      return null;
    }
    return cipher;
  }

  /// Enables E2EE on an existing vault (migration). Preserves vaultId and other settings.
  Future<(VaultConfig, VaultCipher)> enableE2ee({
    required VaultConfig existing,
    required String passphrase,
  }) async {
    final cipher = await VaultCipher.derive(passphrase, existing.vaultId);
    final verificationToken = await cipher.createVerificationToken();
    final config = existing.copyWith(
      verificationToken: verificationToken,
    );
    await save(config);
    return (config, cipher);
  }

  /// Creates a new vault with E2EE. Always enabled in Obsidian plugin.
  Future<(VaultConfig, VaultCipher)> createWithE2ee({
    required String vaultName,
    required String passphrase,
  }) async {
    final config = VaultConfig.newVault(
      vaultName: vaultName,
    );
    final cipher = await VaultCipher.derive(passphrase, config.vaultId);
    final verificationToken = await cipher.createVerificationToken();
    final configWithToken = config.copyWith(
      verificationToken: verificationToken,
    );
    await save(configWithToken);
    return (configWithToken, cipher);
  }

  // ---------------------------------------------------------------------------
  // Save
  // ---------------------------------------------------------------------------

  Future<void> save(VaultConfig config) =>
      _data.update((m) => m[_configKey] = config.toJson());

  // ---------------------------------------------------------------------------
  // Self-host mode: point the plugin at a self-hosted sync server with a
  // static bearer token instead of the managed account service. Mode + URL
  // live in data.json; the token is a secret (system keychain).
  // ---------------------------------------------------------------------------

  Future<({bool enabled, String syncUrl})> loadSelfHost() async {
    final sh = (await _data.read())[_selfHostKey];
    if (sh is Map) {
      return (
        enabled: sh['enabled'] == true,
        syncUrl: (sh['syncUrl'] as String?) ?? '',
      );
    }
    return (enabled: false, syncUrl: '');
  }

  Future<void> saveSelfHost({
    required bool enabled,
    required String syncUrl,
  }) =>
      _data.update(
        (m) => m[_selfHostKey] = {'enabled': enabled, 'syncUrl': syncUrl},
      );

  Future<String?> loadSelfHostToken() =>
      _secrets.getSecret(_selfHostTokenSecret);

  Future<void> saveSelfHostToken(String token) =>
      _secrets.setSecret(_selfHostTokenSecret, token);

  Future<void> clearSelfHostToken() =>
      _secrets.deleteSecret(_selfHostTokenSecret);

  /// Persists the `.obsidian` settings-sync preferences under their own
  /// data.json key, preserving all other keys.
  Future<void> saveSettingsSync(Map<String, Object?> json) =>
      _data.update((m) => m['settingsSync'] = json);

  /// Persists the remote diagnostics-logging preferences under their own
  /// data.json key, preserving all other keys.
  Future<void> saveDiagnostics(Map<String, Object?> json) =>
      _data.update((m) => m['diagnostics'] = json);

  /// Persists the per-device file-type sync filter under its own data.json key,
  /// preserving all other keys.
  Future<void> saveFileFilter(Map<String, Object?> json) =>
      _data.update((m) => m['fileFilter'] = json);

  /// User-requested sync pause (from the side panel). When true, boot skips
  /// the initial `engine.start()`; sync stays off until the user resumes.
  /// Survives restarts. Explicit user actions (sign-in, config change) still
  /// start the engine and are expected to clear this flag.
  Future<bool> loadPaused() async =>
      (await _data.read())['syncPaused'] == true;

  Future<void> savePaused(bool paused) =>
      _data.update((m) => m['syncPaused'] = paused);

  // ---------------------------------------------------------------------------
  // Remember passphrase
  // ---------------------------------------------------------------------------

  Future<void> rememberKey(VaultCipher cipher, String vaultId) async {
    await _secrets.setSecret(
      _vaultKeySecretName(vaultId),
      base64Encode(cipher.rawKeyBytes),
    );
  }

  Future<void> forgetKey(String vaultId) async {
    await _secrets.deleteSecret(_vaultKeySecretName(vaultId));
  }

  /// Clears vault config and remembered key — "disconnect from vault".
  /// Auth config and session are not touched. The vaultId is resolved from the
  /// stored config before it is removed, so the right per-vault key is dropped.
  Future<void> disconnectVault() async {
    final vaultId = (await tryLoad())?.vaultId ?? '';
    await _data.update((m) => m.remove(_configKey));
    if (vaultId.isNotEmpty) {
      await _secrets.deleteSecret(_vaultKeySecretName(vaultId));
    }
  }

  // ---------------------------------------------------------------------------
  // Account session (access + refresh token stored in the system keychain).
  // No API keys are embedded in the build — build_env.kEnv holds only URLs.
  // ---------------------------------------------------------------------------

  Future<AuthSession?> loadAuthSession() async {
    final raw = await _secrets.getSecret(_sessionSecret);
    if (raw == null) return null;
    try {
      return AuthSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      await _secrets.deleteSecret(_sessionSecret);
      return null;
    }
  }

  Future<void> saveAuthSession(AuthSession session) async {
    await _secrets.setSecret(_sessionSecret, jsonEncode(session.toJson()));
  }

  Future<void> clearAuthSession() async {
    await _secrets.deleteSecret(_sessionSecret);
  }
}
