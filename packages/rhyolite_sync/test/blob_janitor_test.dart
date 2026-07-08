// BlobJanitor tests using a thin in-process fake of the history caller.
// We don't spin up a full server in client_core tests because that would
// require pulling sync_server transitively. The server-side path is
// covered separately by state/history responder tests.

import 'dart:typed_data';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart' show RpcContext;
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

const _v = '12345678-1234-4abc-8def-1234567890ab';

class _MemBlobStorage implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  @override
  Future<Set<String>> exists(List<String> blobIds, {RpcContext? context}) async =>
      {for (final id in blobIds) if (store.containsKey(id)) id};
  final List<String> deletedLog = [];
  bool failDelete = false;

  @override
  Future<void> deleteMany(List<String> blobIds, {RpcContext? context}) async {
    if (failDelete) throw StateError('backend refused delete');
    deletedLog.addAll(blobIds);
    for (final id in blobIds) {
      store.remove(id);
    }
  }

  @override
  Future<Map<String, Uint8List>> download(List<String> blobIds, {RpcContext? context}) async => {
    for (final id in blobIds)
      if (store.containsKey(id)) id: store[id]!,
  };

  @override
  Future<void> upload(List<(Uint8List, String)> blobs, {RpcContext? context}) async {
    for (final (bytes, id) in blobs) store[id] = bytes;
  }
}

class _FakeHistoryCaller implements IHistoryContract {
  final List<HistoryEvent> events = [];
  final List<String> deletedEventIds = [];

  void seed(HistoryEvent e) => events.add(e);

  @override
  Future<HistoryGetResponse> getHistory(
    HistoryGetRequest request, {
    RpcContext? context,
  }) async {
    final all = events.where((e) {
      if (request.fileId != null && e.fileId != request.fileId) return false;
      if (request.fromHlcPacked != null &&
          e.hlcPacked.compareTo(request.fromHlcPacked!) <= 0)
        return false;
      if (request.beforeHlcPacked != null &&
          e.hlcPacked.compareTo(request.beforeHlcPacked!) >= 0)
        return false;
      return true;
    }).toList();
    all.sort(
      (a, b) => request.ascending
          ? a.hlcPacked.compareTo(b.hlcPacked)
          : b.hlcPacked.compareTo(a.hlcPacked),
    );
    return HistoryGetResponse(
      events: all.take(request.limit).toList(),
      epoch: 0,
    );
  }

  @override
  Future<HistoryDeleteEventsResponse> deleteEvents(
    HistoryDeleteEventsRequest request, {
    RpcContext? context,
  }) async {
    final before = events.length;
    events.removeWhere((e) => request.eventIds.contains(e.eventId));
    deletedEventIds.addAll(request.eventIds);
    return HistoryDeleteEventsResponse(deleted: before - events.length);
  }

  // Heads stubs — the tests in this file don't exercise them but they
  // are now part of the contract.
  final List<DeviceHead> heads = [];

  @override
  Future<ReportHistoryHeadResponse> reportHistoryHead(
    ReportHistoryHeadRequest request, {
    RpcContext? context,
  }) async {
    heads.removeWhere((h) => h.deviceId == request.deviceId);
    heads.add(
      DeviceHead(
        deviceId: request.deviceId,
        headSeq: request.headSeq,
        updatedAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      ),
    );
    return const ReportHistoryHeadResponse();
  }

  @override
  Future<GetHistoryHeadsResponse> getHistoryHeads(
    GetHistoryHeadsRequest request, {
    RpcContext? context,
  }) async => GetHistoryHeadsResponse(heads: List.of(heads));

  @override
  Future<ForgetDeviceResponse> forgetDevice(
    ForgetDeviceRequest request, {
    RpcContext? context,
  }) async => const ForgetDeviceResponse(removed: false);
}

HistoryEvent _evt({
  required String id,
  required String fileId,
  required String blobRef,
  required int hlcMs,
  required int createdAtMs,
  HistoryOperation op = HistoryOperation.modify,
  int serverSeq = 0,
}) => HistoryEvent(
  eventId: id,
  fileId: fileId,
  blobRef: blobRef,
  hlcPacked: '$hlcMs-0-A',
  operation: op,
  encryptedMeta: 'enc',
  createdAtMs: createdAtMs,
  serverSeq: serverSeq,
);

FileState _state(String fileId, String blobRef) => FileState(
  fileId: fileId,
  path: '$fileId.md',
  blobRef: blobRef,
  sizeBytes: 1,
  hlc: Hlc(1, 0, 'A'),
);

int _daysAgoMs(int days) =>
    DateTime.now().toUtc().millisecondsSinceEpoch - days * 86400000;

