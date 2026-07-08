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

CausalStabilityGc _gc(FugueStore store, _FakeHistory history) => CausalStabilityGc(
      vaultId: _vault,
      getFugueStore: () => store,
      getHistoryCaller: () => history,
      onInfo: (_) {},
      onWarning: (_) {},
      minInterval: Duration.zero,
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
}
