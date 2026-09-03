import 'dart:typed_data';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_core/rhyolite_core.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_store.dart';
import 'package:rhyolite_sync/src/storage/fm_store.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

// Hex, not a mnemonic: `fm` reads nicely but is not a UUID, and a real vaultId
// is a v4 that other layers feed to `uuid.v5` as a NAMESPACE (see
// SettingsSync._fileIdFor, deterministicFileId). FmStore only uses it as a
// collection-name prefix, so the bad value never surfaced here — it would have
// thrown the moment this test grew to touch an id-deriving path.
const _vaultId = '00000000-0000-4000-8000-0000000000fa';

int _wall = 9000;
Hlc at(String node) => Hlc(++_wall, 0, node);

FmState build(String region) => applyDiskFrontmatter(
  FmMapState(
    entries: const {},
    fmHlc: at('device-a'),
    trailHlc: at('device-a'),
  ),
  parseFrontmatterRegion(region),
  at('device-a'),
);

String show(FmState s) => renderRegion(materializeFm(s));

Future<({FmStore store, IDataClient client})> fixture() async {
  final env = await DataServiceFactory.inMemory();
  addTearDown(env.dispose);
  final store = FmStore(client: env.client, vaultId: _vaultId);
  await store.load();
  return (store: store, client: env.client);
}

void main() {
  test('persists and reads back', () async {
    final f = await fixture();
    final state = build('title: Note\ntags:\n  - work\n');

    f.store.set('file-1', state);
    await f.store.persistOne('file-1');

    // A fresh store over the same client — as a restart would see it.
    final reopened = FmStore(client: f.client, vaultId: _vaultId);
    await reopened.load();
    expect(show((await reopened.get('file-1'))!), show(state));
  });

  test(
    'persisting the same file twice overwrites rather than failing',
    () async {
      // A plain create throws on the second write; the store has to
      // create-or-update. Every edit of a note takes this path.
      final f = await fixture();
      f.store.set('file-1', build('x: 1\n'));
      await f.store.persistOne('file-1');

      final second = build('x: 2\n');
      f.store.set('file-1', second);
      await f.store.persistOne('file-1');

      final reopened = FmStore(client: f.client, vaultId: _vaultId);
      await reopened.load();
      expect(show((await reopened.get('file-1'))!), show(second));
    },
  );

  test('an unknown file is null, not an error', () async {
    final f = await fixture();
    expect(await f.store.get('never-seen'), isNull);
  });

  test('remove drops it from memory and from disk', () async {
    final f = await fixture();
    f.store.set('file-1', build('x: 1\n'));
    await f.store.persistOne('file-1');
    await f.store.remove('file-1');

    final reopened = FmStore(client: f.client, vaultId: _vaultId);
    await reopened.load();
    expect(await reopened.get('file-1'), isNull);
  });

  test(
    'a row this build cannot decode reads as absent, never as garbage',
    () async {
      // Written by a newer client, or bit-rotted. Null means "no prior state",
      // which makes the caller rebuild from the blob — the correct recovery,
      // since the blob is authoritative and this is only a cache.
      final f = await fixture();
      await f.client.create(
        collection: '${_vaultId}_fm_store',
        id: 'file-1',
        payload: {
          'fm': Uint8List.fromList([0xFF, 0xFF, 0xFF]),
        },
      );
      final store = FmStore(client: f.client, vaultId: _vaultId);
      await store.load();
      expect(await store.get('file-1'), isNull);
    },
  );

  test('losing the store loses nothing: the blob rebuilds it', () async {
    // The property that makes a local wipe survivable — db_recovery in the
    // plugin, or the engine reset. Worth a test because the spec assumed it
    // without saying so.
    final f = await fixture();
    final state = build('title: Note\ntags:\n  - work\n');
    final blob = appendFmTail(
      FugueStore.encodeBlob(seedFugueText('body\n')),
      state,
    );

    f.store.set('file-1', state);
    await f.store.persistOne('file-1');
    await f.store.wipeAll();

    final afterWipe = FmStore(client: f.client, vaultId: _vaultId);
    await afterWipe.load();
    expect(await afterWipe.get('file-1'), isNull, reason: 'the cache is gone');

    final rebuilt = readFmTail(blob)!;
    expect(show(rebuilt), show(state));
  });

  test('the LRU evicts without losing what was persisted', () async {
    final f = await fixture();
    final store = FmStore(client: f.client, vaultId: _vaultId, cacheMax: 2);
    await store.load();

    for (var i = 0; i < 5; i++) {
      store.set('file-$i', build('x: $i\n'));
      await store.persistOne('file-$i');
    }
    expect(store.stats().cached, lessThanOrEqualTo(2));
    expect(store.stats().files, 5);

    // Evicted entries come back from disk unchanged.
    expect(show((await store.get('file-0'))!), show(build('x: 0\n')));
  });
}
