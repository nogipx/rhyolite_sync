@TestOn('vm')
library;

import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:rhyolite_client_obsidian/src/engine/boot/auth_boot.dart';
import 'package:rhyolite_client_obsidian/src/engine/plan_status.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The first phase of the boot, run outside Obsidian.
//
// This is what the refactor was for. Every rule below was reachable only by
// launching the plugin and arranging the right `data.json` — which is why the
// two that went wrong went wrong in the field: a rotated refresh token that was
// never persisted (frequent re-login), and a stored session discarded on a
// timeout rather than on a refusal (a surprise logout for anyone who opened
// Obsidian offline).
//
// The phase takes an AuthBootStorage and two factories, so none of this needs a
// network, a plugin handle or a real account service.
// ---------------------------------------------------------------------------

final _log = LogController(outputs: []).scope('test');

AuthSession _session({required bool expired}) => AuthSession(
  accessToken: 'access',
  refreshToken: 'refresh',
  expiresAt:
      DateTime.now()
          .add(
            expired ? const Duration(hours: -1) : const Duration(minutes: 14),
          )
          .millisecondsSinceEpoch ~/
      1000,
  userId: 'user-1',
  email: 'user@example.test',
);

Future<AuthBoot> _boot(
  _FakeStorage storage, {
  String accountServiceUrl = 'https://account.example',
  SyncConnection Function({
    required String serverUrl,
    required ITokenProvider tokenProvider,
  })?
  registry,
  RpcAccountClient Function(RpcCallerEndpoint)? client,
}) => bootstrapAuth(
  storage: storage,
  accountServiceUrl: accountServiceUrl,
  managedSyncUrl: 'wss://managed.example',
  log: _log,
  registryLog: _log,
  // Never dialled: the managed path below either has no session to refresh or
  // is handed a client that answers from memory.
  accountTransport: (_) => _DeadTransport(),
  accountClientFactory: client,
  registryConnectionFactory: registry,
  // Short enough that the hanging-refresh case does not stall the suite.
  refreshTimeout: const Duration(milliseconds: 50),
);

void main() {
  group('edition', () {
    test('needs all three parts before self-host is active', () async {
      for (final (enabled, url, token) in [
        (false, 'wss://self.example', 'tok'),
        (true, '', 'tok'),
        (true, 'wss://self.example', ''),
      ]) {
        final boot = await _boot(
          _FakeStorage(
            selfHostEnabled: enabled,
            selfHostUrl: url,
            selfHostToken: token.isEmpty ? null : token,
          ),
        );
        expect(
          boot.selfHostActive,
          isFalse,
          reason:
              'a half-configured self-host that silently fell back to managed '
              'would sync the vault to the wrong server',
        );
        expect(
          boot.syncServerUrl,
          'wss://managed.example',
          reason: 'and it must not be pointed at the half-configured URL',
        );
      }
    });

    test(
      'self-host takes the URL and never touches the account service',
      () async {
        final storage = _FakeStorage(
          selfHostEnabled: true,
          selfHostUrl: 'wss://self.example',
          selfHostToken: 'tok',
          // Present, and must be ignored: this vault is not managed.
          authSession: _session(expired: true),
        );
        final boot = await _boot(
          storage,
          registry: ({required serverUrl, required tokenProvider}) =>
              _FakeConnection(),
        );

        expect(boot.selfHostActive, isTrue);
        expect(boot.syncServerUrl, 'wss://self.example');
        expect(boot.registryConnection, isNotNull);
        expect(
          storage.authSessionReads,
          0,
          reason: 'self-host has no account, so there is no session to restore',
        );
      },
    );

    test('a failed registry connect is not a failed boot', () async {
      final boot = await _boot(
        _FakeStorage(
          selfHostEnabled: true,
          selfHostUrl: 'wss://self.example',
          selfHostToken: 'tok',
        ),
        registry: ({required serverUrl, required tokenProvider}) =>
            _FakeConnection(failConnect: true),
      );

      expect(boot.selfHostActive, isTrue);
      expect(
        boot.registryConnection,
        isNotNull,
        reason:
            'the caller has to own it either way — a half-opened socket still '
            'needs closing at unload',
      );
      expect(
        boot.auth.hasToken,
        isTrue,
        reason:
            'the token still authenticates sync itself; what is lost is the '
            'vault directory',
      );
    });
  });

  group('stored session', () {
    test('a live one is bound as it is', () async {
      final storage = _FakeStorage(authSession: _session(expired: false));
      final boot = await _boot(storage);

      expect(boot.auth.client, isNotNull);
      expect(
        storage.saves,
        0,
        reason: 'nothing was refreshed, so nothing needed writing',
      );
    });

    test('nothing stored binds nothing', () async {
      final boot = await _boot(_FakeStorage());
      expect(boot.auth.client, isNull);
    });

    test('a rotated refresh token is written down', () async {
      // The server rotates the refresh token on every refresh. Without this
      // write the stored one goes stale within ~15 minutes and the next cold
      // start is forced to re-login with a token the server has revoked —
      // which is what "it keeps logging me out" turned out to be.
      final rotated = _session(expired: false);
      final storage = _FakeStorage(authSession: _session(expired: true));
      final boot = await _boot(
        storage,
        client: (e) => _FakeAccountClient(e, refreshTo: rotated),
      );

      expect(boot.auth.client, isNotNull, reason: 'the refresh succeeded');
      expect(storage.saves, 1);
      expect(storage.savedSessions.single.accessToken, rotated.accessToken);
    });

    test('only a refusal the server issued discards the session', () async {
      final storage = _FakeStorage(authSession: _session(expired: true));
      final boot = await _boot(
        storage,
        client: (e) => _FakeAccountClient(
          e,
          // The one shape that counts as evidence: the server refused a
          // token no earlier attempt in this sequence could have spent.
          refreshError: const RefreshFailedException(
            RefreshFailureKind.refused,
            'unauthenticated: bad refresh token',
          ),
        ),
      );

      expect(storage.clears, 1);
      expect(boot.auth.client, isNull);
    });

    test('a timeout is not a verdict, and the session is kept', () async {
      // Opening Obsidian offline used to log people out. A timeout says
      // nothing about whether the token is good, and the provider refreshes
      // again on first use — on a timeout the very same refresh is still in
      // flight, and ensureValidToken joins it rather than starting a second
      // one against a single-use token.
      final storage = _FakeStorage(authSession: _session(expired: true));
      final boot = await _boot(
        storage,
        client: (e) => _FakeAccountClient(e, refreshHangs: true),
      );

      expect(storage.clears, 0, reason: 'a surprise logout for being offline');
      expect(boot.auth.client, isNotNull);
    });

    test('an unconfigured account service is not consulted', () async {
      final storage = _FakeStorage(authSession: _session(expired: false));
      final boot = await _boot(storage, accountServiceUrl: '');

      expect(boot.authConfig.isConfigured, isFalse);
      expect(boot.auth.client, isNull);
      expect(storage.authSessionReads, 0);
    });
  });
}

