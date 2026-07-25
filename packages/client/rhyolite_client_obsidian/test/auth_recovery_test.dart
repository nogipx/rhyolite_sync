import 'package:rhyolite_client_obsidian/src/engine/auth_recovery.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The decision table behind "I signed in again and it immediately told me the
// session had expired". The handler used to treat every auth rejection as
// proof the session was dead: it cleared the stored session — including one a
// browser sign-in had written seconds earlier — dropped the token provider,
// and prompted for sign-in again. The next call then failed the same way.
// ---------------------------------------------------------------------------
void main() {
  group('planAuthRecovery', () {
    test('fresh sign-in racing a rejection from the old connection rebinds, '
        'it does not treat the new session as expired', () {
      // Exactly the reported state: the user just signed in (live session),
      // the still-open socket carries no token, so the server answers
      // `missing or invalid Authorization header`.
      final plan = planAuthRecovery(
        tokenMissing: true,
        sessionLive: true,
        sessionPresent: true,
        providerBound: true,
        rebindBudgetLeft: true,
      );

      expect(plan, AuthRecovery.rebind);
    });

    test('an unbound provider with a good session rebinds', () {
      expect(
        planAuthRecovery(
          tokenMissing: false,
          sessionLive: true,
          sessionPresent: true,
          providerBound: false,
          rebindBudgetLeft: true,
        ),
        AuthRecovery.rebind,
      );
    });

    test('a token the server refused, while bound, goes to refresh — not to '
        'an endless rebind', () {
      expect(
        planAuthRecovery(
          tokenMissing: false,
          sessionLive: true,
          sessionPresent: true,
          providerBound: true,
          rebindBudgetLeft: true,
        ),
        AuthRecovery.refresh,
      );
    });

    test('an exhausted rebind budget stops the restart loop and falls '
        'through to refresh', () {
      expect(
        planAuthRecovery(
          tokenMissing: true,
          sessionLive: true,
          sessionPresent: true,
          providerBound: false,
          rebindBudgetLeft: false,
        ),
        AuthRecovery.refresh,
      );
    });

    test('an expired session refreshes', () {
      expect(
        planAuthRecovery(
          tokenMissing: false,
          sessionLive: false,
          sessionPresent: true,
          providerBound: true,
          rebindBudgetLeft: true,
        ),
        AuthRecovery.refresh,
      );
    });

    test('no session at all prompts', () {
      expect(
        planAuthRecovery(
          tokenMissing: true,
          sessionLive: false,
          sessionPresent: false,
          providerBound: false,
          rebindBudgetLeft: true,
        ),
        AuthRecovery.prompt,
      );
    });
  });

  group('shouldClearStoredSession', () {
    test('token_missing alone never discards the stored session', () {
      expect(
        shouldClearStoredSession(tokenMissing: true, refreshRefused: false),
        isFalse,
        reason:
            'this is the deletion that wiped a just-obtained session and '
            'made the expiry loop self-sustaining',
      );
    });

    test('a refused refresh discards it, even when the trigger was '
        'token_missing', () {
      expect(
        shouldClearStoredSession(tokenMissing: true, refreshRefused: true),
        isTrue,
      );
    });

    test('a token the server refused discards it', () {
      expect(
        shouldClearStoredSession(tokenMissing: false, refreshRefused: false),
        isTrue,
      );
    });
  });
}
