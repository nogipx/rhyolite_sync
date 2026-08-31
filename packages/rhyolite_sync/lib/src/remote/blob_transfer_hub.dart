import 'dart:async';
import 'dart:collection';

import 'package:rpc_dart/rpc_dart.dart';

import 'i_blob_storage.dart';

/// Central coordinator for all blob IO.
///
/// Wraps an inner [IBlobStorage] and gives callers three guarantees:
///
///   1. **Per-id dedup.** Two concurrent calls referencing the same blob
///      id share a single inner request. Common case: two files pulled
///      in parallel share a CDC chunk — chunk is uploaded/downloaded once.
///   2. **Concurrency cap.** At most [maxConcurrent] inner calls are
///      in flight at any time; the rest wait in FIFO order.
///   3. **Bulk cancellation.** [cancelAll] aborts every in-flight call
///      and fails every pending one. Used on `stop()` / `triggerReset()`.
///
/// Caller-side cancellation (via [RpcContext.cancellationToken]) detaches
/// the caller from waiting; the underlying task continues if other
/// subscribers exist, and only fires its own cancel when the last
/// subscriber leaves.
class BlobTransferHub implements IBlobStorage, IListableBlobStorage {
  BlobTransferHub({
    required this.inner,
    this.maxConcurrent = 3,
  }) : assert(maxConcurrent > 0);

  final IBlobStorage inner;
  final int maxConcurrent;

  /// Enumeration passes straight through: blob ids are plaintext content
  /// hashes at every layer of the stack, so nothing here needs decoding.
  /// Null when the backend underneath cannot list.
  @override
  Future<List<String>?> listBlobIds({RpcContext? context}) {
    final backend = inner;
    return backend is IListableBlobStorage
        ? backend.listBlobIds(context: context)
        : Future<List<String>?>.value(null);
  }

  final Map<String, _DownloadTask> _downloads = {};
  final Map<String, _UploadTask> _uploads = {};
  final Set<_DeleteCall> _deletes = {};

  int _running = 0;
  final Queue<Completer<void>> _waiters = Queue();
  bool _disposed = false;

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    _checkAlive();
    if (blobIds.isEmpty) return {};

    // Ids already in flight join their existing call; the rest go out as ONE
    // new call. Splitting them this way keeps the hub's dedup — two callers
    // wanting the same blob still share a fetch — while a caller that asked
    // for many blobs at once pays for one round trip instead of many.
    final joined = <String, _DownloadTask>{};
    final fresh = <_DownloadTask>[];
    for (final id in blobIds) {
      var task = _downloads[id];
      if (task == null) {
        task = _DownloadTask(id);
        _downloads[id] = task;
        fresh.add(task);
      }
      task.subscribers++;
      joined[id] = task;
    }
    // After the subscriber counts are up, so a group can never look abandoned
    // between being scheduled and being waited on.
    _scheduleDownloadGroup(fresh);

