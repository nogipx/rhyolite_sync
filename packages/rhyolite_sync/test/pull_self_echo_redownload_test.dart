// The pull that re-downloaded a vault to compare it against itself.
//
// A device finished its first sync — 9078 records pushed, server cursor 0 to
// 9078 — and one second later pulled all 9078 straight back, because a push
// deliberately does not advance the pull cursor. That much is by design and is
// meant to be nearly free: the join collapses to the value already held and
// the materialise stops at a guard that recognises content already on disk.
//
// It was not free. The prefetch skipped those files as self-echo (correctly:
// the register held exactly their blobRef), while the apply could NOT skip
// them — the startup scan had recorded their signatures without a blobRef, and
// the apply's guard refuses a signature that cannot name what it is evidence
// for. So every file was fetched anyway, one at a time inside the apply
// instead of a batch in the prefetch, to be compared byte-for-byte against the
// file it had been made from and discarded. 225 sampled writes in that
// session, `result=skipped-identical` every one, `skipped-own-echo` none.
//
// Two facts have to hold for that to stay fixed, and they are different facts:
//   * the prefetch may only skip what the apply can skip (this file);
//   * the scan must leave signatures the apply can use (state_startup_diff).
//
// The second file covers the second. This one covers the first, plus the
// cursor bound that turned one wasted pull into one per restart.
import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/sync_v3/state_puller.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';
import 'package:rhyolite_core/rhyolite_core.dart';

const _vaultId = '00000000-0000-4000-8000-0000000000e5';

String _id(int n) => 'file-${n.toString().padLeft(4, '0')}';
String _blob(int n) => 'blob-${n.toString().padLeft(4, '0')}';

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
    final maxSeq = dataset.fold<int>(
      0,
      (m, r) => r.serverSeq > m ? r.serverSeq : m,
    );
    return StateGetResponse(records: records, cursor: maxSeq, epoch: 0);
  }

  @override
  Future<StatePutResponse> putStates(
    StatePutRequest request, {
    RpcContext? context,
  }) => throw UnimplementedError();
  @override
  Future<StateWipeResponse> wipeVault(
    StateWipeRequest request, {
    RpcContext? context,
  }) => throw UnimplementedError();
  @override
  Future<StatePurgeResponse> purgeVault(
    StatePurgeRequest request, {
    RpcContext? context,
  }) => throw UnimplementedError();
}

class _FakeHistoryCaller implements IHistoryContract {
  @override
  Future<ReportHistoryHeadResponse> reportHistoryHead(
    ReportHistoryHeadRequest request, {
    RpcContext? context,
  }) async => const ReportHistoryHeadResponse();
  @override
  Future<HistoryGetResponse> getHistory(
    HistoryGetRequest request, {
    RpcContext? context,
  }) => throw UnimplementedError();
  @override
  Future<HistoryDeleteEventsResponse> deleteEvents(
    HistoryDeleteEventsRequest request, {
    RpcContext? context,
  }) => throw UnimplementedError();
  @override
  Future<GetHistoryHeadsResponse> getHistoryHeads(
    GetHistoryHeadsRequest request, {
    RpcContext? context,
  }) => throw UnimplementedError();
  @override
  Future<ForgetDeviceResponse> forgetDevice(
    ForgetDeviceRequest request, {
    RpcContext? context,
  }) => throw UnimplementedError();
}

class _NoConflictResolver implements IStateConflictResolver {
  @override
  Future<StateMergeOutcome> resolve(
    List<FileState> values, {
    String? baseRef,
  }) => throw UnimplementedError();
}

/// Present so the prefetch runs at all — it returns early on a null backend,
/// which would make every assertion here vacuously true.
class _StubRemote implements IBlobStorage {
  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    covariant Object? context,
  }) async => const {};
  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    covariant Object? context,
  }) async {}
  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    covariant Object? context,
  }) async => const {};
  @override
  Future<void> deleteMany(
    List<String> blobIds, {
    covariant Object? context,
  }) async {}
}

