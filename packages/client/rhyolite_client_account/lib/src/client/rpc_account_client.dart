import 'dart:async';

import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// RPC-based account client.
///
/// Replaces [SupabaseAuthClient] — talks to account-service via HTTP
/// using [IAuthContract], [IVaultContract], and [ISubscriptionContract].
///
/// Usage:
/// ```dart
/// final transport = RpcHttpCallerTransport(baseUrl: 'http://account:8081');
/// final endpoint = RpcCallerEndpoint(transport);
/// final client = RpcAccountClient(endpoint);
/// ```
class RpcAccountClient {
  RpcAccountClient(
    RpcCallerEndpoint endpoint, {
    Duration unauthRetryDelay = const Duration(seconds: 30),
  }) : _auth = AuthContractCaller(endpoint),
       _vault = VaultContractCaller(endpoint),
       _subscription = SubscriptionContractCaller(endpoint),
       _unauthRetryDelay = unauthRetryDelay;

  final AuthContractCaller _auth;
  final VaultContractCaller _vault;
  final SubscriptionContractCaller _subscription;

  // ---------------------------------------------------------------------------
  // Session state
  // ---------------------------------------------------------------------------

  AuthSession? _session;

  /// In-flight refresh, shared by every concurrent caller — [ensureValidToken]
  /// and [refreshSession] alike. Lifecycle: created at the start of one
  /// refresh, cleared in `finally`. Acts as a per-instance mutex — never a
  /// long-lived timer. Mandatory, not an optimisation: the refresh token is
  /// single-use, so a second concurrent refresh presents a token the server
  /// has already revoked.
  Completer<AuthSession>? _refreshInFlight;

  /// Refresh a few seconds before the server-recorded expiry to absorb
  /// clock skew and request latency. Sized for typical WAN RTT + the
  /// few seconds of skew NTP-synced hosts may still have.
  static const Duration _refreshSafetyMargin = Duration(seconds: 30);

  /// Retry budget for transient (network / 5xx) refresh failures.
  /// `unauthenticated: ...` failures have their own tighter retry
  /// budget below — they're usually real but occasionally false
  /// positives from rotation races, so we give them exactly one
  /// extra chance before surrendering.
  static const int _refreshMaxAttempts = 3;

  /// Number of `unauthenticated` responses to tolerate during refresh
  /// before declaring the session truly dead. One retry covers
  /// transient false-positives (token rotation races, mid-flight
  /// connection drops) without keeping a real expired session alive.
  static const int _maxUnauthRetries = 2;

  /// Pause between successive `unauthenticated` refresh attempts. Long
  /// enough to outwait token rotation races; short enough not to
  /// noticeably delay the genuine "session expired" UI.
  final Duration _unauthRetryDelay;

  /// Invoked whenever the session is replaced by a FRESH one from the server
  /// (sign-up, sign-in, refresh) — not on [useSession] restore. The host wires
  /// this to durable storage.
  ///
  /// Critical for refresh-token rotation: each server-side refresh revokes the
  /// used refresh token and issues a new one. Without persisting here, a
  /// background refresh leaves the on-disk session holding a now-revoked token,
  /// so the next cold start fails with `token revoked` and forces a re-login.
  FutureOr<void> Function(AuthSession session)? onSessionPersist;

  /// Replace the live session with a server-issued one and persist it.
  /// Persistence is best-effort: a failed write leaves the in-memory session
  /// valid, only risking a re-login on the next cold start.
  Future<void> _setSession(AuthSession s) async {
    _session = s;
    try {
      await onSessionPersist?.call(s);
    } catch (_) {}
  }

  AuthSession? get session => _session;
  String? get accessToken => _session?.accessToken;
  String? get email => _session?.email;
  String? get userId => _session?.userId;
  bool get isSignedIn => _session != null && !(_session!.isExpired);

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  Future<AuthSession> signUp(String email, String password) async {
    final session = await _auth.signUp(
      SignUpRequest(email: email, password: password),
    );
    await _setSession(session);
    return session;
  }

  Future<AuthSession> signIn(String email, String password) async {
    final session = await _auth.signIn(
      SignInRequest(email: email, password: password),
    );
    await _setSession(session);
    return session;
  }

  /// Exchange a one-time login code (shown by the bot over the linked
  /// Telegram chat) for a session. The code is our own credential —
  /// Telegram only delivered it; identity is the email account it is
  /// bound to. No password is typed.
  Future<AuthSession> redeemLoginCode(String code) async {
    final session = await _auth.redeemLoginCode(
      RedeemLoginCodeRequest(code: code),
    );
    await _setSession(session);
    return session;
  }

