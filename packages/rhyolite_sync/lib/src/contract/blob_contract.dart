// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'blob_contract.g.dart';

// --- DTOs ---

class BlobChunk implements IRpcSerializable {
  const BlobChunk({
    required this.bytes,
    required this.offset,
    required this.last,
    this.blobId,
    this.vaultId,
    this.totalLength,
  });

  final Uint8List bytes;
  final int offset;
  final bool last;

  /// Only set in the first chunk of an upload.
  final String? blobId;

  /// Only set in the first chunk of an upload.
  final String? vaultId;

  /// Total byte size of the blob. Only set in the first chunk of an upload.
  final int? totalLength;

  factory BlobChunk.fromJson(Map<String, dynamic> json) => BlobChunk(
    bytes: Uint8List.fromList((json['bytes'] as List).cast<int>()),
    offset: json['offset'] as int,
    last: json['last'] as bool,
    blobId: json['blobId'] as String?,
    vaultId: json['vaultId'] as String?,
    totalLength: json['totalLength'] as int?,
  );

  @override
  Map<String, dynamic> toJson() => {
    'bytes': bytes,
    'offset': offset,
    'last': last,
    if (blobId != null) 'blobId': blobId,
    if (vaultId != null) 'vaultId': vaultId,
    if (totalLength != null) 'totalLength': totalLength,
  };
}

class BulkUploadBlobResponse implements IRpcSerializable {
  const BulkUploadBlobResponse({required this.blobIds});

  final List<String> blobIds;

  factory BulkUploadBlobResponse.fromJson(Map<String, dynamic> json) =>
      BulkUploadBlobResponse(
        blobIds: List<String>.from(json['blobIds'] as List? ?? const []),
      );

  @override
  Map<String, dynamic> toJson() => {'blobIds': blobIds};
}

class BulkDownloadBlobRequest implements IRpcSerializable {
  const BulkDownloadBlobRequest({required this.vaultId, required this.blobIds});

  final String vaultId;
  final List<String> blobIds;

  factory BulkDownloadBlobRequest.fromJson(Map<String, dynamic> json) =>
      BulkDownloadBlobRequest(
        vaultId: json['vaultId'] as String,
        blobIds: List<String>.from(json['blobIds'] as List? ?? const []),
      );

  @override
  Map<String, dynamic> toJson() => {'vaultId': vaultId, 'blobIds': blobIds};
}

// --- Bulk delete ---

class BulkDeleteBlobsRequest implements IRpcSerializable {
  const BulkDeleteBlobsRequest({required this.vaultId, required this.blobIds});

  final String vaultId;
  final List<String> blobIds;

  factory BulkDeleteBlobsRequest.fromJson(Map<String, dynamic> json) =>
      BulkDeleteBlobsRequest(
        vaultId: json['vaultId'] as String,
        blobIds: List<String>.from(json['blobIds'] as List? ?? const []),
      );

  @override
  Map<String, dynamic> toJson() => {'vaultId': vaultId, 'blobIds': blobIds};
}

class BulkDeleteBlobsResponse implements IRpcSerializable {
  const BulkDeleteBlobsResponse({required this.deleted});

  /// Number of blobs that were actually removed. Idempotent: missing ids
  /// contribute zero, no error raised.
  final int deleted;

  factory BulkDeleteBlobsResponse.fromJson(Map<String, dynamic> json) =>
      BulkDeleteBlobsResponse(deleted: (json['deleted'] as int?) ?? 0);

  @override
  Map<String, dynamic> toJson() => {'deleted': deleted};
}

// --- Bulk exists ---

class BulkExistsBlobRequest implements IRpcSerializable {
  const BulkExistsBlobRequest({required this.vaultId, required this.blobIds});

  final String vaultId;
  final List<String> blobIds;

  factory BulkExistsBlobRequest.fromJson(Map<String, dynamic> json) =>
      BulkExistsBlobRequest(
        vaultId: json['vaultId'] as String,
        blobIds: List<String>.from(json['blobIds'] as List? ?? const []),
      );

  @override
  Map<String, dynamic> toJson() => {'vaultId': vaultId, 'blobIds': blobIds};
}

class BulkExistsBlobResponse implements IRpcSerializable {
  const BulkExistsBlobResponse({required this.presentIds});

  /// Subset of the requested ids that are durably present in the backend.
  final List<String> presentIds;

  factory BulkExistsBlobResponse.fromJson(Map<String, dynamic> json) =>
      BulkExistsBlobResponse(
        presentIds: List<String>.from(json['presentIds'] as List? ?? const []),
      );

  @override
  Map<String, dynamic> toJson() => {'presentIds': presentIds};
}

// --- Contract ---

@RpcService(name: 'RhyoliteBlob', transferMode: RpcDataTransferMode.codec)
abstract class IBlobContract {
  @RpcMethod(name: 'upload', kind: RpcMethodKind.clientStream)
  Future<BulkUploadBlobResponse> upload(
    Stream<BlobChunk> chunks, {
    RpcContext? context,
  });

  /// Returns which of [BulkExistsBlobRequest.blobIds] are durably stored.
  /// Cheap presence probe (HEAD-equivalent) — never transfers blob bytes.
  @RpcMethod.unary(name: 'bulkExists')
  Future<BulkExistsBlobResponse> bulkExists(
    BulkExistsBlobRequest request, {
    RpcContext? context,
  });

  @RpcMethod(name: 'download', kind: RpcMethodKind.serverStream)
  Stream<BlobChunk> download(
    BulkDownloadBlobRequest request, {
    RpcContext? context,
  });

  @RpcMethod.unary(name: 'bulkDelete')
  Future<BulkDeleteBlobsResponse> bulkDelete(
    BulkDeleteBlobsRequest request, {
    RpcContext? context,
  });
}
