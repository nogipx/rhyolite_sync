// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'report_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class ReportContractNames {
  const ReportContractNames._();
  static const service = 'RhyoliteReports';
  static String instance(String suffix) => '$service\_$suffix';
  static const submitReport = 'submitReport';
}

class ReportContractCodecs {
  const ReportContractCodecs._();
  static const codecSubmitReportRequest =
      RpcCodec<SubmitReportRequest>.withDecoder(SubmitReportRequest.fromJson);
  static const codecSubmitReportResponse =
      RpcCodec<SubmitReportResponse>.withDecoder(SubmitReportResponse.fromJson);
}

class ReportContractCaller extends RpcCallerContract
    implements IReportContract {
  ReportContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? ReportContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<SubmitReportResponse> submitReport(
    SubmitReportRequest request, {
    RpcContext? context,
  }) {
    return callUnary<SubmitReportRequest, SubmitReportResponse>(
      methodName: ReportContractNames.submitReport,
      requestCodec: ReportContractCodecs.codecSubmitReportRequest,
      responseCodec: ReportContractCodecs.codecSubmitReportResponse,
      request: request,
      context: context,
    );
  }
}

abstract class ReportContractResponder extends RpcResponderContract
    implements IReportContract {
  ReportContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? ReportContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<SubmitReportRequest, SubmitReportResponse>(
      methodName: ReportContractNames.submitReport,
      handler: submitReport,
      requestCodec: ReportContractCodecs.codecSubmitReportRequest,
      responseCodec: ReportContractCodecs.codecSubmitReportResponse,
    );
  }
}
