import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/sync_v3/causal_stability_gc.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_frontier.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_store.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_dart/rpc_dart.dart' show RpcContext;
import 'package:test/test.dart';

const _vault = 'vault-gc';

class _FakeHistory implements IHistoryContract {
  _FakeHistory(this.heads);
  final List<DeviceHead> heads;

  @override
  Future<GetHistoryHeadsResponse> getHistoryHeads(
    GetHistoryHeadsRequest req, {
    RpcContext? context,
  }) async =>
      GetHistoryHeadsResponse(heads: heads);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

DeviceHead _head(String id, String frontierPacked) => DeviceHead(
      deviceId: id,
      headSeq: 1,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      frontierPacked: frontierPacked,
    );

/// A head with an explicit pull cursor and optional age (for stale-device
/// tests). Used by the tombstone-GC group.
DeviceHead _headSeq(String id, int seq, {int ageMs = 0}) => DeviceHead(
      deviceId: id,
      headSeq: seq,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch - ageMs,
    );

/// Adds a single-value tombstone register for [fileId] to [store] and records
/// the server seq it was pulled at (unless [serverSeq] is null → "not yet
/// echoed back").
Future<void> _addTombstone(
  FileStateStore store,
  String fileId, {
  required int? serverSeq,
}) async {
  store.applyLocal(FileState(
    fileId: fileId,
    path: '$fileId.md',
    blobRef: '',
    sizeBytes: 0,
    hlc: store.nextHlc(),
    tombstone: true,
  ));
  await store.persistOne(fileId);
  if (serverSeq != null) store.recordServerSeq(fileId, serverSeq);
}

/// Builds a Fugue authored entirely by [replica]: type [text] then delete the
/// last [deleteFromEnd] characters (a fully-deleted run when it equals the
/// length). Counters run 1..text.length.
Fugue<String> _authored(String replica, String text, {int deleteFromEnd = 0}) {
  final clk = LamportClock(replica);
  final f = Fugue<String>();
  for (var i = 0; i < text.length; i++) {
    f.insert(i, text[i], clk.tick());
  }
  for (var i = 0; i < deleteFromEnd; i++) {
    f.delete(f.length - 1);
  }
  return f;
}

CausalStabilityGc _gc(
  FugueStore store,
  _FakeHistory history, {
  FileStateStore? fileStore,
  Duration tombstoneBackfillMinAge = const Duration(hours: 24),
}) =>
    CausalStabilityGc(
      vaultId: _vault,
      getFugueStore: () => store,
      getStore: () => fileStore,
      getHistoryCaller: () => history,
      onInfo: (_) {},
      onWarning: (_) {},
      minInterval: Duration.zero,
      tombstoneBackfillMinAge: tombstoneBackfillMinAge,
    );

void main() {
  group('CausalStabilityGc', () {
    test('single device prunes a fully-tombstoned, stable file to empty',
        () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = FugueStore(client: env.client, vaultId: _vault);
      await store.load();

      // 'abc' authored by devA (counters 1,2,3), then all deleted.
      store.set('f1', _authored('devA', 'abc', deleteFromEnd: 3));
      await store.persistOne('f1');
      expect((await store.get('f1'))!.elementCount, 3);

      // devA reports it has observed its own dots up to counter 3.
      final history = _FakeHistory([
        _head('devA', FugueFrontier.pack({'devA': 3})),
      ]);
      await _gc(store, history).run();

      expect((await store.get('f1'))!.elementCount, 0,
          reason: 'a fully-deleted, all-stable block must be pruned');
    });

    test('a partially-live file is retained (has a live element)', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = FugueStore(client: env.client, vaultId: _vault);
      await store.load();

      // 'abc' with only the last char deleted → 'ab' still live.
      store.set('f1', _authored('devA', 'abc', deleteFromEnd: 1));
      await store.persistOne('f1');
      final before = (await store.get('f1'))!.elementCount;

      final history = _FakeHistory([
        _head('devA', FugueFrontier.pack({'devA': 3})),
      ]);
      await _gc(store, history).run();

      expect((await store.get('f1'))!.elementCount, before,
          reason: 'a block with a live element is never dropped');
      expect((await store.get('f1'))!.values.join(), 'ab');
    });

    test('an unrecognised (old-format) frontier prunes nothing', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = FugueStore(client: env.client, vaultId: _vault);
      await store.load();

      store.set('f1', _authored('devA', 'abc', deleteFromEnd: 3));
      await store.persistOne('f1');

      // An HLC-format frontier from a not-yet-upgraded peer — unparseable.
      final history = _FakeHistory([
        _head('devA', 'devA:100-3-devA'),
      ]);
      await _gc(store, history).run();

      expect((await store.get('f1'))!.elementCount, 3,
          reason: 'fail-safe: an unknown frontier must never prune');
    });

