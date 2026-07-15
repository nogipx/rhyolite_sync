import '../contract/history_contract.dart';

/// A device that has synced this vault, as shown in the device-management UI.
class SyncDevice {
  const SyncDevice({
    required this.deviceId,
    required this.name,
    required this.headSeq,
    required this.lastSeen,
    required this.behindBySeq,
    required this.isCurrent,
    this.clientVersion = '',
    this.clientKind = '',
  });

  final String deviceId;

  /// Human label the device reported, or a short id fallback.
  final String name;

  /// Client version the device reported (e.g. "3.4.3"), or '' if unknown.
  final String clientVersion;

  /// Client kind the device reported (`obsidian` / `cli` / …), or '' if unknown.
  final String clientKind;

  /// Highest history serverSeq this device has processed.
  final int headSeq;

  /// When the device last reported its head.
  final DateTime lastSeen;

  /// How far this device trails the furthest-ahead device (in serverSeq).
  /// A large value on an old [lastSeen] is what pins cleanup.
  final int behindBySeq;

  /// True for the device running this session.
  final bool isCurrent;
}

/// Lists the devices syncing a vault and lets the user forget a stale one.
/// Callable: `await DeviceRegistryUseCase(...)()` returns the device list.
///
/// Forgetting a device drops its server-side head so it stops holding back
/// history cleanup; nothing here deletes vault content. A forgotten device
/// that later reconnects simply reports a fresh head.
class DeviceRegistryUseCase {
  DeviceRegistryUseCase({
    required this.historyCaller,
    required this.vaultId,
    required this.thisDeviceId,
  });

  final IHistoryContract historyCaller;
  final String vaultId;
  final String thisDeviceId;

  Future<List<SyncDevice>> call() async {
    final resp =
        await historyCaller.getHistoryHeads(GetHistoryHeadsRequest(vaultId: vaultId));
    final heads = resp.heads;
    final maxHead =
        heads.fold<int>(0, (m, h) => h.headSeq > m ? h.headSeq : m);
    final out = heads
        .map((h) => SyncDevice(
              deviceId: h.deviceId,
              name: h.deviceName.isNotEmpty ? h.deviceName : _shortId(h.deviceId),
              headSeq: h.headSeq,
              lastSeen: DateTime.fromMillisecondsSinceEpoch(h.updatedAtMs),
              behindBySeq:
                  (maxHead - h.headSeq) < 0 ? 0 : (maxHead - h.headSeq),
              isCurrent: h.deviceId == thisDeviceId,
              clientVersion: h.clientVersion,
              clientKind: h.clientKind,
            ))
        .toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    return out;
  }

  /// Removes [deviceId]'s head record. Returns true when a record was removed.
  Future<bool> forget(String deviceId) async {
    final r = await historyCaller
        .forgetDevice(ForgetDeviceRequest(vaultId: vaultId, deviceId: deviceId));
    return r.removed;
  }

  static String _shortId(String id) =>
      id.length <= 8 ? id : 'Device ${id.substring(0, 8)}';
}