StateRecord _rec(String fileId, int seq, {required String blobRef}) =>
    StateRecord(
      fileId: fileId,
      encryptedState: '',
      blobRef: blobRef,
      hlcPacked: Hlc(seq, 0, 'device-$fileId').pack(),
      contextPacked: '',
      serverSeq: seq,
      chunks: [blobRef],
      tombstone: false,
    );

typedef _Fx = ({
  StatePuller puller,
  FileStateStore store,
  List<String> prefetched,
  List<String> applied,
});

/// [diskHolds] stands in for the apply-side guard: the set of fileIds whose
/// on-disk content the reconciler could prove without fetching anything.
Future<_Fx> _newPuller(
  List<StateRecord> dataset, {
  Set<String> diskHolds = const {},

  /// Cuts the pull off after this many applies, the way an interactive edit
  /// preempting a pull does.
  int? cancelAfterApplies,
}) async {
  final env = await DataServiceFactory.inMemory();
  addTearDown(env.dispose);
  final store = FileStateStore(client: env.client, vaultId: _vaultId);
  await store.load();
  final prefetched = <String>[];
  final applied = <String>[];

  final puller = StatePuller(
    stateCaller: _FakeStateCaller(dataset),
    historyCaller: _FakeHistoryCaller(),
    store: store,
    blobStore: LocalBlobStore(InMemoryBlobRepository()),
    vaultId: _vaultId,
    rpcTimeout: const Duration(seconds: 5),
    getRemoteBlobStorage: _StubRemote.new,
    newResolver: () => _NoConflictResolver(),
    applyFile: (fileId, records, resolver, {context}) async {
      if (cancelAfterApplies != null && applied.length >= cancelAfterApplies) {
        throw const RpcCancelledException('preempted by interactive work');
      }
      applied.add(fileId);
    },
    handleEpochMismatch: (_) async {},
    emit: (_) {},
    isFatalRejection: (_) => false,
    log: LogScope.noop,
    prefetchFiles: (blobRefs, {context, onFileProgress}) async {
      prefetched.addAll(blobRefs);
      return (fromServer: blobRefs.length, rebuilt: 0);
    },
    downloadConcurrency: 1,
    diskProvablyHolds: (fileId, blobRef) => diskHolds.contains(fileId),
  );

  return (
    puller: puller,
    store: store,
    prefetched: prefetched,
    applied: applied,
  );
}

/// Seeds the store so the incoming records read as this device's own work
/// coming back: one value per register, holding exactly the incoming blobRef.
Future<void> _seedHeld(FileStateStore store, List<StateRecord> records) async {
  for (final r in records) {
    store.upsert(
      FileState(
        fileId: r.fileId,
        path: '${r.fileId}.bin',
        blobRef: r.blobRef,
        sizeBytes: 10,
        hlc: store.nextHlc(),
        chunks: r.chunks,
      ),
    );
  }
  await store.persistMeta();
}