void main() {
  late IDataClient dataClient;
  late FileStateStore store;
  late _MemBlobStorage blobs;
  late _FakeHistoryCaller historyCaller;
  late BlobJanitor janitor;

  setUp(() async {
    final env = await DataServiceFactory.inMemory();
    addTearDown(env.dispose);
    dataClient = env.client;
    store = FileStateStore(client: dataClient, vaultId: _v);
    await store.load();
    blobs = _MemBlobStorage();
    historyCaller = _FakeHistoryCaller();
    janitor = BlobJanitor(
      historyCaller: historyCaller,
      blobStorage: blobs,
      store: store,
      vaultId: _v,
    );
  });

  group('scan', () {
    test('selects events older than threshold, no live ref → orphan', () async {
      historyCaller.seed(
        _evt(
          id: 'old',
          fileId: 'f1',
          blobRef: 'blob-OLD',
          hlcMs: 1,
          createdAtMs: _daysAgoMs(60),
        ),
      );
      historyCaller.seed(
        _evt(
          id: 'recent',
          fileId: 'f1',
          blobRef: 'blob-RECENT',
          hlcMs: 2,
          createdAtMs: _daysAgoMs(5),
        ),
      );
      // file_state currently points at the recent blob — old is truly orphan.
      store.upsert(_state('f1', 'blob-RECENT'));

      final plan = await janitor.scan(olderThanDays: 30);
      expect(plan.totalEvents, 2);
      expect(plan.eventsToDelete, 1);
      expect(plan.eventsToKeep, 1);
      expect(plan.orphanBlobCount, 1);
      expect(plan.blobIds, ['blob-OLD']);
      expect(plan.eventIds, ['old']);
    });

    test('keeps blob if a current file_state still references it', () async {
      historyCaller.seed(
        _evt(
          id: 'old',
          fileId: 'f1',
          blobRef: 'blob-X',
          hlcMs: 1,
          createdAtMs: _daysAgoMs(60),
        ),
      );
      // file_state still uses blob-X — must NOT be deleted.
      store.upsert(_state('f1', 'blob-X'));

      final plan = await janitor.scan(olderThanDays: 30);
      expect(plan.eventsToDelete, 1);
      expect(
        plan.orphanBlobCount,
        0,
        reason: 'blob is live in file_state, must not appear as orphan',
      );
    });

    test(
      'keeps blob if lastSyncedBlobRef references it (3-way merge base)',
      () async {
        historyCaller.seed(
          _evt(
            id: 'old',
            fileId: 'f1',
            blobRef: 'blob-base',
            hlcMs: 1,
            createdAtMs: _daysAgoMs(60),
          ),
        );
        store.upsert(_state('f1', 'blob-current'));
        store.recordSyncedBlobRef('f1', 'blob-base');

        final plan = await janitor.scan(olderThanDays: 30);
        expect(plan.orphanBlobCount, 0);
      },
    );

    test(
      'keeps blob if a surviving event references it (within window)',
      () async {
        historyCaller.seed(
          _evt(
            id: 'old',
            fileId: 'f1',
            blobRef: 'blob-shared',
            hlcMs: 1,
            createdAtMs: _daysAgoMs(60),
          ),
        );
        historyCaller.seed(
          _evt(
            id: 'recent',
            fileId: 'f1',
            blobRef: 'blob-shared',
            hlcMs: 2,
            createdAtMs: _daysAgoMs(5),
          ),
        );

        final plan = await janitor.scan(olderThanDays: 30);
        expect(plan.eventsToDelete, 1);
        expect(
          plan.orphanBlobCount,
          0,
          reason: 'a surviving event also references this blob',
        );
      },
    );

    test('rejects negative olderThanDays', () async {
      expect(() => janitor.scan(olderThanDays: -1), throwsArgumentError);
    });

    test('olderThanDays: 0 deletes recent history a 30-day window would keep',
        () async {
      historyCaller.seed(
        _evt(
          id: 'yesterday',
          fileId: 'f1',
          blobRef: 'blob-recent',
          hlcMs: 1,
          createdAtMs: _daysAgoMs(1),
        ),
      );
      // No active heads → nothing pins → device-safety allows deletion.
      expect(
        (await janitor.scan(olderThanDays: 30)).eventsToDelete,
        0,
        reason: 'a 1-day-old event is within a 30-day window',
      );
      expect(
        (await janitor.scan(olderThanDays: 0)).eventsToDelete,
        1,
        reason: 'days=0 clears everything the device head allows',
      );
    });

    test('isEmpty true when nothing to do', () async {
      final plan = await janitor.scan(olderThanDays: 30);
      expect(plan.isEmpty, isTrue);
    });
  });

  group('scan with device heads', () {
    test('keeps events above the minimum active device head', () async {
      // Two old events. Device A has processed up to seq=5, device B
      // only up to seq=2. Event with seq=3 must be kept because B
      // hasn't seen it yet.
      historyCaller.seed(
        _evt(
          id: 'e-old-seen',
          fileId: 'f1',
          blobRef: 'blob-2',
          hlcMs: 1,
          createdAtMs: _daysAgoMs(60),
          serverSeq: 2,
        ),
      );
      historyCaller.seed(
        _evt(
          id: 'e-old-unseen',
          fileId: 'f1',
          blobRef: 'blob-3',
          hlcMs: 2,
          createdAtMs: _daysAgoMs(60),
          serverSeq: 3,
        ),
      );
      historyCaller.heads.addAll([
        DeviceHead(
          deviceId: 'A',
          headSeq: 5,
          updatedAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
        ),
        DeviceHead(
          deviceId: 'B',
          headSeq: 2,
          updatedAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
        ),
      ]);

      final plan = await janitor.scan(olderThanDays: 30);
      // min head = 2. Event seq=2 is OK to delete; seq=3 is protected.
      expect(plan.eventIds, ['e-old-seen']);
      expect(plan.eventsProtectedByHead, 1);
      expect(plan.minSafeHead, 2);
      expect(plan.activeDeviceCount, 2);
    });

    test('ignores stale device heads (older than deviceTtl)', () async {
      historyCaller.seed(
        _evt(
          id: 'e1',
          fileId: 'f1',
          blobRef: 'blob-2',
          hlcMs: 1,
          createdAtMs: _daysAgoMs(60),
          serverSeq: 100,
        ),
      );
      historyCaller.heads.addAll([
        DeviceHead(
          deviceId: 'fresh',
          headSeq: 1000,
          updatedAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
        ),
        DeviceHead(deviceId: 'stale', headSeq: 5, updatedAtMs: _daysAgoMs(60)),
      ]);

      final plan = await janitor.scan(olderThanDays: 30, deviceTtlDays: 30);
      // 'stale' is excluded → min over actives = fresh.head = 1000.
      // Event seq=100 < 1000 → deletable.
      expect(plan.activeDeviceCount, 1);
      expect(plan.minSafeHead, 1000);
      expect(plan.eventIds, ['e1']);
    });

    test('no active devices → age-based deletion only', () async {
      historyCaller.seed(
        _evt(
          id: 'e1',
          fileId: 'f1',
          blobRef: 'blob-A',
          hlcMs: 1,
          createdAtMs: _daysAgoMs(60),
          serverSeq: 10,
        ),
      );
      historyCaller.heads.add(
        DeviceHead(
          deviceId: 'long-gone',
          headSeq: 5,
          updatedAtMs: _daysAgoMs(60),
        ),
      );

      final plan = await janitor.scan(olderThanDays: 30, deviceTtlDays: 30);
      expect(plan.activeDeviceCount, 0);
      expect(plan.minSafeHead, isNull);
      expect(plan.eventIds, ['e1']);
    });
  });

  group('execute', () {
    test('deletes orphan blobs from storage and events from server', () async {
      historyCaller.seed(
        _evt(
          id: 'old',
          fileId: 'f1',
          blobRef: 'blob-OLD',
          hlcMs: 1,
          createdAtMs: _daysAgoMs(60),
        ),
      );
      blobs.store['blob-OLD'] = Uint8List.fromList([1, 2, 3]);
      blobs.store['blob-OTHER'] = Uint8List.fromList([4, 5]);

      final plan = await janitor.scan(olderThanDays: 30);
      final result = await janitor.execute(plan);
      expect(result.deletedBlobs, 1);
      expect(result.deletedEvents, 1);
      expect(blobs.store.containsKey('blob-OLD'), isFalse);
      expect(blobs.store.containsKey('blob-OTHER'), isTrue);
      expect(historyCaller.events, isEmpty);
    });

    test('empty plan is a no-op', () async {
      final plan = await janitor.scan(olderThanDays: 30);
      final result = await janitor.execute(plan);
      expect(result.deletedBlobs, 0);
      expect(result.deletedEvents, 0);
    });

    test('blob delete failure keeps events (no invisible orphans)', () async {
      historyCaller.seed(
        _evt(
          id: 'old',
          fileId: 'f1',
          blobRef: 'blob-OLD',
          hlcMs: 1,
          createdAtMs: _daysAgoMs(60),
        ),
      );
      blobs.store['blob-OLD'] = Uint8List.fromList([1, 2, 3]);
      blobs.failDelete = true;

      final plan = await janitor.scan(olderThanDays: 30);
      final result = await janitor.execute(plan);

      expect(result.failedBlobs, greaterThan(0));
      expect(result.hadFailures, isTrue);
      expect(result.deletedEvents, 0,
          reason: 'events must NOT be deleted while their blobs remain — '
              'that would strand the blob as an unfindable orphan');
      expect(historyCaller.deletedEventIds, isEmpty);
      expect(historyCaller.events, isNotEmpty, reason: 'event kept for retry');
    });
  });
}
