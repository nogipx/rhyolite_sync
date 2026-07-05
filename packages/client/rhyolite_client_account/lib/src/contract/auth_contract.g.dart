// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'auth_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class AuthContractNames {
  const AuthContractNames._();
  static const service = 'RhyoliteAuth';
  static String instance(String suffix) => '$service\_$suffix';
  static const signUp = 'signUp';
  static const signIn = 'signIn';
  static const refresh = 'refresh';
  static const signOut = 'signOut';
  static const verifyEmail = 'verifyEmail';
  static const getEmailVerified = 'getEmailVerified';
  static const resendVerificationEmail = 'resendVerificationEmail';
}

class AuthContractCodecs {
  const AuthContractCodecs._();
  static const codecAuthSession = RpcCodec<AuthSession>.withDecoder(
    AuthSession.fromJson,
  );
  static const codecGetEmailVerifiedRequest =
      RpcCodec<GetEmailVerifiedRequest>.withDecoder(
        GetEmailVerifiedRequest.fromJson,
      );
  static const codecGetEmailVerifiedResponse =
      RpcCodec<GetEmailVerifiedResponse>.withDecoder(
        GetEmailVerifiedResponse.fromJson,
      );
  static const codecRefreshRequest = RpcCodec<RefreshRequest>.withDecoder(
    RefreshRequest.fromJson,
  );
  static const codecResendVerificationRequest =
      RpcCodec<ResendVerificationRequest>.withDecoder(
        ResendVerificationRequest.fromJson,
      );
  static const codecResendVerificationResponse =
      RpcCodec<ResendVerificationResponse>.withDecoder(
        ResendVerificationResponse.fromJson,
      );
  static const codecSignInRequest = RpcCodec<SignInRequest>.withDecoder(
    SignInRequest.fromJson,
  );
  static const codecSignOutRequest = RpcCodec<SignOutRequest>.withDecoder(
    SignOutRequest.fromJson,
  );
  static const codecSignOutResponse = RpcCodec<SignOutResponse>.withDecoder(
    SignOutResponse.fromJson,
  );
  static const codecSignUpRequest = RpcCodec<SignUpRequest>.withDecoder(
    SignUpRequest.fromJson,
  );
  static const codecVerifyEmailRequest =
      RpcCodec<VerifyEmailRequest>.withDecoder(VerifyEmailRequest.fromJson);
  static const codecVerifyEmailResponse =
      RpcCodec<VerifyEmailResponse>.withDecoder(VerifyEmailResponse.fromJson);
}

class AuthContractCaller extends RpcCallerContract implements IAuthContract {
  AuthContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? AuthContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<AuthSession> signUp(SignUpRequest request, {RpcContext? context}) {
    return callUnary<SignUpRequest, AuthSession>(
      methodName: AuthContractNames.signUp,
      requestCodec: AuthContractCodecs.codecSignUpRequest,
      responseCodec: AuthContractCodecs.codecAuthSession,
      request: request,
      context: context,
    );
  }

  @override
  Future<AuthSession> signIn(SignInRequest request, {RpcContext? context}) {
    return callUnary<SignInRequest, AuthSession>(
      methodName: AuthContractNames.signIn,
      requestCodec: AuthContractCodecs.codecSignInRequest,
      responseCodec: AuthContractCodecs.codecAuthSession,
      request: request,
      context: context,
    );
  }

  @override
  Future<AuthSession> refresh(RefreshRequest request, {RpcContext? context}) {
    return callUnary<RefreshRequest, AuthSession>(
      methodName: AuthContractNames.refresh,
      requestCodec: AuthContractCodecs.codecRefreshRequest,
      responseCodec: AuthContractCodecs.codecAuthSession,
      request: request,
      context: context,
    );
  }

  @override
  Future<SignOutResponse> signOut(
    SignOutRequest request, {
    RpcContext? context,
  }) {
    return callUnary<SignOutRequest, SignOutResponse>(
      methodName: AuthContractNames.signOut,
      requestCodec: AuthContractCodecs.codecSignOutRequest,
      responseCodec: AuthContractCodecs.codecSignOutResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<VerifyEmailResponse> verifyEmail(
    VerifyEmailRequest request, {
    RpcContext? context,
  }) {
    return callUnary<VerifyEmailRequest, VerifyEmailResponse>(
      methodName: AuthContractNames.verifyEmail,
      requestCodec: AuthContractCodecs.codecVerifyEmailRequest,
      responseCodec: AuthContractCodecs.codecVerifyEmailResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<GetEmailVerifiedResponse> getEmailVerified(
    GetEmailVerifiedRequest request, {
    RpcContext? context,
  }) {
    return callUnary<GetEmailVerifiedRequest, GetEmailVerifiedResponse>(
      methodName: AuthContractNames.getEmailVerified,
      requestCodec: AuthContractCodecs.codecGetEmailVerifiedRequest,
      responseCodec: AuthContractCodecs.codecGetEmailVerifiedResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<ResendVerificationResponse> resendVerificationEmail(
    ResendVerificationRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ResendVerificationRequest, ResendVerificationResponse>(
      methodName: AuthContractNames.resendVerificationEmail,
      requestCodec: AuthContractCodecs.codecResendVerificationRequest,
      responseCodec: AuthContractCodecs.codecResendVerificationResponse,
      request: request,
      context: context,
    );
  }
}

abstract class AuthContractResponder extends RpcResponderContract
    implements IAuthContract {
  AuthContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? AuthContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<SignUpRequest, AuthSession>(
      methodName: AuthContractNames.signUp,
      handler: signUp,
      requestCodec: AuthContractCodecs.codecSignUpRequest,
      responseCodec: AuthContractCodecs.codecAuthSession,
    );
    addUnaryMethod<SignInRequest, AuthSession>(
      methodName: AuthContractNames.signIn,
      handler: signIn,
      requestCodec: AuthContractCodecs.codecSignInRequest,
      responseCodec: AuthContractCodecs.codecAuthSession,
    );
    addUnaryMethod<RefreshRequest, AuthSession>(
      methodName: AuthContractNames.refresh,
      handler: refresh,
      requestCodec: AuthContractCodecs.codecRefreshRequest,
      responseCodec: AuthContractCodecs.codecAuthSession,
    );
    addUnaryMethod<SignOutRequest, SignOutResponse>(
      methodName: AuthContractNames.signOut,
      handler: signOut,
      requestCodec: AuthContractCodecs.codecSignOutRequest,
      responseCodec: AuthContractCodecs.codecSignOutResponse,
    );
    addUnaryMethod<VerifyEmailRequest, VerifyEmailResponse>(
      methodName: AuthContractNames.verifyEmail,
      handler: verifyEmail,
      requestCodec: AuthContractCodecs.codecVerifyEmailRequest,
      responseCodec: AuthContractCodecs.codecVerifyEmailResponse,
    );
    addUnaryMethod<GetEmailVerifiedRequest, GetEmailVerifiedResponse>(
      methodName: AuthContractNames.getEmailVerified,
      handler: getEmailVerified,
      requestCodec: AuthContractCodecs.codecGetEmailVerifiedRequest,
      responseCodec: AuthContractCodecs.codecGetEmailVerifiedResponse,
    );
    addUnaryMethod<ResendVerificationRequest, ResendVerificationResponse>(
      methodName: AuthContractNames.resendVerificationEmail,
      handler: resendVerificationEmail,
      requestCodec: AuthContractCodecs.codecResendVerificationRequest,
      responseCodec: AuthContractCodecs.codecResendVerificationResponse,
    );
  }
}
