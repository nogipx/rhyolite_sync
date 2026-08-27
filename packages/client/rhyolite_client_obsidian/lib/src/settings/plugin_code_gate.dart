import 'obsidian_settings_registry.dart';

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

/// Categories this session may sync down but must not push up, given the user's
/// selection [enabled] and the storage gate's verdict.
///
/// The gate answers one question — may this device spend managed storage — and
/// it is expressed HERE, not by editing [enabled]. That set is also the sync
/// scope: it decides which records the settings store keeps, and it is hashed
/// into the pull cursor's scope token. Narrowing it purges the local CRDT state
/// for the dropped resources and invalidates the cursor, so an `unknownQuota`
/// from a subscription lookup that merely timed out cost a full re-download of
/// the plugin set the moment the lookup succeeded again. Scope follows the
/// user's toggles; availability follows the plan; the two never trade places.
///
/// Downloads stay on under every verdict: the bytes a pull brings down are
/// already stored on the server and cost the quota nothing, and a device that
/// cannot deliver its own plugins can still receive the vault's.
Set<SettingsCategory> pluginCodePullOnly({
  required Set<SettingsCategory> enabled,
  required PluginCodeAvailability availability,
}) {
  if (!enabled.contains(SettingsCategory.communityPluginCode)) return const {};
  if (availability == PluginCodeAvailability.allowed) return const {};
  return const {SettingsCategory.communityPluginCode};
}
