import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// A connection installs its bearer interceptor once, at connect time, and
// holds that provider for the life of the socket. Everything here exists so
// a session change does not require replacing the object the socket holds —
// and so a *missing* session fails loudly on our side instead of quietly
// producing a request with no Authorization header (which comes back as a
// generic `unauthenticated` and reads exactly like a dead session).
// ---------------------------------------------------------------------------
void main() {
  test(
    'unbound provider fails locally instead of yielding an empty token',
    () async {
      final provider = MutableTokenProvider();

      expect(provider.isBound, isFalse);
      await expectLater(
        provider.getToken(),
        throwsA(isA<MissingAuthTokenException>()),
      );
    },
  );

  test('a delegate bound after the provider was handed out is visible '
      'through the original reference', () async {
    final provider = MutableTokenProvider();
    // Stand-in for the connection: it captured the provider at connect time
    // and never looks it up again.
    final ITokenProvider captured = provider;

    provider.delegate = StaticTokenProvider('signed-in');

    expect(await captured.getToken(), 'signed-in');
  });

  test(
    'rebinding swaps the token; unbinding restores the local failure',
    () async {
      final provider = MutableTokenProvider(StaticTokenProvider('first'));
      expect(await provider.getToken(), 'first');

      provider.delegate = StaticTokenProvider('rotated');
      expect(await provider.getToken(), 'rotated');

      provider.delegate = null;
      expect(provider.isBound, isFalse);
      await expectLater(
        provider.getToken(),
        throwsA(isA<MissingAuthTokenException>()),
      );
    },
  );

  test('the local failure is classified as token_missing, never as an '
      'expired session', () {
    const mapper = ServerRejectionMapper();

    final rejection = mapper.fromException(const MissingAuthTokenException());

    expect(
      rejection?.code,
      'auth.token_missing',
      reason:
          'a host must not discard its stored session because THIS '
          'client failed to attach a token',
    );
  });
}
