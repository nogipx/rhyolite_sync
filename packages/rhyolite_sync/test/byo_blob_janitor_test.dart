import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

const _vaultId = '00000000-0000-4000-8000-0000000000ee';

/// A BYO bucket that can be enumerated.
class _FakeBucket implements IListableBlobStorage {
  _FakeBucket(Iterable<String> ids, {this.canList = true}) {
    for (final id in ids) {
      objects[id] = Uint8List(0);
    }
  }

  final Map<String, Uint8List> objects = {};
  final bool canList;
  int listCalls = 0;

  @override
  Future<List<String>?> listBlobIds({RpcContext? context}) async {
    listCalls++;
    return canList ? objects.keys.toList() : null;
  }

  @override
  Future<void> deleteMany(List<String> blobIds, {RpcContext? context}) async {
    for (final id in blobIds) {
      objects.remove(id);
    }
  }

  @override
  Future<Map<String, Uint8List>> download(
    List<String> ids, {
    RpcContext? context,
  }) async => {};
  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    RpcContext? context,
  }) async {}
  @override
  Future<Set<String>> exists(List<String> ids, {RpcContext? context}) async =>
      {};
}

/// A backend with no listing at all — what the managed gRPC path is.
class _OpaqueStorage implements IBlobStorage {
  @override
  Future<Map<String, Uint8List>> download(
    List<String> ids, {
    RpcContext? context,
  }) async => {};
  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    RpcContext? context,
  }) async {}
  @override
  Future<void> deleteMany(List<String> ids, {RpcContext? context}) async {}
  @override
  Future<Set<String>> exists(List<String> ids, {RpcContext? context}) async =>
      {};
}

class _FakeMaintenance implements IVaultMaintenanceContract {
  _FakeMaintenance({this.live = const {}, this.throwOnClassify = false});

  /// What the SERVER considers referenced. The janitor must never widen this.
  final Set<String> live;
  final bool throwOnClassify;
  final batches = <int>[];

  @override
  Future<ClassifyBlobsResponse> classifyBlobs(
    ClassifyBlobsRequest request, {
    RpcContext? context,
  }) async {
    if (throwOnClassify) throw StateError('no such method');
    batches.add(request.blobIds.length);
    return ClassifyBlobsResponse(
      requested: request.blobIds.length,
      deadBlobIds: request.blobIds.where((id) => !live.contains(id)).toList(),
    );
  }

  @override
  Future<ReleaseBlobsResponse> releaseBlobs(
    ReleaseBlobsRequest request, {
    RpcContext? context,
  }) async => const ReleaseBlobsResponse(
    requested: 0,
    stillReferenced: 0,
    deletedBlobs: 0,
  );

  @override
  Future<SweepOrphanBlobsResponse> sweepOrphanBlobs(
    SweepOrphanBlobsRequest request, {
    RpcContext? context,
  }) => throw UnimplementedError();

  @override
  Future<SweepStableTombstonesResponse> sweepStableTombstones(
    SweepStableTombstonesRequest request, {
    RpcContext? context,
  }) => throw UnimplementedError();
}

