import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart' show RpcContext;
import 'package:test/test.dart';

class _FakeHistory implements IHistoryContract {
  _FakeHistory(this._heads);
  final List<DeviceHead> _heads;
  final forgotten = <String>[];

  @override
  Future<GetHistoryHeadsResponse> getHistoryHeads(
    GetHistoryHeadsRequest req, {
    RpcContext? context,
  }) async =>
      GetHistoryHeadsResponse(heads: _heads);

  @override
  Future<ForgetDeviceResponse> forgetDevice(
    ForgetDeviceRequest req, {
    RpcContext? context,
  }) async {
    forgotten.add(req.deviceId);
    return const ForgetDeviceResponse(removed: true);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

DeviceHead _head(String id, int seq, int ageMs, {String name = ''}) => DeviceHead(
      deviceId: id,
      headSeq: seq,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch - ageMs,
      deviceName: name,
    );

void main() {
  test('maps heads: name fallback, behind-by, this-device, newest-first', () async {
    final fake = _FakeHistory([
      _head('aaaaaaaa-1111', 100, 5000, name: 'Obsidian/desktop'), // ahead
      _head('bbbbbbbb-2222', 40, 1000), // no name → short-id, behind by 60
      _head('cccccccc-3333', 90, 9000, name: 'Obsidian/mobile'),
    ]);
    final reg = DeviceRegistryUseCase(
      historyCaller: fake,
      vaultId: 'v1',
      thisDeviceId: 'bbbbbbbb-2222',
    );

    final devices = await reg();

    // Sorted newest-seen first: b (1s) , a (5s), c (9s).
    expect(devices.map((d) => d.deviceId),
        ['bbbbbbbb-2222', 'aaaaaaaa-1111', 'cccccccc-3333']);

    final b = devices.firstWhere((d) => d.deviceId == 'bbbbbbbb-2222');
    expect(b.isCurrent, isTrue);
    expect(b.name, 'Device bbbbbbbb'); // short-id fallback (no reported name)
    expect(b.behindBySeq, 60); // maxHead(100) - 40

    final a = devices.firstWhere((d) => d.deviceId == 'aaaaaaaa-1111');
    expect(a.isCurrent, isFalse);
    expect(a.name, 'Obsidian/desktop');
    expect(a.behindBySeq, 0); // furthest ahead
  });

  test('forget delegates to the contract and returns removed', () async {
    final fake = _FakeHistory([]);
    final reg = DeviceRegistryUseCase(
      historyCaller: fake,
      vaultId: 'v1',
      thisDeviceId: 'self',
    );
    final ok = await reg.forget('dead-device');
    expect(ok, isTrue);
    expect(fake.forgotten, ['dead-device']);
  });
}
