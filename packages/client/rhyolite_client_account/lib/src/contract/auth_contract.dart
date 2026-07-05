// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'auth_contract.g.dart';

// --- DTOs ---

class SignUpRequest implements IRpcSerializable {
  const SignUpRequest({required this.email, required this.password});

  final String email;
  final String password;

  factory SignUpRequest.fromJson(Map<String, dynamic> json) => SignUpRequest(
    email: json['email'] as String,
    password: json['password'] as String,
  );

  @override
  Map<String, dynamic> toJson() => {'email': email, 'password': password};
}

class SignInRequest implements IRpcSerializable {
  const SignInRequest({required this.email, required this.password});

  final String email;
  final String password;

  factory SignInRequest.fromJson(Map<String, dynamic> json) => SignInRequest(
    email: json['email'] as String,
    password: json['password'] as String,
  );

  @override
  Map<String, dynamic> toJson() => {'email': email, 'password': password};
}

class RefreshRequest implements IRpcSerializable {
  const RefreshRequest({required this.refreshToken});

  final String refreshToken;

  factory RefreshRequest.fromJson(Map<String, dynamic> json) =>
      RefreshRequest(refreshToken: json['refresh_token'] as String);

  @override
  Map<String, dynamic> toJson() => {'refresh_token': refreshToken};
}

class SignOutRequest implements IRpcSerializable {
  const SignOutRequest({required this.refreshToken});

  final String refreshToken;

  factory SignOutRequest.fromJson(Map<String, dynamic> json) =>
      SignOutRequest(refreshToken: json['refresh_token'] as String);

  @override
  Map<String, dynamic> toJson() => {'refresh_token': refreshToken};
}

class SignOutResponse implements IRpcSerializable {
  const SignOutResponse();

  factory SignOutResponse.fromJson(Map<String, dynamic> _) =>
      const SignOutResponse();

  @override
  Map<String, dynamic> toJson() => const {};
}

class GetEmailVerifiedRequest implements IRpcSerializable {
  const GetEmailVerifiedRequest();
  factory GetEmailVerifiedRequest.fromJson(Map<String, dynamic> _) =>
      const GetEmailVerifiedRequest();
  @override
  Map<String, dynamic> toJson() => const {};
}

class GetEmailVerifiedResponse implements IRpcSerializable {
  const GetEmailVerifiedResponse({required this.emailVerified});
  final bool emailVerified;
  factory GetEmailVerifiedResponse.fromJson(Map<String, dynamic> json) =>
      GetEmailVerifiedResponse(emailVerified: json['email_verified'] as bool);
  @override
  Map<String, dynamic> toJson() => {'email_verified': emailVerified};
}

class ResendVerificationRequest implements IRpcSerializable {
  const ResendVerificationRequest();
  factory ResendVerificationRequest.fromJson(Map<String, dynamic> _) =>
      const ResendVerificationRequest();
  @override
  Map<String, dynamic> toJson() => const {};
}

class ResendVerificationResponse implements IRpcSerializable {
  const ResendVerificationResponse();
  factory ResendVerificationResponse.fromJson(Map<String, dynamic> _) =>
      const ResendVerificationResponse();
  @override
  Map<String, dynamic> toJson() => const {};
}

class VerifyEmailRequest implements IRpcSerializable {
  const VerifyEmailRequest({required this.token});

  final String token;

  factory VerifyEmailRequest.fromJson(Map<String, dynamic> json) =>
      VerifyEmailRequest(token: json['token'] as String);

  @override
  Map<String, dynamic> toJson() => {'token': token};
}

class VerifyEmailResponse implements IRpcSerializable {
  const VerifyEmailResponse({required this.trialActivated});

  /// True if a trial subscription was activated as part of verification.
  final bool trialActivated;

  factory VerifyEmailResponse.fromJson(Map<String, dynamic> json) =>
      VerifyEmailResponse(trialActivated: json['trial_activated'] as bool);

  @override
  Map<String, dynamic> toJson() => {'trial_activated': trialActivated};
}

/// Auth session returned by signUp, signIn, and refresh.
class AuthSession implements IRpcSerializable {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.userId,
    required this.email,
  });

  final String accessToken;
  final String refreshToken;

  /// Unix timestamp (seconds) when the access token expires.
  final int expiresAt;

  final String userId;
  final String email;

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt;

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
    accessToken: json['access_token'] as String,
    refreshToken: json['refresh_token'] as String,
    expiresAt: (json['expires_at'] as num).toInt(),
    userId: json['user_id'] as String,
    email: json['email'] as String,
  );

  @override
  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt,
    'user_id': userId,
    'email': email,
  };
}

// --- Contract ---

/// Public auth contract — no JWT required.
@RpcService(name: 'RhyoliteAuth', transferMode: RpcDataTransferMode.codec)
abstract class IAuthContract {
  /// Register a new account. Returns null if email confirmation is required.
  @RpcMethod.unary(name: 'signUp')
  Future<AuthSession> signUp(SignUpRequest request, {RpcContext? context});

  @RpcMethod.unary(name: 'signIn')
  Future<AuthSession> signIn(SignInRequest request, {RpcContext? context});

  @RpcMethod.unary(name: 'refresh')
  Future<AuthSession> refresh(RefreshRequest request, {RpcContext? context});

  @RpcMethod.unary(name: 'signOut')
  Future<SignOutResponse> signOut(
    SignOutRequest request, {
    RpcContext? context,
  });

  /// Verify email address using the token sent by email.
  /// On success, activates a trial subscription if none existed before.
  @RpcMethod.unary(name: 'verifyEmail')
  Future<VerifyEmailResponse> verifyEmail(
    VerifyEmailRequest request, {
    RpcContext? context,
  });

  /// Returns whether the current user's email is verified. Requires auth.
  @RpcMethod.unary(name: 'getEmailVerified')
  Future<GetEmailVerifiedResponse> getEmailVerified(
    GetEmailVerifiedRequest request, {
    RpcContext? context,
  });

  /// Resend verification email to the current user. Requires auth.
  @RpcMethod.unary(name: 'resendVerificationEmail')
  Future<ResendVerificationResponse> resendVerificationEmail(
    ResendVerificationRequest request, {
    RpcContext? context,
  });
}
