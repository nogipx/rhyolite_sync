import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/sync_v3/state_puller.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

const _vaultId = '00000000-0000-4000-8000-000000000001';

// Real pull() logs `fileId.substring(0, 8)`, so ids must be >= 8 chars.
const _idA = 'file-aaaa';
const _idB = 'file-bbbb';
const _idC = 'file-cccc';

/// Serves records with serverSeq strictly greater than [sinceCursor] from a
/// fixed dataset, as the real server would. Cursor is the dataset's max seq.
class _FakeStateCaller implements IStateSyncContract {
  _FakeStateCaller(this.dataset);

  final List<StateRecord> dataset;
  int getStatesCalls = 0;

  @override
  Future<StateGetResponse> getStates(
    StateGetRequest request, {
    RpcContext? context,
  }) async {
    getStatesCalls += 1;
    final records = dataset
        .where((r) => r.serverSeq > request.sinceCursor)
        .toList(growable: false);
    final maxSeq = dataset.fold<int>(0, (m, r) => r.serverSeq > m ? r.serverSeq : m);
    return StateGetResponse(records: records, cursor: maxSeq, epoch: 0);
  }

  @override
  Future<StatePutResponse> putStates(StatePutRequest request, {RpcContext? context}) =>
      throw UnimplementedError();

  @override
  Future<StateWipeResponse> wipeVault(StateWipeRequest request, {RpcContext? context}) =>
      throw UnimplementedError();
  @override
  Future<StatePurgeResponse> purgeVault(StatePurgeRequest request, {RpcContext? context}) =>
      throw UnimplementedError();
}

class _FakeHistoryCaller implements IHistoryContract {
  int headReports = 0;
  int? lastHead;

  @override
  Future<ReportHistoryHeadResponse> reportHistoryHead(
    ReportHistoryHeadRequest request, {
    RpcContext? context,
  }) async {
    headReports += 1;
    lastHead = request.headSeq;
    return const ReportHistoryHeadResponse();
  }

  @override
  Future<HistoryGetResponse> getHistory(HistoryGetRequest request, {RpcContext? context}) =>
      throw UnimplementedError();
  @override
  Future<HistoryDeleteEventsResponse> deleteEvents(HistoryDeleteEventsRequest request, {RpcContext? context}) =>
      throw UnimplementedError();
  @override
  Future<GetHistoryHeadsResponse> getHistoryHeads(GetHistoryHeadsRequest request, {RpcContext? context}) =>
      throw UnimplementedError();
  @override
  Future<ForgetDeviceResponse> forgetDevice(ForgetDeviceRequest request, {RpcContext? context}) =>
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
      hlcPacked: Hlc(seq, 0, 'device-$fileId').pack(),
      contextPacked: '',
      serverSeq: seq,
      tombstone: false,
    );

typedef _Fx = ({
  StatePuller puller,
  FileStateStore store,
  _FakeStateCaller caller,
  _FakeHistoryCaller history,
  List<SyncEngineEvent> events,
});

/// [failFor] receives each fileId as it is applied and returns true to make
/// that apply throw (simulating a transient/permanent per-file failure).
Future<_Fx> _newPuller(
  List<StateRecord> dataset, {
  required bool Function(String fileId) failFor,
  // When it returns non-null for a fileId, that apply throws the returned
  // object instead of the default StateError — used to inject an
  // RpcCancelledException (what an in-flight blob download raises on preempt).
  Object? Function(String fileId)? errorFor,
}) async {
  final env = await DataServiceFactory.inMemory();
  addTearDown(env.dispose);
  final store = FileStateStore(client: env.client, vaultId: _vaultId);
  await store.load();
  final blobStore = LocalBlobStore(InMemoryBlobRepository());
  final caller = _FakeStateCaller(dataset);
  final history = _FakeHistoryCaller();
  final events = <SyncEngineEvent>[];

  final puller = StatePuller(
    stateCaller: caller,
    historyCaller: history,
    store: store,
    blobStore: blobStore,
    vaultId: _vaultId,
    rpcTimeout: const Duration(seconds: 5),
    getRemoteBlobStorage: () => null,
    newResolver: () => _NoConflictResolver(),
    applyFile: (fileId, records, resolver, {context}) async {
      final custom = errorFor?.call(fileId);
      if (custom != null) throw custom;
      if (failFor(fileId)) throw StateError('boom for $fileId');
    },
    handleEpochMismatch: (_) async {},
    emit: events.add,
    isFatalRejection: (_) => false,
    log: LogScope.noop,
  );

  return (puller: puller, store: store, caller: caller, history: history, events: events);
}

