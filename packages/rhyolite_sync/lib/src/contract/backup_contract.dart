import 'package:rpc_dart/rpc_dart.dart';

import 'state_sync_contract.dart' show StateRecord;

part 'backup_contract.g.dart';

/// Metadata for one vault backup snapshot on the wire.
class BackupSnapshotInfo implements IRpcSerializable {
  const BackupSnapshotInfo({
    required this.snapshotId,
    required this.createdAtMs,
    required this.recordCount,
  });

  final String snapshotId;
  final int createdAtMs;
  final int recordCount;

  factory BackupSnapshotInfo.fromJson(Map<String, dynamic> json) =>
      BackupSnapshotInfo(
        snapshotId: json['snapshotId'] as String,
        createdAtMs: (json['createdAtMs'] as num).toInt(),
        recordCount: (json['recordCount'] as int?) ?? 0,
      );

  @override
  Map<String, dynamic> toJson() => {
        'snapshotId': snapshotId,
        'createdAtMs': createdAtMs,
        'recordCount': recordCount,
      };
}

class ListBackupsRequest implements IRpcSerializable {
  const ListBackupsRequest({required this.vaultId});
  final String vaultId;

  factory ListBackupsRequest.fromJson(Map<String, dynamic> json) =>
      ListBackupsRequest(vaultId: json['vaultId'] as String);

  @override
  Map<String, dynamic> toJson() => {'vaultId': vaultId};
}

class ListBackupsResponse implements IRpcSerializable {
  const ListBackupsResponse({required this.snapshots});
  final List<BackupSnapshotInfo> snapshots;

  factory ListBackupsResponse.fromJson(Map<String, dynamic> json) =>
      ListBackupsResponse(
        snapshots: [
          for (final s in (json['snapshots'] as List? ?? const []))
            BackupSnapshotInfo.fromJson((s as Map).cast<String, dynamic>()),
        ],
      );

  @override
  Map<String, dynamic> toJson() =>
      {'snapshots': [for (final s in snapshots) s.toJson()]};
}

class GetBackupRequest implements IRpcSerializable {
  const GetBackupRequest({required this.vaultId, required this.snapshotId});
  final String vaultId;
  final String snapshotId;

  factory GetBackupRequest.fromJson(Map<String, dynamic> json) =>
      GetBackupRequest(
        vaultId: json['vaultId'] as String,
        snapshotId: json['snapshotId'] as String,
      );

  @override
  Map<String, dynamic> toJson() =>
      {'vaultId': vaultId, 'snapshotId': snapshotId};
}

/// A snapshot's frozen state records — the same shape a pull delivers, so the
/// client can decrypt each envelope, download the blob at its ref, and write it.
class GetBackupResponse implements IRpcSerializable {
  const GetBackupResponse({required this.records});
  final List<StateRecord> records;

  factory GetBackupResponse.fromJson(Map<String, dynamic> json) =>
      GetBackupResponse(
        records: [
          for (final r in (json['records'] as List? ?? const []))
            StateRecord.fromJson((r as Map).cast<String, dynamic>()),
        ],
      );

  @override
  Map<String, dynamic> toJson() =>
      {'records': [for (final r in records) r.toJson()]};
}

class CaptureBackupRequest implements IRpcSerializable {
  const CaptureBackupRequest({required this.vaultId});
  final String vaultId;

  factory CaptureBackupRequest.fromJson(Map<String, dynamic> json) =>
      CaptureBackupRequest(vaultId: json['vaultId'] as String);

  @override
  Map<String, dynamic> toJson() => {'vaultId': vaultId};
}

class CaptureBackupResponse implements IRpcSerializable {
  const CaptureBackupResponse({required this.snapshot});
  final BackupSnapshotInfo snapshot;

  factory CaptureBackupResponse.fromJson(Map<String, dynamic> json) =>
      CaptureBackupResponse(
        snapshot: BackupSnapshotInfo.fromJson(
            (json['snapshot'] as Map).cast<String, dynamic>()),
      );

  @override
  Map<String, dynamic> toJson() => {'snapshot': snapshot.toJson()};
}

class DeleteBackupRequest implements IRpcSerializable {
  const DeleteBackupRequest({required this.vaultId, required this.snapshotId});
  final String vaultId;
  final String snapshotId;

  factory DeleteBackupRequest.fromJson(Map<String, dynamic> json) =>
      DeleteBackupRequest(
        vaultId: json['vaultId'] as String,
        snapshotId: json['snapshotId'] as String,
      );

  @override
  Map<String, dynamic> toJson() =>
      {'vaultId': vaultId, 'snapshotId': snapshotId};
}

class DeleteBackupResponse implements IRpcSerializable {
  const DeleteBackupResponse({required this.deleted});
  final bool deleted;

  factory DeleteBackupResponse.fromJson(Map<String, dynamic> json) =>
      DeleteBackupResponse(deleted: (json['deleted'] as bool?) ?? false);

  @override
  Map<String, dynamic> toJson() => {'deleted': deleted};
}

class ClearBackupsRequest implements IRpcSerializable {
  const ClearBackupsRequest({required this.vaultId});
  final String vaultId;

  factory ClearBackupsRequest.fromJson(Map<String, dynamic> json) =>
      ClearBackupsRequest(vaultId: json['vaultId'] as String);

  @override
  Map<String, dynamic> toJson() => {'vaultId': vaultId};
}

class ClearBackupsResponse implements IRpcSerializable {
  const ClearBackupsResponse({required this.clearedSnapshots});
  final int clearedSnapshots;

  factory ClearBackupsResponse.fromJson(Map<String, dynamic> json) =>
      ClearBackupsResponse(
        clearedSnapshots: (json['clearedSnapshots'] as num?)?.toInt() ?? 0,
      );

  @override
  Map<String, dynamic> toJson() => {'clearedSnapshots': clearedSnapshots};
}

/// Backup access for a vault: list snapshots, fetch one snapshot's frozen
/// records for a restore, and clear all restore points to release their blob
/// pin (an escape valve when storage is tight). Capture/retention are
/// server-driven (managed).
@RpcService(name: 'RhyoliteBackup', transferMode: RpcDataTransferMode.codec)
abstract class IBackupContract {
  @RpcMethod.unary(name: 'listBackups')
  Future<ListBackupsResponse> listBackups(
    ListBackupsRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'getBackup')
  Future<GetBackupResponse> getBackup(
    GetBackupRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'captureBackup')
  Future<CaptureBackupResponse> captureBackup(
    CaptureBackupRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'deleteBackup')
  Future<DeleteBackupResponse> deleteBackup(
    DeleteBackupRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'clearBackups')
  Future<ClearBackupsResponse> clearBackups(
    ClearBackupsRequest request, {
    RpcContext? context,
  });
}
