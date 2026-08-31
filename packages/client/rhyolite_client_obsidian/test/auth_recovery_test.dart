import 'package:rhyolite_client_account/rhyolite_client_account.dart';
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
        shouldClearStoredSession(
          tokenMissing: true,
          refresh: RefreshOutcome.notAttempted,
        ),
        isFalse,
        reason:
            'this is the deletion that wiped a just-obtained session and '
            'made the expiry loop self-sustaining',
      );
    });

    test('a refused refresh discards it, even when the trigger was '
        'token_missing', () {
      expect(
        shouldClearStoredSession(
          tokenMissing: true,
          refresh: RefreshOutcome.refused,
        ),
        isTrue,
      );
    });

    test('a token the server refused discards it', () {
      expect(
        shouldClearStoredSession(
          tokenMissing: false,
          refresh: RefreshOutcome.notAttempted,
        ),
        isTrue,
      );
    });

    // The logout this whole table exists to prevent: a refresh that failed
    // without an answer says nothing about the session. Refresh tokens are
    // single-use, so a lost response burns the token server-side and the
    // retry comes back `unauthenticated` for a session that is alive.
    test('an inconclusive refresh never discards the session', () {
      expect(
        shouldClearStoredSession(
          tokenMissing: true,
          refresh: RefreshOutcome.inconclusive,
        ),
        isFalse,
      );
      expect(
        shouldClearStoredSession(
          tokenMissing: false,
          refresh: RefreshOutcome.inconclusive,
        ),
        isFalse,
        reason:
            'a refused access token plus an unanswered refresh is still '
            'no evidence the refresh token is dead',
      );
    });
  });

  group('classifyRefreshFailure', () {
    test('only a clean server refusal counts as refused', () {
      expect(
        classifyRefreshFailure(
          const RefreshFailedException(
            RefreshFailureKind.refused,
            'unauthenticated: invalid refresh token',
          ),
        ),
        RefreshOutcome.refused,
      );
    });

    test('a refusal that our own retry may have caused is inconclusive', () {
      expect(
        classifyRefreshFailure(
          const RefreshFailedException(
            RefreshFailureKind.ambiguous,
            'unauthenticated: token revoked',
          ),
        ),
        RefreshOutcome.inconclusive,
      );
    });

    test('network failures and unknown errors are inconclusive', () {
      expect(
        classifyRefreshFailure(
          const RefreshFailedException(
            RefreshFailureKind.transient,
            'connection closed',
          ),
        ),
        RefreshOutcome.inconclusive,
      );
      expect(
        classifyRefreshFailure(StateError('Not signed in')),
        RefreshOutcome.inconclusive,
      );
    });
  });

  group('rejectionWarrantsRefresh', () {
    test('an expired or missing token is worth a refresh', () {
      expect(rejectionWarrantsRefresh('auth.session_expired'), isTrue);
      expect(rejectionWarrantsRefresh('auth.token_missing'), isTrue);
    });

    test('not owning the vault is not', () {
      // Authorization, not authentication: a fresh token carries the same
      // permissions as the one that was refused. Refreshing restarts the
      // engine, fails identically and restarts again — a user's first sync
      // spent minutes in exactly that loop.
      expect(rejectionWarrantsRefresh('auth.permission_denied'), isFalse);
    });

    test('a policy refusal is not, whatever it says', () {
      expect(rejectionWarrantsRefresh('app_policy.quota.storage'), isFalse);
      expect(rejectionWarrantsRefresh('app_policy.subscription_required'),
          isFalse);
    });
  });
}