    test('two devices reporting different replicas prune nothing (conservative)',
        () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = FugueStore(client: env.client, vaultId: _vault);
      await store.load();

      store.set('f1', _authored('devA', 'abc', deleteFromEnd: 3));
      await store.persistOne('f1');

      // devA confirms devA's dots, but devB only reports its OWN replica.
      // The intersection of reported replicas is empty → no boundary.
      final history = _FakeHistory([
        _head('devA', FugueFrontier.pack({'devA': 3})),
        _head('devB', FugueFrontier.pack({'devB': 7})),
      ]);
      await _gc(store, history).run();

      expect((await store.get('f1'))!.elementCount, 3,
          reason: 'without cross-device confirmation of devA, nothing prunes');
    });
  });

  group('CausalStabilityGc — FileState tombstone pruning', () {
    Future<(FugueStore, FileStateStore)> build(dynamic env) async {
      final fugue = FugueStore(client: env.client, vaultId: _vault);
      await fugue.load();
      final store = FileStateStore(client: env.client, vaultId: _vault);
      await store.load();
      return (fugue, store);
    }

    test('a tombstone stable across all active devices is reclaimed', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final (fugue, store) = await build(env);
      await _addTombstone(store, 'f1', serverSeq: 5);

      // Every active device has pulled past seq 5.
      final history = _FakeHistory([_headSeq('devA', 10)]);
      await _gc(fugue, history, fileStore: store).run();

      expect(store.contains('f1'), isFalse,
          reason: 'a delete every device has seen is reclaimed');
    });

    test('a tombstone a lagging device has not seen is retained (no '
        'resurrection)', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final (fugue, store) = await build(env);
      await _addTombstone(store, 'f1', serverSeq: 20);

      // devB has only pulled up to seq 5 → minSafeHead=5 < 20.
      final history = _FakeHistory([_headSeq('devA', 100), _headSeq('devB', 5)]);
      await _gc(fugue, history, fileStore: store).run();

      expect(store.contains('f1'), isTrue,
          reason: 'must NOT reclaim a delete a peer has not pulled yet — '
              'else the file resurrects on that peer');
    });

    test('a fresh tombstone with no known serverSeq is retained (not '
        'backfilled)', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final (fugue, store) = await build(env);
      // Locally-created delete not yet echoed back — HLC is "now", younger than
      // the backfill min-age, so its unknown seq must NOT be backfilled.
      await _addTombstone(store, 'f1', serverSeq: null);

      final history = _FakeHistory([_headSeq('devA', 100)]);
      await _gc(fugue, history, fileStore: store).run();

      expect(store.contains('f1'), isTrue,
          reason: 'a just-created delete not yet echoed back must not be '
              'reclaimed from a cursor guess (could resurrect on a peer)');
    });

    test('an old tombstone with no known serverSeq is backfilled and reclaimed '
        '(pre-fix backlog)', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final (fugue, store) = await build(env);
      store.setServerCursor(7); // this device has pulled up to seq 7
      await _addTombstone(store, 'f1', serverSeq: null);

      // backfillMinAge = 0 → the tombstone is treated as old backlog: its
      // unknown seq is backfilled with serverCursor (7), a safe upper bound.
      // Every active device has passed 7 → reclaimed.
      final history = _FakeHistory([_headSeq('devA', 10)]);
      await _gc(fugue, history,
              fileStore: store, tombstoneBackfillMinAge: Duration.zero)
          .run();

      expect(store.contains('f1'), isFalse,
          reason: 'the pre-fix backlog is reclaimed via a safe cursor backfill');
    });

    test('a tombstone is reclaimed once the lagging device catches up',
        () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final (fugue, store) = await build(env);
      await _addTombstone(store, 'f1', serverSeq: 5);

      await _gc(fugue,
              _FakeHistory([_headSeq('devA', 100), _headSeq('devB', 3)]),
              fileStore: store)
          .run();
      expect(store.contains('f1'), isTrue, reason: 'held while devB lags');

      await _gc(fugue,
              _FakeHistory([_headSeq('devA', 100), _headSeq('devB', 50)]),
              fileStore: store)
          .run();
      expect(store.contains('f1'), isFalse,
          reason: 'once every device passes seq 5, the delete is reclaimed');
    });

    test('a long-offline (stale) device does not block GC', () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final (fugue, store) = await build(env);
      await _addTombstone(store, 'f1', serverSeq: 5);

      // devB lags (seq 3) but is stale (>90d) → excluded from the boundary.
      final history = _FakeHistory([
        _headSeq('devA', 100),
        _headSeq('devB', 3, ageMs: const Duration(days: 120).inMilliseconds),
      ]);
      await _gc(fugue, history, fileStore: store).run();

      expect(store.contains('f1'), isFalse,
          reason: 'a stale device must not block GC forever (same trade-off as '
              'the Fugue frontier)');
    });

    test('a reclaimed tombstone stays gone after a store reload (row deleted)',
        () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final (fugue, store) = await build(env);
      await _addTombstone(store, 'f1', serverSeq: 5);
      await store.persistMeta();

      await _gc(fugue, _FakeHistory([_headSeq('devA', 10)]), fileStore: store)
          .run();
      expect(store.contains('f1'), isFalse);

      // A fresh store from the same backing client must not see the row.
      final reloaded = FileStateStore(client: env.client, vaultId: _vault);
      await reloaded.load();
      expect(reloaded.contains('f1'), isFalse,
          reason: 'the SQLite row + serverSeq entry are durably removed');
    });
  });
}
