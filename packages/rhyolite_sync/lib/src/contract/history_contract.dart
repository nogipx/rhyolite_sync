// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'history_contract.g.dart';

/// File operation type recorded in history.
enum HistoryOperation { create, modify, delete, move }

extension HistoryOperationCodec on HistoryOperation {
  String get wire => name;
  static HistoryOperation parse(String s) =>
      HistoryOperation.values.firstWhere((e) => e.name == s);
}

// ---------------------------------------------------------------------------
// GET
// ---------------------------------------------------------------------------

class HistoryGetRequest implements IRpcSerializable {
  const HistoryGetRequest({
    required this.vaultId,
    this.fileId,
    this.fromHlcPacked,
    this.beforeHlcPacked,
    this.limit = 100,
    this.ascending = false,
  });

  final String vaultId;

  /// Filter by a single file. Null = events for any file.
  final String? fileId;

  /// Return events with hlc > this. Null = no lower bound.
  final String? fromHlcPacked;

  /// Return events with hlc < this. Null = no upper bound. Used by the
  /// 3-way merge base lookup ("give me the latest event for this file
  /// strictly before our local/remote diverged").
  final String? beforeHlcPacked;

  final int limit;

  /// Default newest first (descending by hlc). Set true for chronological.
  final bool ascending;

  factory HistoryGetRequest.fromJson(Map<String, dynamic> json) =>
      HistoryGetRequest(
        vaultId: json['vaultId'] as String,
        fileId: json['fileId'] as String?,
        fromHlcPacked: json['fromHlcPacked'] as String?,
        beforeHlcPacked: json['beforeHlcPacked'] as String?,
        limit: (json['limit'] as int?) ?? 100,
        ascending: (json['ascending'] as bool?) ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'vaultId': vaultId,
        if (fileId != null) 'fileId': fileId,
        if (fromHlcPacked != null) 'fromHlcPacked': fromHlcPacked,
        if (beforeHlcPacked != null) 'beforeHlcPacked': beforeHlcPacked,
        'limit': limit,
        if (ascending) 'ascending': ascending,
      };
}

class HistoryEvent implements IRpcSerializable {
  const HistoryEvent({
    required this.eventId,
    required this.fileId,
    required this.blobRef,
    required this.hlcPacked,
    required this.operation,
    required this.encryptedMeta,
    required this.createdAtMs,
    this.contextPacked = '',
    this.serverSeq = 0,
    this.chunks = const [],
  });

  final String eventId;
  final String fileId;
  final String blobRef;
  final String hlcPacked;
  final HistoryOperation operation;
  final String encryptedMeta;

  /// Server's wall clock at the moment of storage. Used for retention.
  final int createdAtMs;

  /// Packed [CausalContext] the writer had seen at the moment of this
  /// event. Added for symmetry with [StateRecord] (doc §5.3) — the
  /// history service algorithm itself is unchanged.
  final String contextPacked;

  /// Monotonic per-vault sequence assigned at write time. Mirrors the
  /// file_state serverSeq so cleanup can reason about which events any
  /// device has already observed.
  final int serverSeq;

  /// Plain list of chunk hashes the file referenced at the time of this
  /// event. Server uses it as part of the live-chunk set during blob GC
  /// — a chunk is live as long as any non-expired history event still
  /// lists it.
  final List<String> chunks;

  factory HistoryEvent.fromJson(Map<String, dynamic> json) => HistoryEvent(
        eventId: json['eventId'] as String,
        fileId: json['fileId'] as String,
        blobRef: json['blobRef'] as String,
        hlcPacked: json['hlcPacked'] as String,
        operation: HistoryOperationCodec.parse(json['operation'] as String),
        encryptedMeta: json['encryptedMeta'] as String,
        createdAtMs: json['createdAtMs'] as int,
        contextPacked: (json['contextPacked'] as String?) ?? '',
        serverSeq: (json['serverSeq'] as int?) ?? 0,
        chunks: (json['chunks'] as List?)?.cast<String>() ?? const [],
      );

  @override
  Map<String, dynamic> toJson() => {
        'eventId': eventId,
        'fileId': fileId,
        'blobRef': blobRef,
        'hlcPacked': hlcPacked,
        'operation': operation.wire,
        'encryptedMeta': encryptedMeta,
        'createdAtMs': createdAtMs,
        if (contextPacked.isNotEmpty) 'contextPacked': contextPacked,
        if (serverSeq > 0) 'serverSeq': serverSeq,
        if (chunks.isNotEmpty) 'chunks': chunks,
      };
}

class HistoryGetResponse implements IRpcSerializable {
  const HistoryGetResponse({required this.events, required this.epoch});

  final List<HistoryEvent> events;
  final int epoch;

  factory HistoryGetResponse.fromJson(Map<String, dynamic> json) =>
      HistoryGetResponse(
        events: (json['events'] as List)
            .map((e) => HistoryEvent.fromJson(e as Map<String, dynamic>))
            .toList(),
        epoch: json['epoch'] as int,
      );

  @override
  Map<String, dynamic> toJson() => {
        'events': events.map((e) => e.toJson()).toList(),
        'epoch': epoch,
      };
}

// ---------------------------------------------------------------------------
// DELETE EVENTS (user-triggered cleanup)
// ---------------------------------------------------------------------------

class HistoryDeleteEventsRequest implements IRpcSerializable {
  const HistoryDeleteEventsRequest({
    required this.vaultId,
    required this.eventIds,
  });

  final String vaultId;
  final List<String> eventIds;

