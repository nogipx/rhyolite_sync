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
class BlobTransferHub implements IBlobStorage {
  BlobTransferHub({
    required this.inner,
    this.maxConcurrent = 3,
  }) : assert(maxConcurrent > 0);

  final IBlobStorage inner;
  final int maxConcurrent;

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

    final joined = <String, _DownloadTask>{};
    for (final id in blobIds) {
      var task = _downloads[id];
      if (task == null) {
        task = _DownloadTask(id);
        _downloads[id] = task;
        _scheduleDownload(task);
      }
      task.subscribers++;
      joined[id] = task;
    }

    final callerToken = context?.cancellationToken;
    final result = <String, Uint8List>{};
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
      task.internalToken.cancel(reason);
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

  void _scheduleDownload(_DownloadTask task) {
    final ctx = RpcContext.withCancellation(task.internalToken);
    _withSlot(() => inner.download([task.id], context: ctx)).then(
      (got) {
        _downloads.remove(task.id);
        if (!task.completer.isCompleted) {
          task.completer.complete(got[task.id]);
        }
      },
      onError: (Object e, StackTrace st) {
        _downloads.remove(task.id);
        if (!task.completer.isCompleted) {
          task.completer.completeError(e, st);
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
    if (task.subscribers <= 0 &&
        !task.completer.isCompleted &&
        !task.internalToken.isCancelled) {
      task.internalToken.cancel('last subscriber left');
    }
  }

  void _detachUpload(_UploadTask task) {
    task.subscribers--;
    final batch = task.batch;
    if (batch == null) return;
    if (task.subscribers <= 0) {
      batch.liveTasks--;
      if (batch.liveTasks <= 0 && !batch.token.isCancelled) {
        batch.token.cancel('last subscriber left');
      }
    }
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
  final RpcCancellationToken internalToken = RpcCancellationToken();
  int subscribers = 0;
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
  _UploadBatch(this.tasks) : liveTasks = tasks.length;

  final List<_UploadTask> tasks;
  final RpcCancellationToken token = RpcCancellationToken();
  int liveTasks;
}

class _DeleteCall {
  final RpcCancellationToken internalToken = RpcCancellationToken();
}
