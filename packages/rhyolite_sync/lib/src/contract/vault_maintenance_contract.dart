// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'vault_maintenance_contract.g.dart';

/// Server-authoritative storage maintenance. The sweep computes the live blob
/// set from the SERVER's own state records + history events (both hold plaintext
/// blobRef/chunks) so it is immune to a single client's stale view — a
/// client-computed live set could wrongly classify another device's live blob
/// as an orphan and delete it. UI reaches this via `BlobJanitor.sweepOrphans`.
class SweepOrphanBlobsRequest implements IRpcSerializable {
  const SweepOrphanBlobsRequest({required this.vaultId, this.dryRun = true});

  final String vaultId;

  /// When true (default) nothing is deleted — the response just reports what
  /// would be reclaimed. Set false to actually delete the orphans.
  final bool dryRun;

  factory SweepOrphanBlobsRequest.fromJson(Map<String, dynamic> json) =>
      SweepOrphanBlobsRequest(
        vaultId: json['vaultId'] as String,
        dryRun: (json['dryRun'] as bool?) ?? true,
      );

  @override
  Map<String, dynamic> toJson() => {
        'vaultId': vaultId,
        'dryRun': dryRun,
      };
}

class SweepOrphanBlobsResponse implements IRpcSerializable {
  const SweepOrphanBlobsResponse({
    required this.totalBlobs,
    required this.totalBytes,
    required this.orphanBlobs,
    required this.orphanBytes,
    required this.deletedBlobs,
  });

  /// Every blob currently in the vault bucket.
  final int totalBlobs;
  final int totalBytes;

  /// Blobs referenced by no live state and no history event — reclaimable.
  final int orphanBlobs;
  final int orphanBytes;

  /// Orphans actually deleted (0 on a dry run).
  final int deletedBlobs;

  factory SweepOrphanBlobsResponse.fromJson(Map<String, dynamic> json) =>
      SweepOrphanBlobsResponse(
        totalBlobs: (json['totalBlobs'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
        orphanBlobs: (json['orphanBlobs'] as num?)?.toInt() ?? 0,
        orphanBytes: (json['orphanBytes'] as num?)?.toInt() ?? 0,
        deletedBlobs: (json['deletedBlobs'] as num?)?.toInt() ?? 0,
      );

  @override
  Map<String, dynamic> toJson() => {
        'totalBlobs': totalBlobs,
        'totalBytes': totalBytes,
        'orphanBlobs': orphanBlobs,
        'orphanBytes': orphanBytes,
        'deletedBlobs': deletedBlobs,
      };
}

/// Reclaims tombstone rows (deleted files) from the vault's state once every
/// ACTIVE device has pulled past them — i.e. the delete has propagated to
/// everyone, so the marker is no longer needed. Server-authoritative: the server
/// reads device heads itself (no client can under-report and cause a premature
/// delete). Content recovery of a deleted file is via history / restore points,
/// not this marker.
class SweepStableTombstonesRequest implements IRpcSerializable {
  const SweepStableTombstonesRequest({required this.vaultId, this.dryRun = true});

  final String vaultId;
  final bool dryRun;

  factory SweepStableTombstonesRequest.fromJson(Map<String, dynamic> json) =>
      SweepStableTombstonesRequest(
        vaultId: json['vaultId'] as String,
        dryRun: (json['dryRun'] as bool?) ?? true,
      );

  @override
  Map<String, dynamic> toJson() => {'vaultId': vaultId, 'dryRun': dryRun};
}

class SweepStableTombstonesResponse implements IRpcSerializable {
  const SweepStableTombstonesResponse({
    required this.totalTombstones,
    required this.stableTombstones,
    required this.deletedTombstones,
  });

  /// Deleted-file (tombstone-only) records currently held.
  final int totalTombstones;

  /// Of those, how many every active device has already seen — reclaimable.
  final int stableTombstones;

  /// Actually deleted (0 on a dry run).
  final int deletedTombstones;

  factory SweepStableTombstonesResponse.fromJson(Map<String, dynamic> json) =>
      SweepStableTombstonesResponse(
        totalTombstones: (json['totalTombstones'] as num?)?.toInt() ?? 0,
        stableTombstones: (json['stableTombstones'] as num?)?.toInt() ?? 0,
        deletedTombstones: (json['deletedTombstones'] as num?)?.toInt() ?? 0,
      );

  @override
  Map<String, dynamic> toJson() => {
        'totalTombstones': totalTombstones,
        'stableTombstones': stableTombstones,
        'deletedTombstones': deletedTombstones,
      };
}

/// Targeted release of blobs a client believes it just superseded — the
/// immediate counterpart to the full sweep.
///
/// The client proposes candidates (e.g. the blobs of the plugin version it just
/// replaced); the SERVER decides, deleting only those its own live set does not
/// cover. That split is the whole point. Chunks are content-addressed and
/// shared: the same chunk can sit in another plugin, in a note, or in a
/// concurrent value of the very record being replaced (each MV value is its own
/// row, so a peer's un-merged version still counts as live). A client cannot
/// see any of that, and a client-side delete is how blobs go silently missing.
///
/// Unlike [SweepOrphanBlobsRequest] this never enumerates the bucket, so it is
/// cheap enough to run on every update.
class ReleaseBlobsRequest implements IRpcSerializable {
  const ReleaseBlobsRequest({required this.vaultId, required this.blobIds});

  final String vaultId;

  /// Candidates for deletion. Anything still referenced is silently kept.
  final List<String> blobIds;

  factory ReleaseBlobsRequest.fromJson(Map<String, dynamic> json) =>
      ReleaseBlobsRequest(
        vaultId: json['vaultId'] as String,
        blobIds:
            ((json['blobIds'] as List?) ?? const []).whereType<String>().toList(),
      );

  @override
  Map<String, dynamic> toJson() => {'vaultId': vaultId, 'blobIds': blobIds};
}

class ReleaseBlobsResponse implements IRpcSerializable {
  const ReleaseBlobsResponse({
    required this.requested,
    required this.stillReferenced,
    required this.deletedBlobs,
  });

  final int requested;

  /// Candidates rejected because something live still points at them.
  final int stillReferenced;

  final int deletedBlobs;

  factory ReleaseBlobsResponse.fromJson(Map<String, dynamic> json) =>
      ReleaseBlobsResponse(
        requested: (json['requested'] as num?)?.toInt() ?? 0,
        stillReferenced: (json['stillReferenced'] as num?)?.toInt() ?? 0,
        deletedBlobs: (json['deletedBlobs'] as num?)?.toInt() ?? 0,
      );

  @override
  Map<String, dynamic> toJson() => {
        'requested': requested,
        'stillReferenced': stillReferenced,
        'deletedBlobs': deletedBlobs,
      };
}

@RpcService(
  name: 'RhyoliteVaultMaintenance',
  transferMode: RpcDataTransferMode.codec,
)
abstract class IVaultMaintenanceContract {
  @RpcMethod.unary(name: 'sweepOrphanBlobs')
  Future<SweepOrphanBlobsResponse> sweepOrphanBlobs(
    SweepOrphanBlobsRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'releaseBlobs')
  Future<ReleaseBlobsResponse> releaseBlobs(
    ReleaseBlobsRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'sweepStableTombstones')
  Future<SweepStableTombstonesResponse> sweepStableTombstones(
    SweepStableTombstonesRequest request, {
    RpcContext? context,
  });
}
