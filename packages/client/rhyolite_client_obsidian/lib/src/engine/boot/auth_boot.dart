import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';

import '../../vault/vault_directory.dart';
import '../auth_config.dart';
import '../auth_recovery.dart';
import '../auth_session_state.dart';
import '../plan_status.dart';

/// What [bootstrapAuth] reads and writes in `data.json`.
///
/// The concrete store is `ObsidianConfigStorage`, which needs a live plugin
/// handle. Naming the six calls this phase makes keeps the phase itself free of
/// the host — and a boot phase that cannot be run outside Obsidian is a boot
/// phase nobody has ever run twice.
abstract interface class AuthBootStorage {
  Future<PlanSnapshot?> loadPlan();
  Future<({bool enabled, String syncUrl})> loadSelfHost();
  Future<String?> loadSelfHostToken();
  Future<AuthSession?> loadAuthSession();
  Future<void> saveAuthSession(AuthSession session);
  Future<void> clearAuthSession();
}

/// What the rest of the boot needs from the auth phase.
class AuthBoot {
  const AuthBoot({
    required this.auth,
    required this.accountClient,
    required this.authConfig,
    required this.syncServerUrl,
    required this.selfHostActive,
    required this.selfHostEnabled,
    required this.selfHostUrl,
    required this.cachedPlan,
    required this.registryConnection,
  });

  /// The ONE session-binding instance. Read back through `auth.*` everywhere
  /// and never copied into a local, or a later sign-in updates one copy while
  /// the rest of the plugin goes on acting signed out.
  final AuthSessionState auth;

  /// Kept even on self-host, where it is never signed in: the settings tab
  /// offers sign-in from either edition.
  final RpcAccountClient accountClient;

  final AuthConfig authConfig;

  /// Self-host overrides the compile-time managed sync URL.
  final String syncServerUrl;

  /// Whether self-host is USABLE: switched on, with a URL and a token.
  final bool selfHostActive;

  /// Whether the user switched self-host on, regardless of whether it works.
  ///
  /// Held apart from [selfHostActive] because a half-configured self-host must
  /// not silently fall back to managed — the two together are what lets the
  /// panel say "self-host is on but has no URL" rather than "signed out".
  final bool selfHostEnabled;

  /// The configured self-host URL, whether or not it is usable. Shown in the
  /// settings row and the backend label.
  final String selfHostUrl;

  /// The plan the previous load ended on. The caller seeds its tracker with
  /// this before anything reads a plan: the per-file size gate and the
  /// plugin-code storage gate both run during boot and would otherwise spend
  /// the whole session on "no answer" whenever the lookup is slow.
  final PlanSnapshot? cachedPlan;

  /// Self-host only: the socket the vault registry was reached over, for the
  /// caller to take ownership of. Null on managed, and null when the connect
  /// failed.
  final SyncConnection? registryConnection;
}

