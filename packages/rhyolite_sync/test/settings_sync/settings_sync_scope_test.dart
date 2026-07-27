import 'package:rhyolite_sync/src/settings_sync/settings_store.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

/// The pull cursor is only meaningful relative to the scope it was advanced
/// under, so the store has to remember which scope that was.
void main() {
  late IDataClient client;

  setUp(() async {
    final env = await DataServiceFactory.inMemory();
    addTearDown(env.dispose);
    client = env.client;
  });

  Future<SettingsStore> open() async {
    final store = SettingsStore(client: client, vaultId: 'v1');
    await store.load();
    return store;
  }

  test('scope survives a reopen alongside the cursor', () async {
    final first = await open();
    first
      ..cursor = 42
      ..scope = 'appearance,hotkeys';
    await first.persistMeta();

    final second = await open();
    expect(second.scope, 'appearance,hotkeys');
    expect(second.cursor, 42);
  });

  test('a fresh store has no scope, so any scope is a change', () async {
    final store = await open();
    expect(store.scope, isNull);
  });

  test('wipeAll resets the cursor and keeps the device identity', () async {
    final store = await open();
    store
      ..cursor = 99
      ..scope = 'a';
    await store.persistMeta();
    final deviceId = store.deviceId;

    await store.wipeAll();
    expect(store.cursor, 0);
    expect(store.deviceId, deviceId);
  });
}
