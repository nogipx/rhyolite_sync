/// True when compiled with `--dart-define=RHYOLITE_DEBUG=true`.
/// In production builds this is false and logging is disabled.
const kDebug = bool.fromEnvironment('RHYOLITE_DEBUG', defaultValue: false);

class RhyoliteEnvironment {
  const RhyoliteEnvironment({
    required this.accountServiceUrl,
    required this.syncServiceUrl,
  });

  final String accountServiceUrl;
  final String syncServiceUrl;
}

/// Resolves environment from compile-time dart-define constants only.
/// Values are baked in at build time — never read from data.json.
const RhyoliteEnvironment kEnv = RhyoliteEnvironment(
  accountServiceUrl: String.fromEnvironment('ACCOUNT_SERVICE_URL'),
  syncServiceUrl: String.fromEnvironment('SYNC_SERVICE_URL'),
);
