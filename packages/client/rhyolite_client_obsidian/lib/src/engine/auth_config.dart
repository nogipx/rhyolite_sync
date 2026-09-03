/// Account service configuration — stored in plaintext plugin data.
///
/// Kept out of `obsidian_config_storage.dart`, which needs a live plugin
/// handle: this is a value, every boot phase reads it, and a phase that has to
/// import the host to learn a URL cannot be run outside it.
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