void main() {
  group('a self-echo may only skip the prefetch if the apply can skip too', () {
    test(
      'the prefetch is skipped when the disk guard vouches for the file',
      () async {
        final records = [
          for (var i = 1; i <= 4; i++) _rec(_id(i), i, blobRef: _blob(i)),
        ];
        final f = await _newPuller(
          records,
          diskHolds: {for (var i = 1; i <= 4; i++) _id(i)},
        );
        await _seedHeld(f.store, records);

        await f.puller.pull();

        expect(
          f.prefetched,
          isEmpty,
          reason: 'the register holds these values and the disk provably holds '
              'their bytes, so there is nothing for either side to fetch',
        );
        expect(f.applied, hasLength(4), reason: 'still applied, just for free');
      },
    );

    test(
      'the prefetch is NOT skipped when the disk guard cannot vouch',
      () async {
        // The reported vault, in miniature. The register says echo for every
        // file; the signatures cannot name a blobRef, so the apply will fetch
        // each one on its own. Skipping the batch here does not avoid that
        // download — it converts it into the serial per-file form, which is
        // what turned a finished sync into hours of re-downloading.
        final records = [
          for (var i = 1; i <= 4; i++) _rec(_id(i), i, blobRef: _blob(i)),
        ];
        final f = await _newPuller(records, diskHolds: const {});
        await _seedHeld(f.store, records);

        await f.puller.pull();

        expect(
          f.prefetched.toSet(),
          {for (var i = 1; i <= 4; i++) _blob(i)},
          reason: 'if the apply is going to fetch these anyway, the prefetch '
              'is the cheap place to do it — one batched pair of round trips '
              'instead of two per file',
        );
      },
    );

    test('a partial vouch splits the batch rather than deciding for all', () async {
      final records = [
        for (var i = 1; i <= 4; i++) _rec(_id(i), i, blobRef: _blob(i)),
      ];
      final f = await _newPuller(records, diskHolds: {_id(1), _id(3)});
      await _seedHeld(f.store, records);

      await f.puller.pull();

      expect(
        f.prefetched.toSet(),
        {_blob(2), _blob(4)},
        reason: 'the decision is per file, and the two the disk vouches for '
            'must not drag the other two along',
      );
    });
  });

  group('the cursor advances through a long pull', () {
    test(
      'an interrupted pull banks its progress instead of the response floor',
      () async {
        // The bound itself is right: the cursor may only advance to just below
        // the smallest seq still unapplied. What was wrong is what the size
        // sort did to it. Ordering by size across the WHOLE response puts the
        // response's lowest seq wherever its size lands — dead last, for a big
        // attachment — so that one file holds the cursor at the floor no
        // matter how much of the vault has been applied and persisted.
        //
        // It only shows when the pull does not finish, which on the reported
        // device was every time: a preemption, a restart, a health check. One
        // report applied every one of 9078 records across two passes and
        // persisted a cursor of 61.
        //
        // 300 files so the response spans more than one window; seq 1 is the
        // largest, so a global sort applies it last and a windowed one applies
        // it inside the first window. The pull is then cut off after window
        // one is through.
        const total = 300;
        const cutAfter = 260;
        final records = <StateRecord>[
          StateRecord(
            fileId: _id(1),
            encryptedState: '',
            blobRef: _blob(1),
            hlcPacked: Hlc(1, 0, 'device-big').pack(),
            contextPacked: '',
            serverSeq: 1,
            chunks: [for (var c = 0; c < 40; c++) 'chunk-$c'],
            tombstone: false,
          ),
          for (var i = 2; i <= total; i++) _rec(_id(i), i, blobRef: _blob(i)),
        ];
        final f = await _newPuller(
          records,
          diskHolds: {for (var i = 1; i <= total; i++) _id(i)},
          cancelAfterApplies: cutAfter,
        );
        await _seedHeld(f.store, records);

        await expectLater(
          f.puller.pull(),
          throwsA(isA<RpcCancelledException>()),
        );

        expect(
          f.applied,
          hasLength(cutAfter),
          reason: 'sanity: the pull really was cut off part way',
        );
        expect(
          f.store.serverCursor,
          greaterThanOrEqualTo(256),
          reason: 'the first window is fully applied, so its seqs are banked '
              'and the next pull starts after them. Sorted globally by size '
              'the seq-1 file would still be unapplied here and the cursor '
              'would sit at 0 — every one of those 260 applies re-fetched.',
        );
      },
    );

    test('small files still precede large ones inside a window', () async {
      // The windowing exists to let the cursor move; it must not cost the
      // reason the size sort was there. Within one window a note still lands
      // before an attachment.
      final records = <StateRecord>[
        StateRecord(
          fileId: _id(1),
          encryptedState: '',
          blobRef: _blob(1),
          hlcPacked: Hlc(1, 0, 'device-big').pack(),
          contextPacked: '',
          serverSeq: 1,
          chunks: [for (var c = 0; c < 40; c++) 'chunk-$c'],
          tombstone: false,
        ),
        for (var i = 2; i <= 8; i++) _rec(_id(i), i, blobRef: _blob(i)),
      ];
      final f = await _newPuller(
        records,
        diskHolds: {for (var i = 1; i <= 8; i++) _id(i)},
      );
      await _seedHeld(f.store, records);

      await f.puller.pull();

      expect(
        f.applied.last,
        _id(1),
        reason: 'the 40-chunk file has the lowest seq and must still be '
            'applied last — within a window, size is what orders',
      );
    });
  });
}
