import 'package:rpc_dart/rpc_dart.dart';

/// Whether [e] is the server refusing our credentials, as opposed to any
/// other failure.
///
/// Two forms have to be recognised, and missing the second is why a refusal
/// was indistinguishable from a network error for so long: a handler that
/// throws a bare `RpcException('unauthenticated: ...')` — which is what the
/// account server does — reaches the caller as INTERNAL (13) with the
/// exception's `toString()` glued onto the message, so the status code says
/// nothing and the message no longer *starts* with `unauthenticated`. A
/// handler that throws [RpcStatusException] keeps its code intact.
bool isUnauthenticated(RpcException e) {
  if (e is RpcStatusException && e.statusCode == RpcStatus.unauthenticated) {
    return true;
  }
  return e.message.contains('unauthenticated');
}

/// Why a session refresh failed.
///
/// The distinction is what stands between a dropped connection and a
/// logout. Refresh tokens are single-use: the server revokes the presented
/// token *before* it answers, so an answer we never receive still burns the
/// token. Reading the resulting `unauthenticated` as "the session is dead"
/// and clearing the stored session turns one lost response into a forced
/// re-login. Only [refused] is evidence.
enum RefreshFailureKind {
  /// The server rejected the refresh token itself, and no earlier attempt
  /// in this sequence could have consumed it. The session is dead — a
  /// re-login is the only way forward.
  refused,

  /// No usable answer at all: connection error, timeout, 5xx. The token may
  /// or may not have been consumed server-side, so the stored session must
  /// survive for a later attempt.
  transient,

  /// The server said `unauthenticated`, but an earlier attempt in this same
  /// sequence may already have reached it and rotated the token away — the
  /// refusal is explained by our own retry, not by a dead session. Non-fatal
  /// on purpose: a session that really is dead answers the *next*, clean
  /// attempt with [refused], and that one does clear it.
  ambiguous,
}

/// A refresh that did not produce a session, carrying [kind] so the caller
/// can decide whether discarding the stored session is justified.
class RefreshFailedException implements Exception {
  const RefreshFailedException(this.kind, this.cause, [this.stackTrace]);

  final RefreshFailureKind kind;

  /// The underlying error, kept for logging — the reason a refresh failed
  /// used to be swallowed entirely, which made "was I really logged out?"
  /// unanswerable after the fact.
  final Object cause;

  final StackTrace? stackTrace;

  /// True only when the server refused a token it had not already rotated
  /// away: the single case where dropping the stored session is correct.
  bool get sessionIsDead => kind == RefreshFailureKind.refused;

  @override
  String toString() => 'RefreshFailedException(${kind.name}): $cause';
}
