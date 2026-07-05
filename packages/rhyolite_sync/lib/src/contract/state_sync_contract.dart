// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'state_sync_contract.g.dart';

// ---------------------------------------------------------------------------
// PUT (push) DTOs
// ---------------------------------------------------------------------------

/// One file update in a putStates batch.
///
/// A single tagged value in the file's MvRegister (Δ-state CRDT, doc §4).
/// No OCC: server applies a coordination-free join.
class StatePutItem implements IRpcSerializable {
  /// Stable per-file identifier (UUID v5 of vaultId + relPath on client side).
  final String fileId;

  /// Base64-encoded encrypted FileEntry blob. Server never decrypts.
  final String encryptedState;

  /// sha256 of the file content, sent in plain so the server can track
  /// which blobs are currently referenced (for blob GC during history
  /// retention sweeps). Empty for tombstones.
  final String blobRef;

  /// Packed HLC of the writer's clock at edit time.
  final String hlcPacked;

  /// True when this update represents a soft-delete (file removed).
  final bool tombstone;

  /// Packed [CausalContext] the writer had seen at edit time. Used by the
  /// server's MvRegister.join to detect which existing values this write
  /// causally dominates (doc §4.2, §5.1).
  final String contextPacked;

  /// Plain list of chunk hashes (sha256 of plain chunk bytes) that this
  /// file consists of. The server uses it to compute the live chunk set
  /// during blob GC. Empty for tombstones.
  final List<String> chunks;

  const StatePutItem({
    required this.fileId,
    required this.encryptedState,
    required this.blobRef,
    required this.hlcPacked,
    required this.tombstone,
    required this.contextPacked,
    this.chunks = const [],
  });

  factory StatePutItem.fromJson(Map<String, dynamic> json) => StatePutItem(
        fileId: json['fileId'] as String,
        encryptedState: json['encryptedState'] as String,
        blobRef: (json['blobRef'] as String?) ?? '',
        hlcPacked: json['hlcPacked'] as String,
        tombstone: (json['tombstone'] as bool?) ?? false,
        contextPacked: (json['contextPacked'] as String?) ?? '',
        chunks: (json['chunks'] as List?)?.cast<String>() ?? const [],
      );

  @override
  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'encryptedState': encryptedState,
        if (blobRef.isNotEmpty) 'blobRef': blobRef,
        'hlcPacked': hlcPacked,
        if (tombstone) 'tombstone': true,
        if (contextPacked.isNotEmpty) 'contextPacked': contextPacked,
        if (chunks.isNotEmpty) 'chunks': chunks,
      };
}

class StatePutRequest implements IRpcSerializable {
  const StatePutRequest({
    required this.vaultId,
    required this.items,
    this.expectedEpoch,
    this.sourceClientId,
  });

  final String vaultId;
  final List<StatePutItem> items;

  /// Client's last-known epoch. Server rejects the entire batch (no writes)
  /// if its current epoch differs — vault was wiped, client must restore.
  final int? expectedEpoch;
  final String? sourceClientId;

  factory StatePutRequest.fromJson(Map<String, dynamic> json) => StatePutRequest(
        vaultId: json['vaultId'] as String,
        items: (json['items'] as List)
            .map((e) => StatePutItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        expectedEpoch: json['expectedEpoch'] as int?,
        sourceClientId: json['sourceClientId'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'vaultId': vaultId,
        'items': items.map((e) => e.toJson()).toList(),
        if (expectedEpoch != null) 'expectedEpoch': expectedEpoch,
        if (sourceClientId != null) 'sourceClientId': sourceClientId,
      };
}

/// Per-file outcome of a putStates call.
///
/// CRDT puts cannot be rejected — there is no OCC anymore (doc §5.1).
/// Only the assigned [serverSeq] is reported back.
class StatePutResult implements IRpcSerializable {
  const StatePutResult({
    required this.fileId,
    required this.serverSeq,
  });

  final String fileId;

  /// Monotonic cursor assigned to this newly-stored TaggedValue; clients
  /// filter pulls by cursor > sinceCursor.
  final int serverSeq;

  factory StatePutResult.fromJson(Map<String, dynamic> json) => StatePutResult(
        fileId: json['fileId'] as String,
        serverSeq: json['serverSeq'] as int,
      );

  @override
  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'serverSeq': serverSeq,
      };
}

class StatePutResponse implements IRpcSerializable {
  const StatePutResponse({
    required this.results,
    required this.cursor,
    required this.epoch,
    this.epochMismatch = false,
  });

  final List<StatePutResult> results;

  /// Server's current monotonic cursor after this batch (= max serverSeq).
  final int cursor;
  final int epoch;

  /// True when expectedEpoch did not match. NO writes were performed.
  final bool epochMismatch;

  factory StatePutResponse.fromJson(Map<String, dynamic> json) => StatePutResponse(
        results: (json['results'] as List)
            .map((e) => StatePutResult.fromJson(e as Map<String, dynamic>))
            .toList(),
        cursor: json['cursor'] as int,
        epoch: json['epoch'] as int,
        epochMismatch: (json['epochMismatch'] as bool?) ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'results': results.map((e) => e.toJson()).toList(),
        'cursor': cursor,
        'epoch': epoch,
        if (epochMismatch) 'epochMismatch': epochMismatch,
      };
}

// ---------------------------------------------------------------------------
// GET (pull) DTOs
// ---------------------------------------------------------------------------

class StateGetRequest implements IRpcSerializable {
  const StateGetRequest({required this.vaultId, required this.sinceCursor});