  /// Issues a one-time login code for the current session's user. The
  /// site calls this after browser login, then hands the code to a client
  /// (plugin via obsidian://, bot via t.me) to redeem via
  /// [redeemLoginCode]. Requires an active session.
  Future<String> issueSessionLoginCode() async {
    final res = await _auth.issueSessionLoginCode(
      const IssueSessionLoginCodeRequest(),
      context: await _authContext(),
    );
    return res.code;
  }

  /// Exchange the stored refresh token for a fresh session.
  ///
  /// Shares one in-flight attempt with every concurrent caller. That is not
  /// an optimisation: the token is single-use, so two callers refreshing at
  /// once means one of them presents a token the server has already revoked
  /// and reads the refusal as a dead session. Every path that refreshes —
  /// [ensureValidToken], boot-time restore, the host's auth-recovery
  /// handler — must go through here.
  ///
  /// Throws [RefreshFailedException]; only `kind == refused` means the
  /// session is actually dead.
  Future<AuthSession> refreshSession() {
    if (_session?.refreshToken == null) {
      return Future.error(StateError('Not signed in'), StackTrace.current);
    }
    final pending = _refreshInFlight;
    if (pending != null) return pending.future;
    return _guardedRefresh();
  }

  /// The bare RPC. Never call directly — it takes no mutex and does not
  /// classify failures. [refreshSession] is the entry point.
  Future<AuthSession> _refreshOnce() async {
    final token = _session?.refreshToken;
    if (token == null) throw StateError('Not signed in');
    final session = await _auth.refresh(RefreshRequest(refreshToken: token));
    await _setSession(session);
    return session;
  }

  /// Runs [_refreshWithRetry] as the single in-flight refresh, handing its
  /// result (or failure) to everyone who joined while it ran.
  Future<AuthSession> _guardedRefresh() async {
    final completer = Completer<AuthSession>();
    _refreshInFlight = completer;
    try {
      final fresh = await _refreshWithRetry();
      completer.complete(fresh);
      return fresh;
    } catch (e, st) {
      completer.completeError(e, st);
      // The completer only exists to de-dup concurrent refreshes. With no
      // concurrent waiter its error future has NO listener — mark it handled so
      // the failure doesn't escape as an unhandled async error (which crashes
      // the app's error zone / systemd restart-loops the bot). THIS caller still
      // gets the error via rethrow.
      completer.future.ignore();
      rethrow;
    } finally {
      _refreshInFlight = null;
    }
  }

  /// Returns a valid access token, refreshing it proactively when the
  /// recorded expiry is within [_refreshSafetyMargin]. Concurrent
  /// callers share a single in-flight refresh via [_refreshInFlight]
  /// so refresh-token rotation can't kill all but one of them.
  ///
  /// Transient failures retry with exponential backoff; a refusal the
  /// server issued short-circuits the retry budget so the caller can prompt
  /// for re-login instead of pointlessly retrying. Failures arrive as
  /// [RefreshFailedException] — see [refreshSession].
  Future<String> ensureValidToken() async {
    final s = _session;
    if (s == null) throw StateError('Not signed in');
    if (!_needsRefresh(s)) return s.accessToken;

    final pending = _refreshInFlight;
    if (pending != null) return (await pending.future).accessToken;

    return (await _guardedRefresh()).accessToken;
  }

  bool _needsRefresh(AuthSession s) {
    final at = s.expiresAt;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return nowSec + _refreshSafetyMargin.inSeconds >= at;
  }

  Future<AuthSession> _refreshWithRetry() async {
    Object? lastError;
    StackTrace? lastStack;
    var unauthAttempts = 0;
    // Set once an attempt fails without a verdict. The server revokes the
    // presented refresh token before it answers, so a lost answer burns the
    // token: every `unauthenticated` from here on is explained by our own
    // retry and is NOT evidence that the session is dead. Reporting it as
    // such is what logged users out over a single dropped response.
    var tokenMayBeSpent = false;
    for (var attempt = 0; attempt < _refreshMaxAttempts; attempt++) {
      try {
        return await _refreshOnce();
      } on StateError {
        // No token to present — no network call was made, and retrying
        // cannot conjure one.
        rethrow;
      } on RpcException catch (e, st) {
        if (isUnauthenticated(e)) {
          if (tokenMayBeSpent) {
            throw RefreshFailedException(RefreshFailureKind.ambiguous, e, st);
          }
          // Most of the time `unauthenticated` means the refresh token
          // itself is dead and retry can't help — but in the wild we see
          // transient false-positives (server rotation races, network
          // mid-flight reset) where a 30-second pause and one more
          // attempt succeeds. Give it exactly one second chance before
          // surrendering and asking the user to re-login.
          unauthAttempts++;
          if (unauthAttempts >= _maxUnauthRetries) {
            throw RefreshFailedException(RefreshFailureKind.refused, e, st);
          }
          await Future<void>.delayed(_unauthRetryDelay);
          continue;
        }
        tokenMayBeSpent = true;
        lastError = e;
        lastStack = st;
      } catch (e, st) {
        tokenMayBeSpent = true;
        lastError = e;
        lastStack = st;
      }
      if (attempt < _refreshMaxAttempts - 1) {
        await Future<void>.delayed(
          Duration(milliseconds: 200 * (1 << attempt)),
        );
      }
    }
    throw RefreshFailedException(
      RefreshFailureKind.transient,
      lastError!,
      lastStack,
    );
  }