    final callerToken = context?.cancellationToken;
    final result = <String, Uint8List>{};
    // Give every task a listener BEFORE the first await. See the note on the
    // same line in [upload].
    for (final task in joined.values) {
      task.completer.future.ignore();
    }
    try {
      for (final entry in joined.entries) {
        final bytes = await _awaitWithCaller<Uint8List?>(
          entry.value.completer.future,
          callerToken,
        );
        if (bytes != null) result[entry.key] = bytes;
      }
      return result;
    } finally {
      for (final task in joined.values) {
        _detachDownload(task);
      }
    }
  }

  @override
  Future<void> upload(
    List<(Uint8List bytes, String blobId)> blobs, {
    RpcContext? context,
  }) async {
    _checkAlive();
    if (blobs.isEmpty) return;

    final freshTasks = <_UploadTask>[];
    final joinedTasks = <_UploadTask>[];

    for (final (bytes, id) in blobs) {
      var task = _uploads[id];
      if (task == null) {
        task = _UploadTask(id, bytes);
        _uploads[id] = task;
        freshTasks.add(task);
      } else {
        joinedTasks.add(task);
      }
      task.subscribers++;
    }

    _UploadBatch? batch;
    if (freshTasks.isNotEmpty) {
      batch = _UploadBatch(freshTasks);
      for (final t in freshTasks) {
        t.batch = batch;
      }
      _scheduleUploadBatch(batch);
    }

    final callerToken = context?.cancellationToken;
    final allTasks = [...freshTasks, ...joinedTasks];
    // Give every task a listener BEFORE the first await.
    //
    // The loop below awaits them one at a time, while [cancelAll] fails them
    // ALL at once. The first await then throws, the loop exits, and every
    // remaining task is left holding an error nobody is listening for — which
    // Dart reports as an unhandled error, one per task in flight. A single
    // dispose during a large first sync produced about thirty of them, and
    // they crowded out the failure that actually caused the dispose.
    //
    // `ignore` only marks them handled; awaiting the same future below still
    // delivers its error to the awaiter, so nothing is swallowed.
    for (final task in allTasks) {
      task.completer.future.ignore();
    }
    try {
      for (final task in allTasks) {
        await _awaitWithCaller<void>(task.completer.future, callerToken);
      }
    } finally {
      for (final task in allTasks) {
        _detachUpload(task);
      }
    }
  }

  @override
  Future<void> deleteMany(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    _checkAlive();
    if (blobIds.isEmpty) return;

    final call = _DeleteCall();
    _deletes.add(call);
    final ctx = _ctxWith(context, call.internalToken);
    try {
      await _withSlot(() => inner.deleteMany(blobIds, context: ctx));
    } finally {
      _deletes.remove(call);
    }
  }

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    _checkAlive();
    if (blobIds.isEmpty) return {};
    // Presence probe is idempotent and cheap; no per-id dedup needed, just
    // honour the concurrency cap so it queues behind in-flight transfers.
    return _withSlot(() => inner.exists(blobIds, context: context));
  }

  /// Aborts every in-flight call (download, upload, delete) and fails
  /// every pending pool waiter. Idempotent.
  void cancelAll([String reason = 'BlobTransferHub.cancelAll']) {
    for (final task in _downloads.values) {
      task.group?.token.cancel(reason);
    }
    for (final task in _uploads.values) {
      task.batch?.token.cancel(reason);
    }
    for (final call in _deletes) {
      call.internalToken.cancel(reason);
    }
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(
        RpcCancelledException(reason),
      );
    }
  }

  /// Cancels every in-flight call and rejects all further calls. After
  /// dispose the hub is unusable.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancelAll('BlobTransferHub.dispose');
  }

  // ---------------------------------------------------------------- impl

  /// Fetches every id of [tasks] in ONE call, and settles them all from it.
  void _scheduleDownloadGroup(List<_DownloadTask> tasks) {
    if (tasks.isEmpty) return;
    final group = _DownloadGroup(tasks);
    for (final task in tasks) {
      task.group = group;
    }
    final ctx = RpcContext.withCancellation(group.token);
    final ids = [for (final task in tasks) task.id];
    _withSlot(() => inner.download(ids, context: ctx)).then(
      (got) {
        for (final task in tasks) {
          _downloads.remove(task.id);
          if (!task.completer.isCompleted) {
            task.completer.complete(got[task.id]);
          }
        }
      },
      onError: (Object e, StackTrace st) {
        for (final task in tasks) {
          _downloads.remove(task.id);
          if (!task.completer.isCompleted) {
            task.completer.completeError(e, st);
          }
        }
      },
    );
  }

  void _scheduleUploadBatch(_UploadBatch batch) {
    final ctx = RpcContext.withCancellation(batch.token);
    final payload = batch.tasks
        .map((t) => (t.bytes, t.id))
        .toList(growable: false);
    _withSlot(() => inner.upload(payload, context: ctx)).then(
      (_) {
        for (final t in batch.tasks) {
          _uploads.remove(t.id);
          if (!t.completer.isCompleted) t.completer.complete();
        }
      },
      onError: (Object e, StackTrace st) {
        for (final t in batch.tasks) {
          _uploads.remove(t.id);
          if (!t.completer.isCompleted) t.completer.completeError(e, st);
        }
      },
    );
  }

  void _detachDownload(_DownloadTask task) {
    task.subscribers--;
    final group = task.group;
    if (group == null || group.token.isCancelled) return;
    if (group.abandoned) group.token.cancel('last subscriber left');
  }

  void _detachUpload(_UploadTask task) {
    task.subscribers--;
    final batch = task.batch;
    if (batch == null || batch.token.isCancelled) return;
    if (batch.abandoned) batch.token.cancel('last subscriber left');
  }

  Future<T> _withSlot<T>(Future<T> Function() body) async {
    if (_running >= maxConcurrent) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _running++;
    try {
      return await body();
    } finally {
      _running--;
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      }
    }
  }

  Future<T> _awaitWithCaller<T>(
    Future<T> taskFuture,
    RpcCancellationToken? callerToken,
  ) async {
    if (callerToken == null) return taskFuture;
    if (callerToken.isCancelled) {
      throw RpcCancelledException(
        callerToken.reason ?? 'caller cancelled',
      );
    }
    return await Future.any<T>([
      taskFuture,
      callerToken.cancelled.then<T>((_) {
        throw RpcCancelledException(
          callerToken.reason ?? 'caller cancelled',
        );
      }),
    ]);
  }

  RpcContext _ctxWith(RpcContext? base, RpcCancellationToken token) {
    if (base == null) return RpcContext.withCancellation(token);
    return base.withCancellation(token);
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('BlobTransferHub has been disposed');
    }
  }
}

