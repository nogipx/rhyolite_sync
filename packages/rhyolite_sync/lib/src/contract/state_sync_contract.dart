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

  /// Plain list of chunk ids — keyed `HMAC-SHA256(vault subkey, plain chunk
  /// bytes)`, NOT a raw sha256 (keying closes the confirmation-of-file oracle;
  /// see ChunkedBlobIO). The server uses this list to compute the live chunk
  /// set during blob GC. Empty for tombstones.
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

/// Why the server refused a single putStates item.
///
/// Carried per-item in [StatePutResult] so one over-limit record does not fail
/// the whole batch. Machine-readable so the client can surface it and stop
/// re-pushing until the file changes.
class StatePutRejection implements IRpcSerializable {
  const StatePutRejection({
    required this.code,
    required this.current,
    required this.limit,
  });

  /// Reason code, e.g. `state_size` (record exceeds the server's size cap).
  final String code;

  /// The offending value (e.g. the encrypted record's byte size).
  final int current;

  /// The limit that was exceeded.
  final int limit;

  factory StatePutRejection.fromJson(Map<String, dynamic> json) =>
      StatePutRejection(
        code: json['code'] as String,
        current: (json['current'] as num).toInt(),
        limit: (json['limit'] as num).toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
        'code': code,
        'current': current,
        'limit': limit,
      };
}

/// Per-file outcome of a putStates call.
///
/// A successful CRDT put reports the assigned [serverSeq]. A put can also be
/// REJECTED per-item (e.g. the record exceeds the server's size cap): the rest
/// of the batch still succeeds, and this item carries a [rejection] with a
/// machine-readable reason instead of being written. The client must NOT treat
/// a rejected item as synced.
class StatePutResult implements IRpcSerializable {
  const StatePutResult({
    required this.fileId,
    required this.serverSeq,
    this.rejection,
  });

  final String fileId;

  /// Monotonic cursor assigned to this newly-stored TaggedValue; clients
  /// filter pulls by cursor > sinceCursor. Zero when [rejection] is set.
  final int serverSeq;

  /// Non-null when the server refused to store this item.
  final StatePutRejection? rejection;

  bool get rejected => rejection != null;

  factory StatePutResult.fromJson(Map<String, dynamic> json) => StatePutResult(
        fileId: json['fileId'] as String,
        serverSeq: json['serverSeq'] as int,
        rejection: json['rejection'] == null
            ? null
            : StatePutRejection.fromJson(
                json['rejection'] as Map<String, dynamic>),
      );

  @override
  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'serverSeq': serverSeq,
        if (rejection != null) 'rejection': rejection!.toJson(),
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
// PURGE — permanent, irreversible teardown of a vault keyspace.
// ---------------------------------------------------------------------------

/// Request to permanently destroy a vault keyspace: drops every collection AND
/// both `state_meta` keys (seq + epoch), with no epoch bump. Distinct from
/// [StateWipeRequest], which is a reset-for-re-upload that keeps the vault alive
/// and bumps the epoch so live clients re-sync. Call once per keyspace (notes
/// and, separately, config).
class StatePurgeRequest implements IRpcSerializable {
  const StatePurgeRequest({required this.vaultId, this.sourceClientId});

  final String vaultId;
  final String? sourceClientId;

  factory StatePurgeRequest.fromJson(Map<String, dynamic> json) =>
      StatePurgeRequest(
        vaultId: json['vaultId'] as String,
        sourceClientId: json['sourceClientId'] as String?,
      );

  @override
  Map<String, dynamic> toJson() => {
        'vaultId': vaultId,
        if (sourceClientId != null) 'sourceClientId': sourceClientId,
      };
}

class StatePurgeResponse implements IRpcSerializable {
  const StatePurgeResponse();

  factory StatePurgeResponse.fromJson(Map<String, dynamic> _) =>
      const StatePurgeResponse();

  @override
  Map<String, dynamic> toJson() => const {};
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

  /// Permanently destroy this keyspace of the vault (collections + seq + epoch),
  /// with no epoch bump. Used by the delete-vault flow, not by re-upload.
  @RpcMethod.unary(name: 'purgeVault')
  Future<StatePurgeResponse> purgeVault(
    StatePurgeRequest request, {
    RpcContext? context,
  });
}