/// Resolves the edition, restores the stored session, and binds both to a
/// single [AuthSessionState].
///
/// Every step here is bounded. `onLoad` is awaited by Obsidian, so a hang costs
/// the user their settings tab, their commands and their side panel — the
/// panel view is claimed before this runs precisely because this can be slow.
///
/// Nothing here decides UI. It returns what it found; announcing a lapsed plan
/// or a failed registry connect is the caller's business, which is what keeps
/// this callable from a test.
Future<AuthBoot> bootstrapAuth({
  required AuthBootStorage storage,
  required String accountServiceUrl,
  required String managedSyncUrl,
  required LogScope log,
  required LogScope registryLog,
  IRpcTransport Function(String baseUrl)? accountTransport,
  RpcAccountClient Function(RpcCallerEndpoint endpoint)? accountClientFactory,
  SyncConnection Function({
    required String serverUrl,
    required ITokenProvider tokenProvider,
  })?
  registryConnectionFactory,
  Duration refreshTimeout = const Duration(seconds: 8),
  Duration registryConnectTimeout = const Duration(seconds: 10),
}) async {
  final cachedPlan = await storage.loadPlan();

  // Self-host mode: point the plugin at a self-hosted sync server with a static
  // bearer token, bypassing the managed account service entirely. All three
  // conditions, because a half-configured self-host that silently fell back to
  // managed would sync the vault to the wrong place.
  final selfHost = await storage.loadSelfHost();
  final selfHostToken = selfHost.enabled
      ? (await storage.loadSelfHostToken() ?? '')
      : '';
  final selfHostActive =
      selfHost.enabled &&
      selfHost.syncUrl.isNotEmpty &&
      selfHostToken.isNotEmpty;

  final syncServerUrl = selfHostActive ? selfHost.syncUrl : managedSyncUrl;
  final auth = AuthSessionState(selfHost: selfHostActive);

  // The account service URL comes from compile-time dart-define only.
  final authConfig = AuthConfig(accountServiceUrl: accountServiceUrl);
  final transport =
      accountTransport?.call(authConfig.accountServiceUrl) ??
      RpcHttpCallerTransport(baseUrl: authConfig.accountServiceUrl);
  final endpoint = RpcCallerEndpoint(transport: transport);
  final accountClient =
      accountClientFactory?.call(endpoint) ?? RpcAccountClient(endpoint);
  // Persist every server-issued session — sign-in and every background refresh.
  // The server rotates the refresh token on each refresh, so without this the
  // stored token goes stale within ~15 min and the next cold start is forced to
  // re-login with a revoked one.
  accountClient.onSessionPersist = storage.saveAuthSession;

  final restoredClient = selfHostActive || !authConfig.isConfigured
      ? null
      : await _restoreSession(
          storage: storage,
          accountClient: accountClient,
          log: log,
          refreshTimeout: refreshTimeout,
        );

  if (!selfHostActive) {
    auth.bindAccount(restoredClient);
    return AuthBoot(
      auth: auth,
      accountClient: accountClient,
      authConfig: authConfig,
      syncServerUrl: syncServerUrl,
      selfHostActive: false,
      selfHostEnabled: selfHost.enabled,
      selfHostUrl: selfHost.syncUrl,
      cachedPlan: cachedPlan,
      registryConnection: null,
    );
  }

  auth.bindSelfHostToken(selfHostToken);
  final registry =
      registryConnectionFactory?.call(
        serverUrl: syncServerUrl,
        tokenProvider: auth.tokenProvider,
      ) ??
      WebSocketSyncConnection(
        serverUrl: syncServerUrl,
        tokenProvider: auth.tokenProvider,
        logger: registryLog,
      );
  try {
    // Bounded: a stalled connect here would hold the whole plugin load open,
    // and the settings page would come up blank.
    await registry.connect().timeout(registryConnectTimeout);
    final caller = VaultRegistryContractCaller(registry.endpoint);
    auth.bindSelfHostRegistry(
      directory: SelfHostVaultDirectory(caller),
      metaStorage: SelfHostVaultMetaStorage(caller),
    );
  } catch (e) {
    // Not fatal: the token still authenticates sync itself. What is lost is the
    // vault directory, so the picker comes up empty until the next start.
    log.warning('Self-host registry connect failed: $e');
  }

  return AuthBoot(
    auth: auth,
    accountClient: accountClient,
    authConfig: authConfig,
    syncServerUrl: syncServerUrl,
    selfHostActive: true,
    selfHostEnabled: selfHost.enabled,
    selfHostUrl: selfHost.syncUrl,
    cachedPlan: cachedPlan,
    registryConnection: registry,
  );
}

/// Brings back the stored session, or decides it cannot be trusted.
///
/// Returns the client to bind, or null when there is nothing to bind. Only a
/// refusal the server actually issued discards a session — see
/// [classifyRefreshFailure]; every other outcome keeps it, because a timeout is
/// not a verdict and a forced logout is the worst possible response to a
/// flaky network.
Future<RpcAccountClient?> _restoreSession({
  required AuthBootStorage storage,
  required RpcAccountClient accountClient,
  required LogScope log,
  required Duration refreshTimeout,
}) async {
  final saved = await storage.loadAuthSession();
  if (saved == null) return null;

  accountClient.useSession(saved);
  // Access tokens live 15 minutes, so an expired one is the normal cold-start
  // path rather than a problem.
  if (!saved.isExpired) return accountClient;

  try {
    // Bounded: onLoad must never hang on the network.
    await accountClient.refreshSession().timeout(refreshTimeout);
    final fresh = accountClient.session;
    if (fresh != null) await storage.saveAuthSession(fresh);
    return accountClient;
  } catch (e) {
    if (classifyRefreshFailure(e) == RefreshOutcome.refused) {
      log.warning('Stored session refused by the server — cleared: $e');
      await storage.clearAuthSession();
      return null;
    }
    // Offline at boot, or an answer we never got. Keep the session: the
    // provider refreshes again on first use, and on a timeout the very same
    // refresh is still in flight — `ensureValidToken` joins it rather than
    // starting a second one against a single-use token.
    //
    // Deliberately NOT re-applying `saved` here. It was applied above, before
    // the attempt, so the only thing a second `useSession` can do is overwrite
    // a NEWER session the in-flight refresh has meanwhile stored — leaving the
    // client holding a refresh token the server has already revoked, i.e. a
    // forced logout on the next call.
    log.warning('Boot refresh inconclusive — keeping the stored session: $e');
    return accountClient;
  }
}