class _DownloadTask {
  _DownloadTask(this.id);

  final String id;
  final Completer<Uint8List?> completer = Completer<Uint8List?>();
  int subscribers = 0;

  /// The in-flight call carrying this id. Several ids share one, so the token
  /// that can cancel it lives on the group, not here.
  _DownloadGroup? group;
}

/// One `inner.download` call and every id it carries.
///
/// The hub used to schedule a call per id, which quietly undid batching done
/// anywhere above it: a caller asking for eight blobs in one list still paid
/// eight round trips. Grouping is what makes the list on the wire mean
/// something.
class _DownloadGroup {
  _DownloadGroup(this.tasks);

  final List<_DownloadTask> tasks;
  final RpcCancellationToken token = RpcCancellationToken();

  /// Nobody is waiting for ANY id in this call any more.
  ///
  /// The per-id cancellation this replaced could not survive grouping: one
  /// caller walking away must not take its neighbours' bytes with it, so the
  /// call dies only when the last of them has.
  bool get abandoned => tasks.every(
        (t) => t.completer.isCompleted || t.subscribers <= 0,
      );
}

class _UploadTask {
  _UploadTask(this.id, this.bytes);

  final String id;
  final Uint8List bytes;
  final Completer<void> completer = Completer<void>();
  int subscribers = 0;
  _UploadBatch? batch;
}

class _UploadBatch {
  _UploadBatch(this.tasks);

  final List<_UploadTask> tasks;
  final RpcCancellationToken token = RpcCancellationToken();

  /// Nobody is waiting for ANY id in this call any more.
  ///
  /// Recomputed rather than counted down. A live-task counter cannot be
  /// decremented safely, because a task at zero subscribers is still in
  /// `_uploads` until it completes and a later caller can join it — after
  /// which the counter is permanently one too low, and the batch is cancelled
  /// out from under someone who IS waiting. Same rule, and the same shape, as
  /// [_DownloadGroup.abandoned].
  bool get abandoned => tasks.every(
        (t) => t.completer.isCompleted || t.subscribers <= 0,
      );
}

class _DeleteCall {
  final RpcCancellationToken internalToken = RpcCancellationToken();
}