class _FakeStorage implements AuthBootStorage {
  _FakeStorage({
    this.selfHostEnabled = false,
    this.selfHostUrl = '',
    this.selfHostToken,
    this.authSession,
  });

  final bool selfHostEnabled;
  final String selfHostUrl;
  final String? selfHostToken;
  final AuthSession? authSession;

  int authSessionReads = 0;
  int clears = 0;
  final savedSessions = <AuthSession>[];
  int get saves => savedSessions.length;

  @override
  Future<PlanSnapshot?> loadPlan() async => null;

  @override
  Future<({bool enabled, String syncUrl})> loadSelfHost() async =>
      (enabled: selfHostEnabled, syncUrl: selfHostUrl);

  @override
  Future<String?> loadSelfHostToken() async => selfHostToken;

  @override
  Future<AuthSession?> loadAuthSession() async {
    authSessionReads++;
    return authSession;
  }

  @override
  Future<void> saveAuthSession(AuthSession session) async {
    savedSessions.add(session);
  }

  @override
  Future<void> clearAuthSession() async {
    clears++;
  }
}

/// Answers nothing. Every managed case here either has no session to refresh or
/// never gets as far as a call, so a transport that is used at all is a bug in
/// the test rather than a case to support.
///
/// [incomingMessages] is the exception, and it is not a call. Since rpc_dart
/// 5.0.0 `RpcCallerEndpoint` starts listening in its constructor, so merely
/// building one reaches this — and an empty stream is the honest answer for a
/// transport nobody will ever write to. Leaving it to [noSuchMethod] would make
/// the double refuse construction itself, which is not what it exists to catch.
class _DeadTransport implements IRpcTransport {
  @override
  Stream<RpcTransportMessage> get incomingMessages => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('the boot phase must not dial out here');
}

/// An account client that answers from memory. Subclassed rather than
/// reimplemented: the phase only ever calls these four members, and inheriting
/// the rest means a phase that grows a fifth call fails here loudly instead of
/// silently taking the real one.
class _FakeAccountClient extends RpcAccountClient {
  _FakeAccountClient(
    super.endpoint, {
    this.refreshTo,
    this.refreshError,
    this.refreshHangs = false,
  });

  final AuthSession? refreshTo;
  final Object? refreshError;
  final bool refreshHangs;

  AuthSession? _held;

  @override
  AuthSession? get session => _held;

  @override
  void useSession(AuthSession saved) => _held = saved;

  @override
  Future<AuthSession> refreshSession() async {
    if (refreshHangs) {
      // What a real timeout looks like from here: the caller's own .timeout
      // fires first.
      await Future<void>.delayed(const Duration(seconds: 30));
    }
    if (refreshError != null) throw refreshError!;
    final next = refreshTo;
    if (next == null) throw StateError('no refresh configured');
    _held = next;
    return next;
  }
}

class _FakeConnection implements SyncConnection {
  _FakeConnection({this.failConnect = false});

  final bool failConnect;

  @override
  Future<void> connect() async {
    if (failConnect) throw StateError('no route to host');
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not used at boot');
}
