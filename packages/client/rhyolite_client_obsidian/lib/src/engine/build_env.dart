/// True when compiled with `--dart-define=RHYOLITE_DEBUG=true`.
/// In production builds this is false and logging is disabled.
const kDebug = bool.fromEnvironment('RHYOLITE_DEBUG', defaultValue: false);

class RhyoliteEnvironment {
  const RhyoliteEnvironment({
    required this.accountServiceUrl,
    required this.syncServiceUrl,
    required this.siteUrl,
  });

  final String accountServiceUrl;
  final String syncServiceUrl;

  /// Public site base URL (e.g. https://rhyolite.nogipx.dev). Browser-auth —
  /// the plugin's single sign-in method — opens `$siteUrl/auth?client=plugin`;
  /// the site logs the user in on the web and redirects back to
  /// `obsidian://rhyolite-auth?code=...`.
  final String siteUrl;
}

/// Resolves environment from compile-time dart-define constants only.
/// Values are baked in at build time — never read from data.json.
const RhyoliteEnvironment kEnv = RhyoliteEnvironment(
  accountServiceUrl: String.fromEnvironment('ACCOUNT_SERVICE_URL'),
  syncServiceUrl: String.fromEnvironment('SYNC_SERVICE_URL'),
  siteUrl: String.fromEnvironment('SITE_URL'),
);
