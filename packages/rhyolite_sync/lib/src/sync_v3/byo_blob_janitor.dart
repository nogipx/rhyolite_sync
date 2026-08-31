import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// What a bring-your-own sweep found, or why it could not look.
class ByoSweepPlan {
  const ByoSweepPlan({
    required this.totalBlobs,
    required this.deadBlobIds,
    this.unsupported = false,
  });

  /// The sweep could not run: the backend cannot be enumerated, or the server
  /// is too old to classify. Distinct from "found nothing" — the UI must not
  /// report a clean bucket it never managed to read.
  const ByoSweepPlan.unsupported()
    : totalBlobs = 0,
      deadBlobIds = const [],
      unsupported = true;

  /// Objects seen in the user's bucket under this vault's prefix.
  final int totalBlobs;

  /// Of those, the ones the SERVER says nothing references any more.
  final List<String> deadBlobIds;

  final bool unsupported;

  int get deadCount => deadBlobIds.length;
  bool get isClean => !unsupported && deadBlobIds.isEmpty;
}

/// Reclaims orphaned blobs from a bring-your-own S3/WebDAV bucket.
///
/// The managed sweep ([BlobJanitor.sweepOrphans]) is entirely server-side: the
/// server enumerates its own bucket, computes the live set, deletes. None of
/// that works for BYO, where the bytes sit in storage only the client holds
/// credentials for — so a BYO vault has had no orphan reclamation at all, and
/// failed uploads and residue from earlier cleanups accumulate with nothing
/// able to remove them.
///
/// This splits the same job across the two parties by what each one can see:
///
///   * the CLIENT enumerates the bucket, because only it can reach the
///     storage, and deletes, for the same reason;
///   * the SERVER decides which ids are dead, because only it has the whole
///     picture — every device's records including un-merged concurrent
///     values, plus history and restore points.
///
/// The division is not ceremony. Chunks are content-addressed and shared: the
/// same chunk can belong to another note, to a peer's version of the record
/// being replaced, or to a restore point this device never enumerated. A
/// client that decides for itself is how blobs go silently missing months
/// later, which is exactly the failure the server-authoritative sweep exists
/// to prevent.
class ByoBlobJanitor {
  ByoBlobJanitor({
    required this.blobStorage,
    required this.maintenanceCaller,
    required this.vaultId,
    this.classifyBatchSize = 500,
    LogScope? logger,
  }) : _log = logger ?? LogScope.noop;

  /// The vault's blob backend. Swept only when it implements
  /// [IListableBlobStorage] — the managed gRPC backend does not, and must not:
  /// it has its own server-side sweep and no business being enumerated here.
  final IBlobStorage blobStorage;

  /// The classify RPC. Null when not connected; the sweep then reports
  /// unsupported rather than guessing.
  final IVaultMaintenanceContract? maintenanceCaller;

  final String vaultId;

  /// Ids per classify call. Bounded so a bucket with a hundred thousand
  /// objects does not become one enormous request.
  final int classifyBatchSize;

  final LogScope _log;

  /// Lists the bucket and asks the server which of it is dead. Deletes
  /// nothing — [execute] does that, with the plan the user has seen.
  Future<ByoSweepPlan> scan({RpcContext? context}) async {
    final storage = blobStorage;
    if (storage is! IListableBlobStorage) {
      return const ByoSweepPlan.unsupported();
    }
    final caller = maintenanceCaller;
    if (caller == null) return const ByoSweepPlan.unsupported();

    final List<String>? present;
    try {
      present = await storage.listBlobIds(context: context);
    } catch (e) {
      _log.warning('BYO sweep: listing the bucket failed: $e');
      return const ByoSweepPlan.unsupported();
    }
    if (present == null) return const ByoSweepPlan.unsupported();
    if (present.isEmpty) {
      return const ByoSweepPlan(totalBlobs: 0, deadBlobIds: []);
    }

    final dead = <String>[];
    for (var i = 0; i < present.length; i += classifyBatchSize) {
      context?.cancellationToken?.throwIfCancelled();
      final end = (i + classifyBatchSize) > present.length
          ? present.length
          : i + classifyBatchSize;
      try {
        final response = await caller.classifyBlobs(
          ClassifyBlobsRequest(
            vaultId: vaultId,
            blobIds: present.sublist(i, end),
          ),
          context: context,
        );
        dead.addAll(response.deadBlobIds);
      } catch (e) {
        // An older server has no classifyBlobs. Report unsupported rather
        // than delete a partially-classified batch — a half-answered sweep
        // is the one outcome that must not reach [execute].
        _log.warning('BYO sweep: classify failed: $e');
        return const ByoSweepPlan.unsupported();
      }
    }

    _log.info(
      'BYO sweep: ${present.length} object(s) in the bucket, '
      '${dead.length} unreferenced',
    );
    return ByoSweepPlan(totalBlobs: present.length, deadBlobIds: dead);
  }

  /// Deletes exactly the ids in [plan]. Re-classifies nothing: the plan is
  /// what the user approved, and widening it here would delete things they
  /// never saw.
  Future<int> execute(ByoSweepPlan plan, {RpcContext? context}) async {
    if (plan.unsupported || plan.deadBlobIds.isEmpty) return 0;
    await blobStorage.deleteMany(plan.deadBlobIds, context: context);
    _log.info('BYO sweep: deleted ${plan.deadBlobIds.length} orphan(s)');
    return plan.deadBlobIds.length;
  }
}
