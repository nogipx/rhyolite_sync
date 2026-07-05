// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'history_contract.dart';

// **************************************************************************
// RpcDartGenerator
// **************************************************************************

// ignore_for_file: type=lint, unused_element

class HistoryContractNames {
  const HistoryContractNames._();
  static const service = 'RhyoliteHistory';
  static String instance(String suffix) => '$service\_$suffix';
  static const getHistory = 'getHistory';
  static const deleteEvents = 'deleteEvents';
  static const reportHistoryHead = 'reportHistoryHead';
  static const getHistoryHeads = 'getHistoryHeads';
}

class HistoryContractCodecs {
  const HistoryContractCodecs._();
  static const codecGetHistoryHeadsRequest =
      RpcCodec<GetHistoryHeadsRequest>.withDecoder(
        GetHistoryHeadsRequest.fromJson,
      );
  static const codecGetHistoryHeadsResponse =
      RpcCodec<GetHistoryHeadsResponse>.withDecoder(
        GetHistoryHeadsResponse.fromJson,
      );
  static const codecHistoryDeleteEventsRequest =
      RpcCodec<HistoryDeleteEventsRequest>.withDecoder(
        HistoryDeleteEventsRequest.fromJson,
      );
  static const codecHistoryDeleteEventsResponse =
      RpcCodec<HistoryDeleteEventsResponse>.withDecoder(
        HistoryDeleteEventsResponse.fromJson,
      );
  static const codecHistoryGetRequest = RpcCodec<HistoryGetRequest>.withDecoder(
    HistoryGetRequest.fromJson,
  );
  static const codecHistoryGetResponse =
      RpcCodec<HistoryGetResponse>.withDecoder(HistoryGetResponse.fromJson);
  static const codecReportHistoryHeadRequest =
      RpcCodec<ReportHistoryHeadRequest>.withDecoder(
        ReportHistoryHeadRequest.fromJson,
      );
  static const codecReportHistoryHeadResponse =
      RpcCodec<ReportHistoryHeadResponse>.withDecoder(
        ReportHistoryHeadResponse.fromJson,
      );
}

class HistoryContractCaller extends RpcCallerContract
    implements IHistoryContract {
  HistoryContractCaller(
    RpcCallerEndpoint endpoint, {
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? HistoryContractNames.service,
         endpoint,
         dataTransferMode: dataTransferMode,
       );

  @override
  Future<HistoryGetResponse> getHistory(
    HistoryGetRequest request, {
    RpcContext? context,
  }) {
    return callUnary<HistoryGetRequest, HistoryGetResponse>(
      methodName: HistoryContractNames.getHistory,
      requestCodec: HistoryContractCodecs.codecHistoryGetRequest,
      responseCodec: HistoryContractCodecs.codecHistoryGetResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<HistoryDeleteEventsResponse> deleteEvents(
    HistoryDeleteEventsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<HistoryDeleteEventsRequest, HistoryDeleteEventsResponse>(
      methodName: HistoryContractNames.deleteEvents,
      requestCodec: HistoryContractCodecs.codecHistoryDeleteEventsRequest,
      responseCodec: HistoryContractCodecs.codecHistoryDeleteEventsResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<ReportHistoryHeadResponse> reportHistoryHead(
    ReportHistoryHeadRequest request, {
    RpcContext? context,
  }) {
    return callUnary<ReportHistoryHeadRequest, ReportHistoryHeadResponse>(
      methodName: HistoryContractNames.reportHistoryHead,
      requestCodec: HistoryContractCodecs.codecReportHistoryHeadRequest,
      responseCodec: HistoryContractCodecs.codecReportHistoryHeadResponse,
      request: request,
      context: context,
    );
  }

  @override
  Future<GetHistoryHeadsResponse> getHistoryHeads(
    GetHistoryHeadsRequest request, {
    RpcContext? context,
  }) {
    return callUnary<GetHistoryHeadsRequest, GetHistoryHeadsResponse>(
      methodName: HistoryContractNames.getHistoryHeads,
      requestCodec: HistoryContractCodecs.codecGetHistoryHeadsRequest,
      responseCodec: HistoryContractCodecs.codecGetHistoryHeadsResponse,
      request: request,
      context: context,
    );
  }
}

abstract class HistoryContractResponder extends RpcResponderContract
    implements IHistoryContract {
  HistoryContractResponder({
    String? serviceNameOverride,
    RpcDataTransferMode dataTransferMode = RpcDataTransferMode.codec,
  }) : super(
         serviceNameOverride ?? HistoryContractNames.service,
         dataTransferMode: dataTransferMode,
       );

  @override
  void setup() {
    addUnaryMethod<HistoryGetRequest, HistoryGetResponse>(
      methodName: HistoryContractNames.getHistory,
      handler: getHistory,
      requestCodec: HistoryContractCodecs.codecHistoryGetRequest,
      responseCodec: HistoryContractCodecs.codecHistoryGetResponse,
    );
    addUnaryMethod<HistoryDeleteEventsRequest, HistoryDeleteEventsResponse>(
      methodName: HistoryContractNames.deleteEvents,
      handler: deleteEvents,
      requestCodec: HistoryContractCodecs.codecHistoryDeleteEventsRequest,
      responseCodec: HistoryContractCodecs.codecHistoryDeleteEventsResponse,
    );
    addUnaryMethod<ReportHistoryHeadRequest, ReportHistoryHeadResponse>(
      methodName: HistoryContractNames.reportHistoryHead,
      handler: reportHistoryHead,
      requestCodec: HistoryContractCodecs.codecReportHistoryHeadRequest,
      responseCodec: HistoryContractCodecs.codecReportHistoryHeadResponse,
    );
    addUnaryMethod<GetHistoryHeadsRequest, GetHistoryHeadsResponse>(
      methodName: HistoryContractNames.getHistoryHeads,
      handler: getHistoryHeads,
      requestCodec: HistoryContractCodecs.codecGetHistoryHeadsRequest,
      responseCodec: HistoryContractCodecs.codecGetHistoryHeadsResponse,
    );
  }
}