  factory HistoryDeleteEventsRequest.fromJson(Map<String, dynamic> json) =>
      HistoryDeleteEventsRequest(
        vaultId: json['vaultId'] as String,
        eventIds: List<String>.from(json['eventIds'] as List),
      );

  @override
  Map<String, dynamic> toJson() => {
        'vaultId': vaultId,
        'eventIds': eventIds,
      };
}

class HistoryDeleteEventsResponse implements IRpcSerializable {
  const HistoryDeleteEventsResponse({required this.deleted});

  /// Number of events actually removed. Less than requested when some ids
  /// were not found (idempotent — caller can re-run safely).
  final int deleted;

  factory HistoryDeleteEventsResponse.fromJson(Map<String, dynamic> json) =>
      HistoryDeleteEventsResponse(deleted: json['deleted'] as int);

  @override
  Map<String, dynamic> toJson() => {'deleted': deleted};
}

// ---------------------------------------------------------------------------
// HEADS (per-device watermarks for safe cleanup)
// ---------------------------------------------------------------------------

/// A device's checkpoint: the highest history serverSeq it has observed
/// and a packed [CausalContext] frontier — the latest HLC seen per
/// author from this device's view. The frontier is the source of truth
/// for causal-stability tombstone GC (Phase 5): a Sequence dot is
/// stable iff it is dominated by `min(frontier)` across every device
/// in the vault.
class DeviceHead implements IRpcSerializable {
  const DeviceHead({
    required this.deviceId,
    required this.headSeq,
    required this.updatedAtMs,
    this.frontierPacked = '',
  });

  final String deviceId;
  final int headSeq;
  final int updatedAtMs;

  /// Packed [CausalContext] this device had observed at the moment it
  /// last reported. Empty for legacy clients that don't ship a
  /// frontier yet — server treats empty as "unknown" and excludes
  /// from min-aggregation to avoid accidentally collapsing the
  /// boundary down to nothing.
  final String frontierPacked;

  factory DeviceHead.fromJson(Map<String, dynamic> json) => DeviceHead(
        deviceId: json['deviceId'] as String,
        headSeq: json['headSeq'] as int,
        updatedAtMs: json['updatedAtMs'] as int,
        frontierPacked: (json['frontierPacked'] as String?) ?? '',
      );

  @override
  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'headSeq': headSeq,
        'updatedAtMs': updatedAtMs,
        if (frontierPacked.isNotEmpty) 'frontierPacked': frontierPacked,
      };
}

class ReportHistoryHeadRequest implements IRpcSerializable {
  const ReportHistoryHeadRequest({
    required this.vaultId,
    required this.deviceId,
    required this.headSeq,
    this.frontierPacked = '',
  });

  final String vaultId;
  final String deviceId;
  final int headSeq;

  /// Packed [CausalContext] this device has observed. Used by the
  /// server to maintain the per-device frontier table that feeds
  /// causal-stability GC. Empty string from legacy clients is
  /// accepted but excluded from min-aggregation.
  final String frontierPacked;

  factory ReportHistoryHeadRequest.fromJson(Map<String, dynamic> json) =>
      ReportHistoryHeadRequest(
        vaultId: json['vaultId'] as String,
        deviceId: json['deviceId'] as String,
        headSeq: json['headSeq'] as int,
        frontierPacked: (json['frontierPacked'] as String?) ?? '',
      );

  @override
  Map<String, dynamic> toJson() => {
        'vaultId': vaultId,
        'deviceId': deviceId,
        'headSeq': headSeq,
        if (frontierPacked.isNotEmpty) 'frontierPacked': frontierPacked,
      };
}

class ReportHistoryHeadResponse implements IRpcSerializable {
  const ReportHistoryHeadResponse();

  factory ReportHistoryHeadResponse.fromJson(Map<String, dynamic> json) =>
      const ReportHistoryHeadResponse();

  @override
  Map<String, dynamic> toJson() => const {};
}

class GetHistoryHeadsRequest implements IRpcSerializable {
  const GetHistoryHeadsRequest({required this.vaultId});

  final String vaultId;

  factory GetHistoryHeadsRequest.fromJson(Map<String, dynamic> json) =>
      GetHistoryHeadsRequest(vaultId: json['vaultId'] as String);

  @override
  Map<String, dynamic> toJson() => {'vaultId': vaultId};
}

class GetHistoryHeadsResponse implements IRpcSerializable {
  const GetHistoryHeadsResponse({required this.heads});

  final List<DeviceHead> heads;

  factory GetHistoryHeadsResponse.fromJson(Map<String, dynamic> json) =>
      GetHistoryHeadsResponse(
        heads: (json['heads'] as List)
            .map((e) => DeviceHead.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  @override
  Map<String, dynamic> toJson() =>
      {'heads': heads.map((e) => e.toJson()).toList()};
}

// ---------------------------------------------------------------------------
// Contract
// ---------------------------------------------------------------------------

@RpcService(name: 'RhyoliteHistory', transferMode: RpcDataTransferMode.codec)
abstract class IHistoryContract {
  @RpcMethod.unary(name: 'getHistory')
  Future<HistoryGetResponse> getHistory(
    HistoryGetRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'deleteEvents')
  Future<HistoryDeleteEventsResponse> deleteEvents(
    HistoryDeleteEventsRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'reportHistoryHead')
  Future<ReportHistoryHeadResponse> reportHistoryHead(
    ReportHistoryHeadRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'getHistoryHeads')
  Future<GetHistoryHeadsResponse> getHistoryHeads(
    GetHistoryHeadsRequest request, {
    RpcContext? context,
  });
}
