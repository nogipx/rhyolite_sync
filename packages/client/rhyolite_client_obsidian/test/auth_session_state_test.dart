import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:rhyolite_client_obsidian/src/engine/auth_session_state.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Regression cover for the "signed in but still told the session expired"
// loop. Two structural faults produced it:
//
//   * the account client travelled BY VALUE into the settings registrar, so a
//     browser sign-in updated one copy while every other consumer kept
//     reading its own null and behaved as if signed out — clearing the
//     session that had just been stored;
//   * the bearer provider was REPLACED per sign-in, but a live connection
//     holds the provider it was opened with, so the socket kept sending
//     unauthenticated calls.
//
// AuthSessionState answers both: one shared object, one provider mutated in
// place. These tests fail if either property is lost.
// ---------------------------------------------------------------------------

/// A client on a transport with no peer — nothing here makes a call.
RpcAccountClient _client() => RpcAccountClient(
  RpcCallerEndpoint(transport: RpcInMemoryTransport.pair().$1),
);

void main() {
  group('managed edition', () {
    test(
      'signed out: no session, and the token provider fails locally',
      () async {
        final auth = AuthSessionState(selfHost: false);

        expect(auth.client, isNull);
        expect(auth.directory, isNull);
        expect(auth.metaStorage, isNull);
        expect(auth.hasToken, isFalse);
        await expectLater(
          auth.tokenProvider.getToken(),
          throwsA(isA<MissingAuthTokenException>()),
          reason:
              'without a session the call must fail here, not reach the '
              'server with no Authorization header',
        );
      },
    );

    test('sign-in binds token, directory and meta store together', () {
      final auth = AuthSessionState(selfHost: false);

      auth.bindAccount(_client());

      expect(auth.hasToken, isTrue);
      expect(auth.directory, isNotNull, reason: 'vault picker must work');
      expect(
        auth.metaStorage,
        isNotNull,
        reason: 'external-blob config must be readable after re-auth',
      );
    });

    test('sign-in keeps the SAME provider instance — connections opened '
        'before it authenticate on their next call', () async {
      final auth = AuthSessionState(selfHost: false);
      // Stand-in for a connection that captured the provider at connect time.
      final ITokenProvider captured = auth.tokenProvider;

      auth.bindAccount(_client());

      expect(
        identical(captured, auth.tokenProvider),
        isTrue,
        reason:
            'replacing the provider on sign-in is exactly what left the '
            'live socket unauthenticated',
      );
      expect(auth.hasToken, isTrue);
    });

    test('sign-out unbinds without swapping the provider', () async {
      final auth = AuthSessionState(selfHost: false);
      final ITokenProvider captured = auth.tokenProvider;
      auth.bindAccount(_client());

      auth.bindAccount(null);

      expect(auth.client, isNull);
      expect(auth.directory, isNull);
      expect(auth.metaStorage, isNull);
      expect(auth.hasToken, isFalse);
      expect(identical(captured, auth.tokenProvider), isTrue);
    });

    test('a sign-in performed through a callback is visible to every other '
        'holder of the state', () {
      final auth = AuthSessionState(selfHost: false);
      final client = _client();
      // The settings tab only ever gets a reference — the pass-by-value
      // parameter it used to get is what made this update invisible to the
      // auth-recovery listener.
      void settingsSignIn(AuthSessionState shared) =>
          shared.bindAccount(client);

      settingsSignIn(auth);

      expect(auth.client, same(client));
      expect(auth.hasToken, isTrue);
    });
  });

  group('self-host edition', () {
    test('the shared-secret token binds at boot', () async {
      final auth = AuthSessionState(selfHost: true);

      auth.bindSelfHostToken('shared-secret');

      expect(auth.hasToken, isTrue);
      expect(await auth.tokenProvider.getToken(), 'shared-secret');
    });

    test('managed sign-out cannot strip the self-host token', () async {
      final auth = AuthSessionState(selfHost: true);
      auth.bindSelfHostToken('shared-secret');

      // A managed-path call reaching self-host by mistake must be inert:
      // there is no account session to drop, and dropping the static token
      // would take the whole edition offline.
      auth.bindAccount(null);

      expect(auth.hasToken, isTrue);
      expect(await auth.tokenProvider.getToken(), 'shared-secret');
    });
  });
}
