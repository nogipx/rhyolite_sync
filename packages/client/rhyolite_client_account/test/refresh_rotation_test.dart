import 'dart:async';

import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Refresh tokens are single-use: the server revokes the presented token
// BEFORE it answers. Everything here defends the consequences of that.
//
// The incident: a refresh reached the server, which rotated the token and
// minted a new session — and the answer never arrived. The client retried
// with the same, now-revoked token, got `unauthenticated`, reported it as a
// dead session, and the host deleted a login that was alive on the server.
// The freshly minted refresh token sat in the database, valid and unused,
// while the user was told the session had expired.
// ---------------------------------------------------------------------------

/// Drives [refresh] from a script; every other method is unreachable here.
class _ScriptedAuthResponder extends AuthContractResponder {
  _ScriptedAuthResponder(this.script);

  /// One entry per call: either the session to return or the error to throw.
  final List<Object> script;

  /// Refresh tokens the server actually saw, in order.
  final presented = <String>[];

  @override
  void setup() {
    addUnaryMethod<RefreshRequest, AuthSession>(
      methodName: AuthContractNames.refresh,
      handler: refresh,
      requestCodec: AuthContractCodecs.codecRefreshRequest,
      responseCodec: AuthContractCodecs.codecAuthSession,
    );
  }

  @override
  Future<AuthSession> refresh(
    RefreshRequest request, {
    RpcContext? context,
  }) async {
    presented.add(request.refreshToken);
    final step = script[presented.length - 1];
    if (step is AuthSession) return step;
    throw step;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

AuthSession _session(String suffix, {required bool expired}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return AuthSession(
    accessToken: 'access-$suffix',
    refreshToken: 'refresh-$suffix',
    expiresAt: expired ? now - 60 : now + 3600,
    userId: 'user-1',
    email: 'user@example.com',
  );
}

/// Wires a client to a scripted server over an in-memory transport pair, so
/// the errors under test travel the real RPC error path.
(RpcAccountClient, _ScriptedAuthResponder) _connect(List<Object> script) {
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
  final responder = _ScriptedAuthResponder(script);
  RpcResponderEndpoint(transport: serverTransport)
    ..registerServiceContract(responder)
    ..start();
  final client = RpcAccountClient(
    RpcCallerEndpoint(transport: clientTransport),
    // Production waits 30s between `unauthenticated` attempts to outwait a
    // rotation race; the classification under test is the same either way.
    unauthRetryDelay: const Duration(milliseconds: 1),
  );
  return (client, responder);
}

void main() {
  group('refresh failure classification', () {
    test('a refusal the server issued for a token we never spent is '
        'refused — the one case that may clear the session', () async {
      // Two refusals: the retry budget for a false-positive rotation race is
      // exhausted, and nothing before them could have burned the token.
      final (client, responder) = _connect([
        RpcException('unauthenticated: invalid refresh token'),
        RpcException('unauthenticated: invalid refresh token'),
      ]);
      client.useSession(_session('a', expired: true));

      await expectLater(
        client.refreshSession(),
        throwsA(
          isA<RefreshFailedException>()
              .having((e) => e.kind, 'kind', RefreshFailureKind.refused)
              .having((e) => e.sessionIsDead, 'sessionIsDead', isTrue),
        ),
      );
      expect(responder.presented, hasLength(2));
    });

    test('a refusal that follows an unanswered attempt is ambiguous — the '
        'server may have rotated the token away on the lost call', () async {
      final (client, responder) = _connect([
        RpcException('internal: upstream reset'),
        RpcException('unauthenticated: invalid refresh token'),
      ]);
      client.useSession(_session('a', expired: true));

      await expectLater(
        client.refreshSession(),
        throwsA(
          isA<RefreshFailedException>()
              .having((e) => e.kind, 'kind', RefreshFailureKind.ambiguous)
              .having((e) => e.sessionIsDead, 'sessionIsDead', isFalse),
        ),
      );
      expect(
        responder.presented,
        ['refresh-a', 'refresh-a'],
        reason: 'the retry necessarily reuses the single-use token — which '
            'is why its refusal proves nothing',
      );
    });

    test('network failures throughout are transient, never a dead session',
        () async {
      final (client, _) = _connect([
        RpcException('unavailable: connection closed'),
        RpcException('unavailable: connection closed'),
        RpcException('unavailable: connection closed'),
      ]);
      client.useSession(_session('a', expired: true));

      await expectLater(
        client.refreshSession(),
        throwsA(
          isA<RefreshFailedException>()
              .having((e) => e.kind, 'kind', RefreshFailureKind.transient)
              .having((e) => e.sessionIsDead, 'sessionIsDead', isFalse),
        ),
      );
    });

    test('a transient failure that then succeeds keeps the session', () async {
      final fresh = _session('b', expired: false);
      final (client, responder) = _connect([
        RpcException('unavailable: connection closed'),
        fresh,
      ]);
      client.useSession(_session('a', expired: true));

      final result = await client.refreshSession();

      expect(result.refreshToken, 'refresh-b');
      expect(client.session?.refreshToken, 'refresh-b');
      expect(responder.presented, hasLength(2));
    });
  });

  group('concurrent refreshes', () {
    test('share one in-flight attempt instead of racing on the same '
        'single-use token', () async {
      final (client, responder) = _connect([
        _session('b', expired: false),
        RpcException('unauthenticated: token revoked'),
      ]);
      client.useSession(_session('a', expired: true));

      // ensureValidToken (the bearer provider, on every RPC) and
      // refreshSession (the host's auth-recovery handler) firing together is
      // exactly the collision that revoked a live session.
      final results = await Future.wait([
        client.ensureValidToken(),
        client.refreshSession().then((s) => s.accessToken),
        client.ensureValidToken(),
      ]);

      expect(
        responder.presented,
        ['refresh-a'],
        reason: 'a second call would present a token the server just revoked',
      );
      expect(results, everyElement('access-b'));
    });

    test('a failed shared refresh reports to every joined caller', () async {
      final (client, responder) = _connect([
        RpcException('unauthenticated: invalid refresh token'),
        RpcException('unauthenticated: invalid refresh token'),
      ]);
      client.useSession(_session('a', expired: true));

      final first = client.refreshSession();
      final second = client.refreshSession();

      await expectLater(first, throwsA(isA<RefreshFailedException>()));
      await expectLater(second, throwsA(isA<RefreshFailedException>()));
      expect(responder.presented, hasLength(2), reason: 'one retry sequence');
    });

    test('a later refresh starts a new attempt once the first settled',
        () async {
      final (client, responder) = _connect([
        _session('b', expired: false),
        _session('c', expired: false),
      ]);
      client.useSession(_session('a', expired: true));

      await client.refreshSession();
      await client.refreshSession();

      expect(responder.presented, ['refresh-a', 'refresh-b']);
    });
  });

  test('no session at all fails locally, without a call', () async {
    final (client, responder) = _connect([]);

    await expectLater(client.refreshSession(), throwsA(isA<StateError>()));
    expect(responder.presented, isEmpty);
  });

  // A refused refresh is the only proof a session is dead, and it surfaces to
  // callers as whatever operation happened to need a token — each of which
  // logs its own failure and carries on. Without this notification nothing
  // concluded "signed out": the host kept retrying an account it could never
  // authenticate with, and told the user nothing.
  group('onSessionRefused', () {
    test('fires once, only for a refusal, and never for an ambiguous or '
        'transient failure', () async {
      for (final scripted in [
        (
          name: 'ambiguous',
          script: <Object>[
            RpcException('internal: upstream reset'),
            RpcException('unauthenticated: invalid refresh token'),
          ],
        ),
        (
          name: 'transient',
          script: <Object>[
            RpcException('unavailable: connection closed'),
            RpcException('unavailable: connection closed'),
            RpcException('unavailable: connection closed'),
          ],
        ),
      ]) {
        final (client, _) = _connect(scripted.script);
        client.useSession(_session('a', expired: true));
        var fired = 0;
        client.onSessionRefused = (_) => fired++;

        await expectLater(client.refreshSession(), throwsA(isA<Object>()));
        expect(fired, 0, reason: '${scripted.name} is not evidence');
      }

      final (client, _) = _connect([
        RpcException('unauthenticated: invalid refresh token'),
        RpcException('unauthenticated: invalid refresh token'),
      ]);
      client.useSession(_session('a', expired: true));
      final reasons = <RefreshFailedException>[];
      client.onSessionRefused = reasons.add;

      await expectLater(
        client.refreshSession(),
        throwsA(isA<RefreshFailedException>()),
      );
      expect(reasons, hasLength(1));
      expect(reasons.single.sessionIsDead, isTrue);
    });

    test('a burst of callers produces one notification, and every caller '
        'still gets the error', () async {
      final (client, responder) = _connect([
        RpcException('unauthenticated: invalid refresh token'),
        RpcException('unauthenticated: invalid refresh token'),
      ]);
      client.useSession(_session('a', expired: true));
      var fired = 0;
      client.onSessionRefused = (_) => fired++;

      // ensureValidToken joins the in-flight refresh rather than starting a
      // second one against a single-use token.
      final calls = [
        client.refreshSession(),
        client.ensureValidToken(),
        client.ensureValidToken(),
      ];
      for (final c in calls) {
        await expectLater(c, throwsA(isA<RefreshFailedException>()));
      }

      expect(fired, 1);
      expect(responder.presented, hasLength(2), reason: 'one retry sequence');
    });

    test('a throwing handler does not replace the error the caller awaits',
        () async {
      final (client, _) = _connect([
        RpcException('unauthenticated: invalid refresh token'),
        RpcException('unauthenticated: invalid refresh token'),
      ]);
      client.useSession(_session('a', expired: true));
      client.onSessionRefused = (_) => throw StateError('host blew up');

      await expectLater(
        client.refreshSession(),
        throwsA(
          isA<RefreshFailedException>()
              .having((e) => e.sessionIsDead, 'sessionIsDead', isTrue),
        ),
      );
    });
  });
}