  /// Verify email with token from the verification link.
  /// Returns true if a trial subscription was activated.
  Future<bool> verifyEmail(String token) async {
    final response = await _auth.verifyEmail(VerifyEmailRequest(token: token));
    return response.trialActivated;
  }

  Future<bool> getEmailVerified() async {
    final response = await _auth.getEmailVerified(
      const GetEmailVerifiedRequest(),
      context: await _authContext(),
    );
    return response.emailVerified;
  }

  Future<void> resendVerificationEmail() async {
    await _auth.resendVerificationEmail(
      const ResendVerificationRequest(),
      context: await _authContext(),
    );
  }

  Future<void> signOut() async {
    final token = _session?.refreshToken;
    if (token == null) return;
    try {
      await _auth.signOut(SignOutRequest(refreshToken: token));
    } finally {
      _session = null;
    }
  }

  /// Restore a previously persisted session without a network call.
  void useSession(AuthSession saved) {
    _session = saved;
  }

  // ---------------------------------------------------------------------------
  // Vaults
  // ---------------------------------------------------------------------------

  Future<List<VaultDto>> listVaults() async {
    final response = await _vault.listVaults(
      const ListVaultsRequest(),
      context: await _authContext(),
    );
    return response.vaults;
  }

  Future<void> createVault({
    required String vaultId,
    required String vaultName,
  }) async {
    await _vault.createVault(
      CreateVaultRequest(vaultId: vaultId, vaultName: vaultName),
      context: await _authContext(),
    );
  }

  Future<void> updateVerificationToken({
    required String vaultId,
    required String verificationToken,
  }) async {
    await _vault.updateVerificationToken(
      UpdateVerificationTokenRequest(
        vaultId: vaultId,
        verificationToken: verificationToken,
      ),
      context: await _authContext(),
    );
  }

  Future<void> updateVaultMeta({
    required String vaultId,
    required String encryptedMeta,
  }) async {
    await _vault.updateVaultMeta(
      UpdateVaultMetaRequest(
        vaultId: vaultId,
        encryptedMeta: encryptedMeta,
      ),
      context: await _authContext(),
    );
  }

  /// Returns the encrypted meta for a vault, or null if not set.
  /// Reads from listVaults response (no extra RPC needed).
  Future<String?> getVaultMeta({required String vaultId}) async {
    final response = await listVaults();
    final vault = response.firstWhere(
      (v) => v.vaultId == vaultId,
      orElse: () => VaultDto(vaultId: vaultId, vaultName: ''),
    );
    return vault.encryptedMeta;
  }

  /// Removes the vault registration. Call last in the delete flow, after the
  /// vault's data has been purged from the sync server + external storage.
  Future<void> deleteVault({required String vaultId}) async {
    await _vault.deleteVault(
      DeleteVaultRequest(vaultId: vaultId),
      context: await _authContext(),
    );
  }

  // ---------------------------------------------------------------------------
  // Subscription
  // ---------------------------------------------------------------------------

  Future<SubscriptionDto> getSubscription() async {
    return _subscription.getSubscription(
      const GetSubscriptionRequest(),
      context: await _authContext(),
    );
  }

  Future<List<InvoiceDto>> listInvoices() async {
    final response = await _subscription.listInvoices(
      const ListInvoicesRequest(),
      context: await _authContext(),
    );
    return response.invoices;
  }

  /// Returns the list of available products/plans from the server.
  /// Checks pending payments against Selfwork and activates subscription if any succeeded.
  Future<bool> restoreSubscription() async {
    final response = await _subscription.restoreSubscription(
      const RestoreSubscriptionRequest(),
      context: await _authContext(),
    );
    return response.restored;
  }

  Future<List<ProductDto>> listProducts() async {
    final response = await _subscription.listProducts(
      const ListProductsRequest(),
      context: await _authContext(),
    );
    return response.products;
  }

  /// Create a payment session. Returns the payment URL, or null if the
  /// subscription was activated without a redirect (e.g. dev simulation).
  Future<String?> createPayment({required String planId}) async {
    final response = await _subscription.createPayment(
      CreatePaymentRequest(planId: planId),
      context: await _authContext(),
    );
    return response.paymentUrl;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<RpcContext> _authContext() async {
    final token = await ensureValidToken();
    return RpcContextBuilder.inheritFrom(
      RpcContext.empty(),
    ).withBearerAuth(token).build();
  }
}
