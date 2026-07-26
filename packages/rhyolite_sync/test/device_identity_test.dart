import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// A device's identity is what every head on the server is filed under, and a
// head does more than label a row: `min(headSeq)` across live devices is the
// gate for tombstone GC. So an install that comes back as a stranger does not
// merely clutter a list — it pins that minimum down and freezes collection for
// the whole stale window, on the client and on the server alike.
//
// The loss is invisible while the app runs (the id stays in memory) and only
// shows on the NEXT launch, which is why every case below reopens the store.
// ---------------------------------------------------------------------------

const _vaultId = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';

void main() {
  late InMemoryDataServiceEnvironment env;
  late IDataClient client;

  setUp(() async {
    env = await DataServiceFactory.inMemory();
    client = env.client;
  });

  tearDown(() async => env.dispose());

  /// Opens the store the way a fresh launch would.
  Future<FileStateStore> open({String? deviceId}) async {
    final store = FileStateStore(
      client: client,
      vaultId: _vaultId,
      deviceId: deviceId,
    );
    await store.load();
    return store;
  }

  group('identity owned by the database', () {
    test('survives a reset and the restart that follows', () async {
      final original = (await open()).deviceId;

      final store = await open();
      await store.wipeAll();

      expect(
        (await open()).deviceId,
        original,
        reason:
            'a reset must not make the server treat this install as a new '
            'device — that is how phantom heads accumulate',
      );
    });

    test('survives a wipe through a freshly constructed store', () async {
      final original = (await open()).deviceId;

      // How the engine actually wipes: a new instance that never loaded, so it
      // holds no id in memory to write back.
      await FileStateStore(client: client, vaultId: _vaultId).wipeAll();

      expect((await open()).deviceId, original);
    });

    test('is minted once and then reused', () async {
      final first = (await open()).deviceId;
      expect(first, isNotEmpty);
      expect((await open()).deviceId, first);
    });
  });

  group('identity supplied by the host', () {
    test('wins over whatever the database remembers', () async {
      await open(); // database mints one of its own

      final store = await open(deviceId: 'host-owned-id');

      expect(store.deviceId, 'host-owned-id');
      expect(
        (await open()).deviceId,
        'host-owned-id',
        reason:
            'the adopted id must be written back, or the two disagree '
            'again on the next launch',
      );
    });

    test('survives losing the database entirely', () async {
      // The case the host-owned id exists for: recovery from corruption, or a
      // reinstall, hands the engine a database it has never seen.
      final fresh = await DataServiceFactory.inMemory();
      addTearDown(fresh.dispose);
      final store = FileStateStore(
        client: fresh.client,
        vaultId: _vaultId,
        deviceId: 'host-owned-id',
      );
      await store.load();

      expect(store.deviceId, 'host-owned-id');
    });

    test('a wipe keeps it', () async {
      final store = await open(deviceId: 'host-owned-id');
      await store.wipeAll();

      expect((await open(deviceId: 'host-owned-id')).deviceId, 'host-owned-id');
    });

    test('the database keeps its own id when the host supplies none', () async {
      // Migration order matters: an existing install must be able to hand its
      // id UP to the host, not be given a new one.
      final existing = (await open()).deviceId;

      final store = await open();

      expect(store.deviceIdOrNull, existing);
    });
  });

  test('a wipe still resets the sync position', () async {
    final store = await open();
    store.setServerCursor(42);
    await store.persistMeta();

    await store.wipeAll();

    expect(
      (await open()).serverCursor,
      0,
      reason:
          'preserving identity must not preserve position — the point of '
          'a reset is to re-read everything',
    );
  });
}
