// H4 — The pull hold-cursor holds AND releases correctly (positive-invariant
// confirmation; higher cost of error than the negative hypotheses).
//
// state_puller_test.dart already covers two of the three cases the review asks
// for:
//   * one failing file holds the cursor below it            -> COVERED there
//   * a persistent failure is skipped past after the cap    -> COVERED there
//     (with SyncRecordSkipped surfaced; the streak counter is cleared)
//
// This file adds the two that were NOT covered:
//   Test A: strengthens "hold" by asserting the HEALTHY records after the
//           failed one still applied (only the cursor is held).
//   Test B: the regression — two failing files with interleaved seqs must hold
//           the cursor under the GLOBAL MINIMUM failed seq, not the last one,
//           or some failed records would be skipped forever.
import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/sync_v3/state_puller.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

const _vaultId = '00000000-0000-4000-8000-0000000000a4';

// pull() logs fileId.substring(0, 8), so ids must be >= 8 chars.
String _id(String tag) => 'file-$tag';

class _FakeStateCaller implements IStateSyncContract {
  _FakeStateCaller(this.dataset);
  final List<StateRecord> dataset;

  @override
  Future<StateGetResponse> getStates(
    StateGetRequest request, {
    RpcContext? context,
  }) async {
    final records = dataset
        .where((r) => r.serverSeq > request.sinceCursor)
        .toList(growable: false);
    final maxSeq =
        dataset.fold<int>(0, (m, r) => r.serverSeq > m ? r.serverSeq : m);
    return StateGetResponse(records: records, cursor: maxSeq, epoch: 0);
  }

  @override
  Future<StatePutResponse> putStates(StatePutRequest request,
          {RpcContext? context}) =>
      throw UnimplementedError();
  @override
  Future<StateWipeResponse> wipeVault(StateWipeRequest request,
          {RpcContext? context}) =>
      throw UnimplementedError();
  @override
  Future<StatePurgeResponse> purgeVault(StatePurgeRequest request,
          {RpcContext? context}) =>
      throw UnimplementedError();
}

class _FakeHistoryCaller implements IHistoryContract {
  @override
  Future<ReportHistoryHeadResponse> reportHistoryHead(
          ReportHistoryHeadRequest request, {RpcContext? context}) async =>
      const ReportHistoryHeadResponse();
  @override
  Future<HistoryGetResponse> getHistory(HistoryGetRequest request,
          {RpcContext? context}) =>
      throw UnimplementedError();
  @override
  Future<HistoryDeleteEventsResponse> deleteEvents(
          HistoryDeleteEventsRequest request, {RpcContext? context}) =>
      throw UnimplementedError();
  @override
  Future<GetHistoryHeadsResponse> getHistoryHeads(GetHistoryHeadsRequest request,
          {RpcContext? context}) =>
      throw UnimplementedError();
  @override
  Future<ForgetDeviceResponse> forgetDevice(ForgetDeviceRequest request,
          {RpcContext? context}) =>
      throw UnimplementedError();
}

class _NoConflictResolver implements IStateConflictResolver {
  @override
  Future<StateMergeOutcome> resolve(List<FileState> values, {String? baseRef}) =>
      throw UnimplementedError();
}

StateRecord _rec(String fileId, int seq) => StateRecord(
      fileId: fileId,
      encryptedState: '',
      blobRef: '',
      hlcPacked: Hlc(seq, 0, 'device-$fileId-$seq').pack(),
      contextPacked: '',
      serverSeq: seq,
      tombstone: false,
    );

typedef _Fx = ({
  StatePuller puller,
  FileStateStore store,
  List<String> applied,
  List<SyncEngineEvent> events,
});

/// [failFor] returns true for fileIds whose apply must throw.
Future<_Fx> _newPuller(
  List<StateRecord> dataset, {
  required bool Function(String fileId) failFor,
}) async {
  final env = await DataServiceFactory.inMemory();
  addTearDown(env.dispose);
  final store = FileStateStore(client: env.client, vaultId: _vaultId);
  await store.load();
  final applied = <String>[];
  final events = <SyncEngineEvent>[];

  final puller = StatePuller(
    stateCaller: _FakeStateCaller(dataset),
    historyCaller: _FakeHistoryCaller(),
    store: store,
    blobStore: LocalBlobStore(InMemoryBlobRepository()),
    vaultId: _vaultId,
    rpcTimeout: const Duration(seconds: 5),
    getRemoteBlobStorage: () => null,
    newResolver: () => _NoConflictResolver(),
    applyFile: (fileId, records, resolver) async {
      if (failFor(fileId)) throw StateError('boom for $fileId');
      applied.add(fileId);
    },
    handleEpochMismatch: (_) async {},
    emit: events.add,
    isFatalRejection: (_) => false,
    log: LogScope.noop,
  );

  return (puller: puller, store: store, applied: applied, events: events);
}

void main() {
  group('H4 — hold-cursor holds AND releases', () {
    test(
      'a failed file holds the cursor below it, yet every healthy record '
      '(including those AFTER it) still applies',
      () async {
        // Healthy 1-4, X fails at 5, healthy 6-10. Two batches (size 8).
        final x = _id('xxxx-05');
        final dataset = <StateRecord>[
          _rec(_id('aaaa-01'), 1),
          _rec(_id('bbbb-02'), 2),
          _rec(_id('cccc-03'), 3),
          _rec(_id('dddd-04'), 4),
          _rec(x, 5),
          _rec(_id('ffff-06'), 6),
          _rec(_id('gggg-07'), 7),
          _rec(_id('hhhh-08'), 8),
          _rec(_id('iiii-09'), 9),
          _rec(_id('jjjj-10'), 10),
        ];
        final f = await _newPuller(dataset, failFor: (id) => id == x);

        await f.puller.pull();

        expect(f.store.serverCursor, 4,
            reason: 'cursor held at X.seq-1 (5-1=4), never advanced past X');
        // Every non-failing file applied — including the ones sequenced AFTER
        // the failure, so a single bad file does not stall the whole batch.
        final healthy = dataset
            .map((r) => r.fileId)
            .where((id) => id != x)
            .toSet();
        expect(f.applied.toSet(), containsAll(healthy),
            reason: 'records 6..10 must still apply; only the cursor is held');
        expect(f.applied, isNot(contains(x)));
      },
    );

    test(
      'two failing files with interleaved seqs hold the cursor under the '
      'GLOBAL MINIMUM failed seq, not the last',
      () async {
        // B fails at seqs {2, 6}; D fails at seqs {4, 5}. Global min failed
        // seq = 2, so the cursor must hold at 1. A "hold under the last file"
        // bug would land at 3 (D-min-1) or 5 (B-max-1) instead.
        final b = _id('bbbb-bb');
        final d = _id('dddd-dd');
        final dataset = <StateRecord>[
          _rec(_id('aaaa-01'), 1),
          _rec(b, 2),
          _rec(_id('cccc-03'), 3),
          _rec(d, 4),
          _rec(d, 5),
          _rec(b, 6),
          _rec(_id('eeee-07'), 7),
        ];
        final f = await _newPuller(dataset, failFor: (id) => id == b || id == d);

        await f.puller.pull();

        expect(f.store.serverCursor, 1,
            reason: 'must hold at min(failed seqs)-1 = 2-1 = 1 so BOTH B and D '
                'are re-fetched on the next pull; a per-file hold would strand '
                'the lower-seq failures');
        // The healthy files still applied.
        expect(f.applied,
            containsAll(<String>[_id('aaaa-01'), _id('cccc-03'), _id('eeee-07')]));
      },
    );
  });
}
