import 'dart:convert';

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
  /// The keychain secret is per Obsidian vault, so this is a single key; the
  /// verification guards the one case that key can be stale: switching the
  /// rhyolite vault within one Obsidian vault without re-remembering. Boot
  /// previously used the stored key blind, which would then fail to decrypt.
  Future<VaultCipher?> tryUnlockFromStorage(String verificationToken) async {
    final rawKeyB64 = await _secrets.getSecret(_rawKeySecret);
    if (rawKeyB64 == null) return null;
    final VaultCipher cipher;
    try {
      cipher = VaultCipher.fromRawKey(base64Decode(rawKeyB64));
    } catch (_) {
      await _secrets.deleteSecret(_rawKeySecret);
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

  Future<void> rememberKey(VaultCipher cipher) async {
    await _secrets.setSecret(_rawKeySecret, base64Encode(cipher.rawKeyBytes));
  }

  Future<void> forgetKey() async {
    await _secrets.deleteSecret(_rawKeySecret);
  }

  /// Clears vault config and remembered key — "disconnect from vault".
  /// Auth config and session are not touched.
  Future<void> disconnectVault() async {
    await _data.update((m) => m.remove(_configKey));
    await _secrets.deleteSecret(_rawKeySecret);
  }

  // ---------------------------------------------------------------------------
  // Auth config — Supabase URL + anon key come from compile-time dart-define
  // constants only and are never stored in data.json.
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Supabase session (access + refresh token stored in system keychain)
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
