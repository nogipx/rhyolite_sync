import 'package:rhyolite_client_obsidian/src/engine/server_rejections.dart';
import 'package:test/test.dart';

void main() {
  // The plugin's recovery handler branches on these types. `token_missing`
  // must arrive as its own type: on that code the handler rebinds and
  // restarts, while on `session_expired` it may clear the stored session —
  // and clearing on the wrong one is what deleted a just-obtained session.
  test('token_missing maps to its own type, distinct from SessionExpired', () {
    final r = pluginRejectionFactory(
      'auth.token_missing',
      'no token',
      const {},
    );

    expect(r, isA<AuthTokenMissing>());
    expect(r, isNot(isA<SessionExpired>()));
    expect(r!.code, 'auth.token_missing');
  });

  test('session_expired still maps to SessionExpired', () {
    expect(
      pluginRejectionFactory('auth.session_expired', 'dead', const {}),
      isA<SessionExpired>(),
    );
  });

  test('both stay inside the auth.* family the handler funnels on', () {
    for (final code in ['auth.token_missing', 'auth.session_expired']) {
      final r = pluginRejectionFactory(code, 'm', const {});
      expect(r!.code.startsWith('auth.'), isTrue);
    }
  });
}
