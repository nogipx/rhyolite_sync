/// Capability bundle that describes what a subscription [Plan] allows
/// its holder to do. Enforcement happens in the daemon
/// (per-upload checks) and in the account server (per-vault-creation
/// checks); the consumer never has to reason about plan _kind_, only
/// about specific capabilities.
///
/// Each numeric cap is nullable: `null` means "no managed-side cap"
/// (typical for BYO-storage plans where the user pays for their own
/// storage and we have no business limiting them). `0` is reserved
/// for "explicitly zero" — used for e.g. expired-subscription
/// fallback that denies everything.
class PlanCapabilities {
  const PlanCapabilities({
    required this.canUseManagedStorage,
    required this.canUseExternalStorage,
    this.maxVaultCount,
    this.maxFileSizeBytes,
    this.managedStorageQuotaBytes,
  });

  /// User may upload blobs to our managed storage backend (the
  /// in-protocol blob endpoint backed by MinIO/S3).
  final bool canUseManagedStorage;

  /// User may configure their own WebDAV / S3 / etc as the blob
  /// backend. Most plans grant this; the only reason to deny is a
  /// deliberate "managed-only" SKU we don't currently offer.
  final bool canUseExternalStorage;

  /// Maximum vaults the user may own. Account-server enforces at
  /// vault creation. `null` = no managed-side cap.
  final int? maxVaultCount;

  /// Maximum size in bytes of a single uploaded file. Daemon enforces
  /// on each blob upload that hits managed storage. Has no effect on
  /// external-storage traffic — daemon never sees those bytes.
  final int? maxFileSizeBytes;

  /// Total managed-storage quota across all the user's vaults.
  /// Daemon enforces on blob upload. Same caveat as
  /// [maxFileSizeBytes].
  final int? managedStorageQuotaBytes;

  /// Default-deny capabilities used as a safe fallback when no
  /// subscription is found or the resolver fails. All booleans false,
  /// all numeric caps 0 (which is treated as "explicitly zero, deny
  /// everything").
  static const PlanCapabilities deny = PlanCapabilities(
    canUseManagedStorage: false,
    canUseExternalStorage: false,
    maxVaultCount: 0,
    maxFileSizeBytes: 0,
    managedStorageQuotaBytes: 0,
  );

  /// Free tier — the default for a signed-up user with no active paid
  /// subscription (granted on registration and after a subscription
  /// lapses). Managed storage, no BYO, 1 vault, 10 MB/file, 50 MB quota.
  static const PlanCapabilities free = PlanCapabilities(
    canUseManagedStorage: true,
    canUseExternalStorage: false,
    maxVaultCount: 1,
    maxFileSizeBytes: 10 * 1024 * 1024,
    managedStorageQuotaBytes: 50 * 1024 * 1024,
  );

  factory PlanCapabilities.fromJson(Map<String, dynamic> json) =>
      PlanCapabilities(
        canUseManagedStorage: json['canUseManagedStorage'] as bool,
        canUseExternalStorage: json['canUseExternalStorage'] as bool,
        maxVaultCount: (json['maxVaultCount'] as num?)?.toInt(),
        maxFileSizeBytes: (json['maxFileSizeBytes'] as num?)?.toInt(),
        managedStorageQuotaBytes:
            (json['managedStorageQuotaBytes'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        'canUseManagedStorage': canUseManagedStorage,
        'canUseExternalStorage': canUseExternalStorage,
        if (maxVaultCount != null) 'maxVaultCount': maxVaultCount,
        if (maxFileSizeBytes != null) 'maxFileSizeBytes': maxFileSizeBytes,
        if (managedStorageQuotaBytes != null)
          'managedStorageQuotaBytes': managedStorageQuotaBytes,
      };

  @override
  bool operator ==(Object other) =>
      other is PlanCapabilities &&
      canUseManagedStorage == other.canUseManagedStorage &&
      canUseExternalStorage == other.canUseExternalStorage &&
      maxVaultCount == other.maxVaultCount &&
      maxFileSizeBytes == other.maxFileSizeBytes &&
      managedStorageQuotaBytes == other.managedStorageQuotaBytes;

  @override
  int get hashCode => Object.hash(
        canUseManagedStorage,
        canUseExternalStorage,
        maxVaultCount,
        maxFileSizeBytes,
        managedStorageQuotaBytes,
      );

  @override
  String toString() =>
      'PlanCapabilities(managed=$canUseManagedStorage, '
      'external=$canUseExternalStorage, vaults=$maxVaultCount, '
      'file=$maxFileSizeBytes, storage=$managedStorageQuotaBytes)';
}
