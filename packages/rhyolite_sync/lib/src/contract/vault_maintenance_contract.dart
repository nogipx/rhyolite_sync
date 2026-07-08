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
}
