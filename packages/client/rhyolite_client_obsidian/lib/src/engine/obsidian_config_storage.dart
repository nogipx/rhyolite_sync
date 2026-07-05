import 'dart:convert';

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Deep-converts a JS object tree to Dart Maps/Lists.
/// Obsidian's loadData() returns JS objects; shallow Map.from()
/// leaves nested objects as opaque JSObjects that fail type casts.
Map<String, dynamic> _deepConvert(Map map) {
  final result = <String, dynamic>{};
  for (final entry in map.entries) {
    final key = entry.key.toString();
    final value = entry.value;
    if (value is Map) {
      result[key] = _deepConvert(value);
    } else if (value is List) {
      result[key] = value.map((e) => e is Map ? _deepConvert(e) : e).toList();
    } else {
      result[key] = value;
    }
  }
  return result;
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
  const ObsidianConfigStorage(this._plugin);

  final PluginHandle _plugin;

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
    final data = await _plugin.loadData();
    if (data == null) return null;
    try {
      final map = data as Map<Object?, Object?>;
      final config = map[_configKey];
      if (config == null) return null;
      return VaultConfig.fromJson(_deepConvert(config as Map));
    } catch (_) {
      return null;
    }
  }

  /// Attempts to unlock the vault cipher without a passphrase (remembered key).
  /// Returns null if no key is remembered.
  Future<VaultCipher?> tryUnlockFromStorage() async {
    final rawKeyB64 = await _secrets.getSecret(_rawKeySecret);
    if (rawKeyB64 == null) return null;
    try {
      return VaultCipher.fromRawKey(base64Decode(rawKeyB64));
    } catch (_) {
      await _secrets.deleteSecret(_rawKeySecret);
      return null;
    }
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

  Future<void> save(VaultConfig config) async {
    final raw = await _plugin.loadData();
    final map = Map<String, dynamic>.from(raw as Map? ?? {});
    map[_configKey] = config.toJson();
    await _plugin.saveData(map);
  }

  // ---------------------------------------------------------------------------
  // Self-host mode: point the plugin at a self-hosted sync server with a
  // static bearer token instead of the managed account service. Mode + URL
  // live in data.json; the token is a secret (system keychain).
  // ---------------------------------------------------------------------------

  Future<({bool enabled, String syncUrl})> loadSelfHost() async {
    final data = await _plugin.loadData();
    if (data is Map) {
      final sh = _deepConvert(data)[_selfHostKey];
      if (sh is Map) {
        return (
          enabled: sh['enabled'] == true,
          syncUrl: (sh['syncUrl'] as String?) ?? '',
        );
      }
    }
    return (enabled: false, syncUrl: '');
  }

  Future<void> saveSelfHost({
    required bool enabled,
    required String syncUrl,
  }) async {
    final raw = await _plugin.loadData();
    final map = Map<String, dynamic>.from(raw as Map? ?? {});
    map[_selfHostKey] = {'enabled': enabled, 'syncUrl': syncUrl};
    await _plugin.saveData(map);
  }

  Future<String?> loadSelfHostToken() =>
      _secrets.getSecret(_selfHostTokenSecret);

  Future<void> saveSelfHostToken(String token) =>
      _secrets.setSecret(_selfHostTokenSecret, token);

  Future<void> clearSelfHostToken() =>
      _secrets.deleteSecret(_selfHostTokenSecret);

  /// Persists the `.obsidian` settings-sync preferences under their own
  /// data.json key, preserving all other keys.
  Future<void> saveSettingsSync(Map<String, Object?> json) async {
    final raw = await _plugin.loadData();
    final map = Map<String, dynamic>.from(raw as Map? ?? {});
    map['settingsSync'] = json;
    await _plugin.saveData(map);
  }

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
    final raw = await _plugin.loadData();
    final map = Map<String, dynamic>.from(raw as Map? ?? {});
    map.remove(_configKey);
    await _plugin.saveData(map);
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
