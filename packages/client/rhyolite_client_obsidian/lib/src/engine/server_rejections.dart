/// Plugin-specific typed subclasses of [SyncServerRejected].
///
/// Defined here (not in `rhyolite_sync`) so adding a new rejection
/// kind never edits the sync library. The [pluginRejectionFactory]
/// at the bottom is what we pass to `StateSyncEngine` so the engine
/// emits instances of these classes — UI code then pattern-matches
/// on types, not on raw string codes.
library;

import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Auth refresh token invalid — engine stops after emitting this.
class SessionExpired extends SyncServerRejected {
  SessionExpired(String message)
      : super(code: 'auth.session_expired', message: message);
}

/// Caller does not own the vault.
class PermissionDenied extends SyncServerRejected {
  PermissionDenied(String message)
      : super(code: 'auth.permission_denied', message: message);
}

/// User has no active subscription — engine stops after emitting this.
class SubscriptionRequired extends SyncServerRejected {
  SubscriptionRequired(String message)
      : super(
          code: 'app_policy.subscription_required',
          message: message,
        );
}

/// User's plan does not include managed-storage capability (typical
/// BYO tier). Raised when the daemon receives a blob upload from a
/// user whose plan capabilities don't allow our managed backend.
class ManagedStorageNotAllowed extends SyncServerRejected {
  ManagedStorageNotAllowed(String message)
      : super(
          code: 'app_policy.feature.managed_storage_unavailable',
          message: message,
        );
}

/// User's plan does not allow external (BYO) storage, and a putStates
/// referenced a blob that isn't in managed storage — i.e. the client was
/// patched to route blobs to its own storage on a plan without that
/// capability. The whole putStates is rejected server-side.
class ExternalStorageNotAllowed extends SyncServerRejected {
  ExternalStorageNotAllowed(String message)
      : super(
          code: 'app_policy.feature.external_storage_unavailable',
          message: message,
        );
}

/// User would exceed the per-tier vault-count cap. Raised by the
/// account server on vault creation; sync engine surfaces it the
/// first time the new vault is touched.
class VaultCountExceeded extends SyncServerRejected {
  VaultCountExceeded({
    required this.currentCount,
    required this.limitCount,
    required String message,
  }) : super(
          code: 'app_policy.quota.vault_count',
          message: message,
          params: {
            'current': '$currentCount',
            'limit': '$limitCount',
          },
        );

  final int currentCount;
  final int limitCount;

  static VaultCountExceeded fromParams(
    String message,
    Map<String, dynamic> params,
  ) =>
      VaultCountExceeded(
        currentCount: int.tryParse('${params['current'] ?? ''}') ?? 0,
        limitCount: int.tryParse('${params['limit'] ?? ''}') ?? 0,
        message: message,
      );
}

/// Single file exceeded the per-tier maximum size on the managed tier.
class FileSizeLimitExceeded extends SyncServerRejected {
  FileSizeLimitExceeded({
    required this.attemptedBytes,
    required this.limitBytes,
    required String message,
  }) : super(
          code: 'app_policy.quota.file_size',
          message: message,
          params: {
            'current': '$attemptedBytes',
            'limit': '$limitBytes',
          },
        );

  final int attemptedBytes;
  final int limitBytes;

  static FileSizeLimitExceeded fromParams(
    String message,
    Map<String, dynamic> params,
  ) =>
      FileSizeLimitExceeded(
        attemptedBytes: int.tryParse('${params['current'] ?? ''}') ?? 0,
        limitBytes: int.tryParse('${params['limit'] ?? ''}') ?? 0,
        message: message,
      );
}

/// Storage quota for the vault is exhausted.
class StorageQuotaExceeded extends SyncServerRejected {
  StorageQuotaExceeded({
    required this.currentBytes,
    required this.limitBytes,
    required String message,
  }) : super(
          code: 'app_policy.quota.storage',
          message: message,
          params: {
            'current': '$currentBytes',
            'limit': '$limitBytes',
          },
        );

  final int currentBytes;
  final int limitBytes;

  static StorageQuotaExceeded fromParams(
    String message,
    Map<String, dynamic> params,
  ) =>
      StorageQuotaExceeded(
        currentBytes: int.tryParse('${params['current'] ?? ''}') ?? 0,
        limitBytes: int.tryParse('${params['limit'] ?? ''}') ?? 0,
        message: message,
      );
}

/// The server holds an external blob storage config for this vault. Carries
/// only the NON-SECRET [kind] ('s3' / 'webdav'); the actual config (with
/// credentials) is applied by the engine itself and read from `engine.config`,
/// never sent on the broadcast events stream.
class ExternalBlobConfigDiscovered extends SyncServerRejected {
  ExternalBlobConfigDiscovered({
    required this.kind,
    required String message,
  }) : super(
          code: 'feature.external_blob_config_discovered',
          message: message,
          params: {'kind': kind},
        );

  final String kind;

  static ExternalBlobConfigDiscovered? tryFromParams(
    String message,
    Map<String, dynamic> params,
  ) {
    final kind = params['kind'];
    if (kind is! String || kind.isEmpty) return null;
    return ExternalBlobConfigDiscovered(kind: kind, message: message);
  }
}

/// Factory passed to [StateSyncEngine]. Maps known codes to typed
/// subclasses; returns null for unknown codes so the engine falls
/// back to emitting a raw [SyncServerRejected] envelope.
SyncServerRejected? pluginRejectionFactory(
  String code,
  String message,
  Map<String, dynamic> params,
) {
  switch (code) {
    case 'auth.session_expired':
      return SessionExpired(message);
    case 'auth.permission_denied':
      return PermissionDenied(message);
    case 'app_policy.subscription_required':
      return SubscriptionRequired(message);
    case 'app_policy.quota.storage':
      return StorageQuotaExceeded.fromParams(message, params);
    case 'app_policy.quota.file_size':
      return FileSizeLimitExceeded.fromParams(message, params);
    case 'app_policy.quota.vault_count':
      return VaultCountExceeded.fromParams(message, params);
    case 'app_policy.feature.managed_storage_unavailable':
      return ManagedStorageNotAllowed(message);
    case 'app_policy.feature.external_storage_unavailable':
      return ExternalStorageNotAllowed(message);
    case 'feature.external_blob_config_discovered':
      return ExternalBlobConfigDiscovered.tryFromParams(message, params);
  }
  return null;
}