void main() {
  group('StatePuller — pull persists meta at its convergence point (L1-4)', () {
    test('cursor + recorded LCA survive a crash before the next push',
        () async {
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = FileStateStore(client: env.client, vaultId: _vaultId);
      await store.load();
      final blobStore = LocalBlobStore(InMemoryBlobRepository());
      final events = <SyncEngineEvent>[];

      final puller = StatePuller(
        stateCaller: _FakeStateCaller([_rec(_idA, 1), _rec(_idB, 2)]),
        historyCaller: _FakeHistoryCaller(),
        store: store,
        blobStore: blobStore,
        vaultId: _vaultId,
        rpcTimeout: const Duration(seconds: 5),
        getRemoteBlobStorage: () => null,
        newResolver: () => _NoConflictResolver(),
        // A successful apply records a synced LCA for the file — exactly the
        // in-memory-only state that a crash used to lose.
        applyFile: (fileId, records, resolver, {context}) async {
          store.recordSyncedBlobRef(fileId, 'lca-$fileId');
        },
        handleEpochMismatch: (_) async {},
        emit: events.add,
        isFatalRejection: (_) => false,
        log: LogScope.noop,
      );

      await puller.pull();
      expect(store.serverCursor, 2);

      // Simulate a crash before any push: a fresh store reloading from the
      // same backing client sees only what pull() durably persisted. The
      // register rows are persisted per-file (persistOne); the meta row
      // (cursor, ownContext, lastSyncedBlobRef) was previously only written
      // by a later push, so a crash here desynced persisted registers from
      // stale meta.
      final reloaded = FileStateStore(client: env.client, vaultId: _vaultId);
      await reloaded.load();

      expect(reloaded.serverCursor, 2,
          reason: 'cursor must be durable right after the pull, not only '
              'after a later push (else we re-pull the whole batch)');
      // Note: for Fugue text the LCA is vestigial (join is conflict-free).
      // It is the base for the binary/LWW resolver (conflict-vs-fast-forward
      // and its defensive content 3-way merge), and it must not silently
      // roll back to a stale value across a crash.
      expect(reloaded.lastSyncedBlobRefFor(_idA), 'lca-$_idA',
          reason: 'lastSyncedBlobRef recorded during pull must survive a '
              'crash — it is the binary resolver base');
    });
  });

  group('StatePuller — failed apply holds the cursor, never silent-skips (L1-3)',
      () {
    test('one failing file holds the cursor below it so a later pull retries',
        () async {
      // A(1) ok, B(2) fails, C(3) ok. cursor high-watermark = 3.
      final f = await _newPuller(
        [_rec(_idA, 1), _rec(_idB, 2), _rec(_idC, 3)],
        failFor: (id) => id == _idB,
      );

      await f.puller.pull();

      expect(
        f.store.serverCursor,
        1,
        reason:
            'cursor must be held at B.seq-1 (1), not advanced to 3 — otherwise '
            'getStates never re-emits B and it is skipped forever',
      );
    });

    test('a persistently failing file is skipped past after the attempt cap',
        () async {
      final f = await _newPuller(
        [_rec(_idA, 1), _rec(_idB, 2), _rec(_idC, 3)],
        failFor: (id) => id == _idB,
      );

      // Pull repeatedly; each pull re-fetches from the held cursor and
      // retries B. After the cap it gives up and advances past B.
      for (var i = 0; i < 5; i++) {
        await f.puller.pull();
      }

      expect(f.store.serverCursor, 3,
          reason: 'after the retry cap the cursor advances past the bad file');
      final skipped = f.events.whereType<SyncRecordSkipped>().toList();
      expect(skipped, isNotEmpty,
          reason: 'giving up must surface a durable skip, not vanish silently');
      expect(skipped.map((e) => e.fileId), contains(_idB));
    });

    test('a transient failure recovers within the same pull (no extra sync)',
        () async {
      // Fail B on its first apply, succeed on the in-pull retry — models a
      // momentary IO error / a race with a just-finished blob write.
      var bApplyCalls = 0;
      final f = await _newPuller(
        [_rec(_idA, 1), _rec(_idB, 2), _rec(_idC, 3)],
        failFor: (id) {
          if (id != _idB) return false;
          bApplyCalls += 1;
          return bApplyCalls == 1; // only the first attempt fails
        },
      );

      await f.puller.pull();

      expect(f.store.serverCursor, 3,
          reason:
              'the in-pull retry applied B, so this single pull is correct — '
              'no cursor hold, no waiting for another sync');
      expect(f.events.whereType<SyncRecordSkipped>(), isEmpty);
      expect(bApplyCalls, greaterThanOrEqualTo(2),
          reason: 'B was retried within the same pull');
    });

    test('a recovering file clears its streak and the cursor advances', () async {
      var bShouldFail = true;
      final f = await _newPuller(
        [_rec(_idA, 1), _rec(_idB, 2), _rec(_idC, 3)],
        failFor: (id) => id == _idB && bShouldFail,
      );

      await f.puller.pull();
      expect(f.store.serverCursor, 1, reason: 'held while B is failing');

      // B becomes applyable (e.g. its blob is now reachable).
      bShouldFail = false;
      await f.puller.pull();

      expect(f.store.serverCursor, 3, reason: 'B applied, cursor advances fully');
      expect(f.events.whereType<SyncRecordSkipped>(), isEmpty,
          reason: 'a recovered file is never reported as skipped');
    });
  });

  group('StatePuller — preemption unwinds the pull (not swallowed, not held '
      'like a per-file failure)', () {
    test('a cancelled context aborts the pull, cursor untouched, nothing skipped',
        () async {
      final f = await _newPuller(
        [_rec(_idA, 1), _rec(_idB, 2)],
        failFor: (_) => false,
      );
      final token = RpcCancellationToken()..cancel('preempted by edit');
      final ctx = RpcContext.withCancellation(token);

      await expectLater(
        () => f.puller.pull(context: ctx),
        throwsA(isA<RpcCancelledException>()),
        reason: 'a preempted pull must unwind so the lane frees for the push',
      );
      expect(f.store.serverCursor, 0,
          reason: 'cursor must NOT advance on preempt — the re-scheduled pull '
              're-fetches the batch from where it left off');
      expect(f.events.whereType<SyncRecordSkipped>(), isEmpty,
          reason: 'cancellation is not a per-file failure — nothing is skipped');
    });

    test('cancellation raised mid-apply propagates out, not held/skipped like a '
        'transient failure', () async {
      // B throws RpcCancelledException — exactly what an in-flight blob download
      // raises when the interactive push preempts the pull. Unlike a StateError
      // (which is held-and-retried), this must abort the WHOLE pull with the
      // cursor left at 0 so the re-scheduled pull retries from scratch.
      final f = await _newPuller(
        [_rec(_idA, 1), _rec(_idB, 2), _rec(_idC, 3)],
        failFor: (_) => false,
        errorFor: (id) =>
            id == _idB ? RpcCancelledException('preempted') : null,
      );

      await expectLater(
        () => f.puller.pull(),
        throwsA(isA<RpcCancelledException>()),
      );
      expect(f.store.serverCursor, 0,
          reason: 'the pull unwinds; the cursor is never advanced NOR held '
              '(a StateError would hold it at 1 — cancellation must not)');
      expect(f.events.whereType<SyncRecordSkipped>(), isEmpty);
    });
  });
}
