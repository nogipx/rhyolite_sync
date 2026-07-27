/// Why plugin-code sync is or is not available for this session.
enum PluginCodeAvailability {
  /// The storage backing this vault can hold a plugin set.
  allowed,

  /// Managed storage with a quota too small for plugin code. Not a licence
  /// check — the same user is allowed the moment they attach their own storage
  /// or move to a larger managed quota.
  quotaTooSmall,

  /// No plan capabilities yet (pre-fetch, or the subscription lookup timed
  /// out). Fails closed: better a delayed feature than a half-uploaded plugin
  /// set that the server's quota interceptor rejects mid-transfer.
  unknownQuota,
}

/// Managed quota below which plugin code is not offered.
///
/// A normal community-plugin set is tens to hundreds of megabytes, so on the
/// 50 MB free quota the very first sync would blow through it — and would do so
/// *mid-upload*, on the server's blob-quota interceptor, which reads as "sync
/// is broken" rather than "this needs more storage". Sitting between the free
/// and paid quotas, this threshold expresses the actual constraint (headroom)
/// instead of hard-coding a plan name, so it keeps working if the tiers change.
const int kMinManagedQuotaForPluginCode = 256 * 1024 * 1024;

/// Decides whether this session may sync community-plugin code.
///
/// [selfHost] and [externalStorage] (bring-your-own S3/WebDAV) both mean the
/// bytes never touch managed storage, so there is nothing to gate: the user is
/// spending their own capacity.
PluginCodeAvailability pluginCodeAvailability({
  required bool selfHost,
  required bool externalStorage,
  required int? managedStorageQuotaBytes,
}) {
  if (selfHost || externalStorage) return PluginCodeAvailability.allowed;
  final quota = managedStorageQuotaBytes;
  if (quota == null) return PluginCodeAvailability.unknownQuota;
  // A zero/absent quota is how a denied capability set is expressed; treat it
  // as too small rather than as "unlimited".
  if (quota < kMinManagedQuotaForPluginCode) {
    return PluginCodeAvailability.quotaTooSmall;
  }
  return PluginCodeAvailability.allowed;
}