void main() {
  group('ByoBlobJanitor', () {
    test('deletes only what the server calls dead', () async {
      final bucket = _FakeBucket(['live-1', 'orphan-1', 'live-2', 'orphan-2']);
      final janitor = ByoBlobJanitor(
        blobStorage: bucket,
        maintenanceCaller: _FakeMaintenance(live: {'live-1', 'live-2'}),
        vaultId: _vaultId,
      );

      final plan = await janitor.scan();
      expect(plan.unsupported, isFalse);
      expect(plan.totalBlobs, 4);
      expect(plan.deadBlobIds..sort(), ['orphan-1', 'orphan-2']);

      expect(await janitor.execute(plan), 2);
      expect(bucket.objects.keys.toSet(), {'live-1', 'live-2'});
    });

    test('a blob the server has never heard of is an orphan', () async {
      // The whole point of the sweep: residue from a failed upload is in the
      // bucket and in no record anywhere.
      final bucket = _FakeBucket(['stranded']);
      final janitor = ByoBlobJanitor(
        blobStorage: bucket,
        maintenanceCaller: _FakeMaintenance(live: const {}),
        vaultId: _vaultId,
      );

      final plan = await janitor.scan();
      expect(plan.deadBlobIds, ['stranded']);
    });

    test('scan deletes nothing on its own', () async {
      final bucket = _FakeBucket(['orphan']);
      final janitor = ByoBlobJanitor(
        blobStorage: bucket,
        maintenanceCaller: _FakeMaintenance(live: const {}),
        vaultId: _vaultId,
      );

      await janitor.scan();
      expect(
        bucket.objects,
        hasLength(1),
        reason: 'the user has not approved anything yet',
      );
    });

    test(
      'execute deletes exactly the approved plan, not a fresh verdict',
      () async {
        final bucket = _FakeBucket(['a', 'b']);
        final janitor = ByoBlobJanitor(
          blobStorage: bucket,
          maintenanceCaller: _FakeMaintenance(live: const {}),
          vaultId: _vaultId,
        );

        // A plan naming only 'a', as if the user reviewed it before 'b' appeared.
        await janitor.execute(
          const ByoSweepPlan(totalBlobs: 1, deadBlobIds: ['a']),
        );
        expect(
          bucket.objects.keys,
          ['b'],
          reason: 'widening the plan would delete what nobody saw',
        );
      },
    );

    test(
      'a storage that cannot be listed reports unsupported, not clean',
      () async {
        final janitor = ByoBlobJanitor(
          blobStorage: _OpaqueStorage(),
          maintenanceCaller: _FakeMaintenance(),
          vaultId: _vaultId,
        );

        final plan = await janitor.scan();
        expect(plan.unsupported, isTrue);
        expect(
          plan.isClean,
          isFalse,
          reason: 'a bucket we never read must not be reported clean',
        );
      },
    );

    test(
      'a listing that returns null is unsupported, not an empty bucket',
      () async {
        final janitor = ByoBlobJanitor(
          blobStorage: _FakeBucket(const ['x'], canList: false),
          maintenanceCaller: _FakeMaintenance(),
          vaultId: _vaultId,
        );

        expect((await janitor.scan()).unsupported, isTrue);
      },
    );

    test('a server too old to classify aborts the whole sweep', () async {
      final bucket = _FakeBucket(['a', 'b']);
      final janitor = ByoBlobJanitor(
        blobStorage: bucket,
        maintenanceCaller: _FakeMaintenance(throwOnClassify: true),
        vaultId: _vaultId,
      );

      final plan = await janitor.scan();
      expect(plan.unsupported, isTrue);
      expect(
        plan.deadBlobIds,
        isEmpty,
        reason: 'a half-answered sweep must never reach execute',
      );
      expect(await janitor.execute(plan), 0);
      expect(bucket.objects, hasLength(2));
    });

    test('a large bucket is classified in bounded batches', () async {
      final ids = [for (var i = 0; i < 1200; i++) 'blob-$i'];
      final maintenance = _FakeMaintenance(live: const {});
      final janitor = ByoBlobJanitor(
        blobStorage: _FakeBucket(ids),
        maintenanceCaller: maintenance,
        vaultId: _vaultId,
        classifyBatchSize: 500,
      );

      final plan = await janitor.scan();
      expect(plan.deadBlobIds, hasLength(1200));
      expect(maintenance.batches, [500, 500, 200]);
    });

    test('an empty bucket is clean, and asks the server nothing', () async {
      final maintenance = _FakeMaintenance();
      final plan = await ByoBlobJanitor(
        blobStorage: _FakeBucket(const []),
        maintenanceCaller: maintenance,
        vaultId: _vaultId,
      ).scan();

      expect(plan.isClean, isTrue);
      expect(maintenance.batches, isEmpty);
    });
  });
}