  final String vaultId;

  /// Return records whose serverSeq is strictly greater than this. 0 = full.
  final int sinceCursor;

  factory StateGetRequest.fromJson(Map<String, dynamic> json) => StateGetRequest(
        vaultId: json['vaultId'] as String,
        sinceCursor: json['sinceCursor'] as int,
      );

  @override
  Map<String, dynamic> toJson() => {
        'vaultId': vaultId,
        'sinceCursor': sinceCursor,
      };
}

/// One TaggedValue from a file's MvRegister (doc §5.2). A single fileId
/// can appear multiple times in a pull batch — that is what a multi-value
/// register looks like on the wire.
class StateRecord implements IRpcSerializable {
  const StateRecord({
    required this.fileId,
    required this.encryptedState,
    required this.blobRef,
    required this.hlcPacked,
    required this.contextPacked,
    required this.serverSeq,
    required this.tombstone,
    this.chunks = const [],
  });

  final String fileId;
  final String encryptedState;

  /// sha256 of the manifest blob (not of the file contents directly).
  /// Empty for tombstones.
  final String blobRef;
  final String hlcPacked;

  /// Packed [CausalContext] this TaggedValue was written under. Used by
  /// the client to reconstruct the MvRegister and to compute dominance
  /// when issuing the next write.
  final String contextPacked;
  final int serverSeq;
  final bool tombstone;

  /// Plain list of chunk hashes the file referenced at write time.
  /// Empty for tombstones.
  final List<String> chunks;

  factory StateRecord.fromJson(Map<String, dynamic> json) => StateRecord(
        fileId: json['fileId'] as String,
        encryptedState: json['encryptedState'] as String,
        blobRef: (json['blobRef'] as String?) ?? '',
        hlcPacked: json['hlcPacked'] as String,
        contextPacked: (json['contextPacked'] as String?) ?? '',
        serverSeq: json['serverSeq'] as int,
        tombstone: (json['tombstone'] as bool?) ?? false,
        chunks: (json['chunks'] as List?)?.cast<String>() ?? const [],
      );

  @override
  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'encryptedState': encryptedState,
        if (blobRef.isNotEmpty) 'blobRef': blobRef,
        'hlcPacked': hlcPacked,
        if (contextPacked.isNotEmpty) 'contextPacked': contextPacked,
        'serverSeq': serverSeq,
        if (tombstone) 'tombstone': true,
        if (chunks.isNotEmpty) 'chunks': chunks,
      };
}

class StateGetResponse implements IRpcSerializable {
  const StateGetResponse({
    required this.records,
    required this.cursor,
    required this.epoch,
  });

  final List<StateRecord> records;

  /// Server's current monotonic cursor. Clients save this as the new
  /// sinceCursor for the next getStates call.
  final int cursor;
  final int epoch;

  factory StateGetResponse.fromJson(Map<String, dynamic> json) => StateGetResponse(
        records: (json['records'] as List)
            .map((e) => StateRecord.fromJson(e as Map<String, dynamic>))
            .toList(),
        cursor: json['cursor'] as int,
        epoch: json['epoch'] as int,
      );

  @override
  Map<String, dynamic> toJson() => {
        'records': records.map((e) => e.toJson()).toList(),
        'cursor': cursor,
        'epoch': epoch,
      };
}

// ---------------------------------------------------------------------------
// WIPE
// ---------------------------------------------------------------------------

class StateWipeRequest implements IRpcSerializable {
  const StateWipeRequest({required this.vaultId, this.sourceClientId});

  final String vaultId;
  final String? sourceClientId;

  factory StateWipeRequest.fromJson(Map<String, dynamic> json) => StateWipeRequest(
        vaultId: json['vaultId'] as String,
        sourceClientId: json['sourceClientId'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'vaultId': vaultId,
        if (sourceClientId != null) 'sourceClientId': sourceClientId,
      };
}

class StateWipeResponse implements IRpcSerializable {
  const StateWipeResponse({required this.epoch});

  /// New epoch after the wipe.
  final int epoch;

  factory StateWipeResponse.fromJson(Map<String, dynamic> json) =>
      StateWipeResponse(epoch: json['epoch'] as int);

  @override
  Map<String, dynamic> toJson() => {'epoch': epoch};
}

// ---------------------------------------------------------------------------
// Contract
// ---------------------------------------------------------------------------

@RpcService(name: 'RhyoliteStateSync', transferMode: RpcDataTransferMode.codec)
abstract class IStateSyncContract {
  @RpcMethod.unary(name: 'getStates')
  Future<StateGetResponse> getStates(
    StateGetRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'putStates')
  Future<StatePutResponse> putStates(
    StatePutRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'wipeVault')
  Future<StateWipeResponse> wipeVault(
    StateWipeRequest request, {
    RpcContext? context,
  });
}
