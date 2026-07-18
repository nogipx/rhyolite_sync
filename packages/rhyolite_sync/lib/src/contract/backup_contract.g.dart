// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'backup_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class BackupContractNames {
  const BackupContractNames._();
  static const service = 'RhyoliteBackup';
  static String instance(String suffix) => '$service\_$suffix';
  static const listBackups = 'listBackups';
  static const getBackup = 'getBackup';
  static const captureBackup = 'captureBackup';
  static const deleteBackup = 'deleteBackup';
  static const clearBackups = 'clearBackups';
}

class BackupContractCodecs {
  const BackupContractCodecs._();
  static const codecCaptureBackupRequest =
      RpcCodec<CaptureBackupRequest>.withDecoder(CaptureBackupRequest.fromJson);
  static const codecCaptureBackupResponse =
      RpcCodec<CaptureBackupResponse>.withDecoder(
        CaptureBackupResponse.fromJson,
      );
  static const codecClearBackupsRequest =
      RpcCodec<ClearBackupsRequest>.withDecoder(ClearBackupsRequest.fromJson);
  static const codecClearBackupsResponse =
      RpcCodec<ClearBackupsResponse>.withDecoder(ClearBackupsResponse.fromJson);
  static const codecDeleteBackupRequest =
      RpcCodec<DeleteBackupRequest>.withDecoder(DeleteBackupRequest.fromJson);
  static const codecDeleteBackupResponse =
      RpcCodec<DeleteBackupResponse>.withDecoder(DeleteBackupResponse.fromJson);
  static const codecGetBackupRequest = RpcCodec<GetBackupRequest>.withDecoder(
    GetBackupRequest.fromJson,
  );
  static const codecGetBackupResponse = RpcCodec<GetBackupResponse>.withDecoder(
    GetBackupResponse.fromJson,
  );
  static const codecListBackupsRequest =
      RpcCodec<ListBackupsRequest>.withDecoder(ListBackupsRequest.fromJson);
  static const codecListBackupsResponse =
      RpcCodec<ListBackupsResponse>.withDecoder(ListBackupsResponse.fromJson);
}

class BackupContractCaller extends RpcCallerContract
    implements IBackupContract {
  BackupContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? BackupContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<ListBackupsResponse> listBackups(
    ListBackupsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ListBackupsRequest, ListBackupsResponse>(
      methodName: BackupContractNames.listBackups,
      requestCodec: BackupContractCodecs.codecListBackupsRequest,
      responseCodec: BackupContractCodecs.codecListBackupsResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<GetBackupResponse> getBackup(
    GetBackupRequest request, {
    RpcContext? context,
  }) {
    return callUnary<GetBackupRequest, GetBackupResponse>(
      methodName: BackupContractNames.getBackup,
      requestCodec: BackupContractCodecs.codecGetBackupRequest,
      responseCodec: BackupContractCodecs.codecGetBackupResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<CaptureBackupResponse> captureBackup(
    CaptureBackupRequest request, {
    RpcContext? context,
  }) {
    return callUnary<CaptureBackupRequest, CaptureBackupResponse>(
      methodName: BackupContractNames.captureBackup,
      requestCodec: BackupContractCodecs.codecCaptureBackupRequest,
      responseCodec: BackupContractCodecs.codecCaptureBackupResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<DeleteBackupResponse> deleteBackup(
    DeleteBackupRequest request, {
    RpcContext? context,
  }) {
    return callUnary<DeleteBackupRequest, DeleteBackupResponse>(
      methodName: BackupContractNames.deleteBackup,
      requestCodec: BackupContractCodecs.codecDeleteBackupRequest,
      responseCodec: BackupContractCodecs.codecDeleteBackupResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<ClearBackupsResponse> clearBackups(
    ClearBackupsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ClearBackupsRequest, ClearBackupsResponse>(
      methodName: BackupContractNames.clearBackups,
      requestCodec: BackupContractCodecs.codecClearBackupsRequest,
      responseCodec: BackupContractCodecs.codecClearBackupsResponse,
      request: request,
      context: context,
    );
  }
}

abstract class BackupContractResponder extends RpcResponderContract
    implements IBackupContract {
  BackupContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? BackupContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<ListBackupsRequest, ListBackupsResponse>(
      methodName: BackupContractNames.listBackups,
      handler: listBackups,
      requestCodec: BackupContractCodecs.codecListBackupsRequest,
      responseCodec: BackupContractCodecs.codecListBackupsResponse,
    );
    addUnaryMethod<GetBackupRequest, GetBackupResponse>(
      methodName: BackupContractNames.getBackup,
      handler: getBackup,
      requestCodec: BackupContractCodecs.codecGetBackupRequest,
      responseCodec: BackupContractCodecs.codecGetBackupResponse,
    );
    addUnaryMethod<CaptureBackupRequest, CaptureBackupResponse>(
      methodName: BackupContractNames.captureBackup,
      handler: captureBackup,
      requestCodec: BackupContractCodecs.codecCaptureBackupRequest,
      responseCodec: BackupContractCodecs.codecCaptureBackupResponse,
    );
    addUnaryMethod<DeleteBackupRequest, DeleteBackupResponse>(
      methodName: BackupContractNames.deleteBackup,
      handler: deleteBackup,
      requestCodec: BackupContractCodecs.codecDeleteBackupRequest,
      responseCodec: BackupContractCodecs.codecDeleteBackupResponse,
    );
    addUnaryMethod<ClearBackupsRequest, ClearBackupsResponse>(
      methodName: BackupContractNames.clearBackups,
      handler: clearBackups,
      requestCodec: BackupContractCodecs.codecClearBackupsRequest,
      responseCodec: BackupContractCodecs.codecClearBackupsResponse,
    );
  }
}
