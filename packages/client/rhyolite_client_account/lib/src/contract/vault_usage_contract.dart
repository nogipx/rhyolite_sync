// ignore_for_file: uri_has_not_been_generated

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

part 'vault_usage_contract.g.dart';

// --- DTOs ---

class GetVaultUsageRequest implements IRpcSerializable {
  const GetVaultUsageRequest({required this.vaultId});

  final String vaultId;

  factory GetVaultUsageRequest.fromJson(Map<String, dynamic> json) =>
      GetVaultUsageRequest(vaultId: json['vaultId'] as String);

  @override
  Map<String, dynamic> toJson() => {'vaultId': vaultId};
}

class GetVaultUsageResponse implements IRpcSerializable {
  const GetVaultUsageResponse({
    required this.usedBytes,
    required this.quotaBytes,
  });

  final int usedBytes;
  final int quotaBytes;

  factory GetVaultUsageResponse.fromJson(Map<String, dynamic> json) =>
      GetVaultUsageResponse(
        usedBytes: (json['usedBytes'] as num).toInt(),
        quotaBytes: (json['quotaBytes'] as num).toInt(),
      );

  @override
  Map<String, dynamic> toJson() => {
    'usedBytes': usedBytes,
    'quotaBytes': quotaBytes,
  };
}

// --- Contract ---

@RpcService(name: 'RhyoliteVaultUsage', transferMode: RpcDataTransferMode.codec)
abstract class IVaultUsageContract {
  @RpcMethod.unary(name: 'getVaultUsage')
  Future<GetVaultUsageResponse> getVaultUsage(
    GetVaultUsageRequest request, {
    RpcContext? context,
  });
}
