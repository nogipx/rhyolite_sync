import 'dart:async';

import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_promo/rpc_promo.dart';

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
  RpcAccountClient(RpcCallerEndpoint endpoint)
    : _auth = AuthContractCaller(endpoint),
      _vault = VaultContractCaller(endpoint),
      _subscription = SubscriptionContractCaller(endpoint),
      _discount = DiscountContractCaller(endpoint);

  final AuthContractCaller _auth;
  final VaultContractCaller _vault;
  final SubscriptionContractCaller _subscription;
  final DiscountContractCaller _discount;

  // ---------------------------------------------------------------------------
  // Session state
  // ---------------------------------------------------------------------------

  AuthSession? _session;

  /// In-flight refresh, shared by concurrent [ensureValidToken] callers.
  /// Lifecycle: created at the start of one refresh, cleared in `finally`.
  /// Acts as a per-instance mutex — never a long-lived timer.
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
  static const Duration _unauthRetryDelay = Duration(seconds: 30);

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

  Future<AuthSession> refreshSession() async {
    final token = _session?.refreshToken;
    if (token == null) throw StateError('Not signed in');
    final session = await _auth.refresh(RefreshRequest(refreshToken: token));
    await _setSession(session);
    return session;
  }

  /// Returns a valid access token, refreshing it proactively when the
  /// recorded expiry is within [_refreshSafetyMargin]. Concurrent
  /// callers share a single in-flight refresh via [_refreshInFlight]
  /// so refresh-token rotation can't kill all but one of them.
  ///
  /// Transient failures retry with exponential backoff; an
  /// `unauthenticated` server error short-circuits immediately so the
  /// caller can prompt for re-login instead of pointlessly retrying.
  Future<String> ensureValidToken() async {
    final s = _session;
    if (s == null) throw StateError('Not signed in');
    if (!_needsRefresh(s)) return s.accessToken;

    final pending = _refreshInFlight;
    if (pending != null) return (await pending.future).accessToken;

    final completer = Completer<AuthSession>();
    _refreshInFlight = completer;
    try {
      final fresh = await _refreshWithRetry();
      completer.complete(fresh);
      return fresh.accessToken;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _refreshInFlight = null;
    }
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
    for (var attempt = 0; attempt < _refreshMaxAttempts; attempt++) {
      try {
        return await refreshSession();
      } on RpcException catch (e, st) {
        if (e.message.startsWith('unauthenticated')) {
          // Most of the time `unauthenticated` means the refresh token
          // itself is dead and retry can't help — but in the wild we see
          // transient false-positives (server rotation races, network
          // mid-flight reset) where a 30-second pause and one more
          // attempt succeeds. Give it exactly one second chance before
          // surrendering and asking the user to re-login.
          unauthAttempts++;
          if (unauthAttempts >= _maxUnauthRetries) rethrow;
          await Future<void>.delayed(_unauthRetryDelay);
          continue;
        }
        lastError = e;
        lastStack = st;
      } catch (e, st) {
        lastError = e;
        lastStack = st;
      }
      if (attempt < _refreshMaxAttempts - 1) {
        await Future<void>.delayed(
          Duration(milliseconds: 200 * (1 << attempt)),
        );
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack ?? StackTrace.current);
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
  Future<String?> createPayment({
    required String planId,
    String? discountCode,
  }) async {
    final response = await _subscription.createPayment(
      CreatePaymentRequest(planId: planId, discountCode: discountCode),
      context: await _authContext(),
    );
    return response.paymentUrl;
  }

  /// Validates a discount code against the given plan + amount.
  ///
  /// Returns the discount preview when the code is valid; returns the
  /// machine-readable rejection reason in [PreviewDiscountResponse.errorReason]
  /// otherwise. Does not consume the code — that happens on payment
  /// success.
  Future<PreviewDiscountResponse> previewDiscount({
    required String code,
    required String planId,
    required int originalKopecks,
  }) async {
    return _discount.preview(
      PreviewDiscountRequest(
        code: code,
        planId: planId,
        originalKopecks: originalKopecks,
      ),
      context: await _authContext(),
    );
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
