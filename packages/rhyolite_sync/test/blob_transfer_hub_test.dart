import 'dart:async';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Controllable in-memory blob storage. Each upload/download blocks on a
/// per-id Completer the test can drive.
class _ControllableStorage implements IBlobStorage {
  final Map<String, Uint8List> bytes = {};

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    RpcContext? context,
  }) async => {
    for (final id in blobIds)
      if (bytes.containsKey(id)) id,
  };
  int uploadCalls = 0;
  int downloadCalls = 0;
  int deleteCalls = 0;

  final Map<String, Completer<void>> _uploadGates = {};
  final Map<String, Completer<void>> _downloadGates = {};

  /// Set this to make every upload/download await `gate.future` before
  /// completing — gives the test deterministic control over in-flight
  /// state and order.
  Completer<void> uploadGate(String id) =>
      _uploadGates.putIfAbsent(id, Completer<void>.new);
  Completer<void> downloadGate(String id) =>
      _downloadGates.putIfAbsent(id, Completer<void>.new);

  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    RpcContext? context,
  }) async {
    uploadCalls++;
    for (final (b, id) in blobs) {
      final gate = _uploadGates[id];
      if (gate != null) {
        await Future.any([
          gate.future,
          context?.cancellationToken?.cancelled.then((_) {
                throw RpcCancelledException('cancelled');
              }) ??
              Completer<void>().future,
        ]);
      }
      context?.cancellationToken?.throwIfCancelled();
      bytes[id] = b;
    }
  }

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    downloadCalls++;
    final out = <String, Uint8List>{};
    for (final id in blobIds) {
      final gate = _downloadGates[id];
      if (gate != null) {
        await Future.any([
          gate.future,
          context?.cancellationToken?.cancelled.then((_) {
                throw RpcCancelledException('cancelled');
              }) ??
              Completer<void>().future,
        ]);
      }
      context?.cancellationToken?.throwIfCancelled();
      if (bytes.containsKey(id)) out[id] = bytes[id]!;
    }
    return out;
  }

  @override
  Future<void> deleteMany(List<String> blobIds, {RpcContext? context}) async {
    deleteCalls++;
    context?.cancellationToken?.throwIfCancelled();
    for (final id in blobIds) {
      bytes.remove(id);
    }
  }
}

void main() {
  group('BlobTransferHub', () {
    // -----------------------------------------------------------------------
    // A dispose mid-transfer must not spray unhandled errors.
    //
    // upload/download await their tasks one at a time, while `cancelAll` fails
    // them all at once: the first await throws, the loop exits, and every
    // remaining task holds an error with no listener. A real first sync
    // produced about thirty of these per dispose, and they buried the failure
    // that had caused the dispose in the first place.
    // -----------------------------------------------------------------------
    test('dispose during an upload orphans no errors', () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final storage = _ControllableStorage();
        final hub = BlobTransferHub(inner: storage);
        final bytes = Uint8List.fromList([1]);
        // Five tasks in one call: one is awaited when dispose lands, four are
        // still queued behind it and are exactly what used to leak.
        final ids = ['a', 'b', 'c', 'd', 'e'];
        for (final id in ids) {
          storage.uploadGate(id);
        }

        final f = hub.upload([for (final id in ids) (bytes, id)]);
        await Future<void>.delayed(Duration.zero);
        hub.dispose();

        await expectLater(f, throwsA(isA<RpcCancelledException>()));
        // Let anything orphaned reach the zone before we look.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }, (e, _) => errors.add(e));

      expect(errors, isEmpty, reason: 'errors reaching the zone are orphans');
    });

    test('dispose during a download orphans no errors', () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final storage = _ControllableStorage();
        final hub = BlobTransferHub(inner: storage);
        final ids = ['a', 'b', 'c', 'd', 'e'];
        for (final id in ids) {
          storage.bytes[id] = Uint8List.fromList([1]);
          storage.downloadGate(id);
        }

        final f = hub.download(ids);
        await Future<void>.delayed(Duration.zero);
        hub.dispose();

        await expectLater(f, throwsA(isA<RpcCancelledException>()));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }, (e, _) => errors.add(e));

      expect(errors, isEmpty, reason: 'errors reaching the zone are orphans');
    });

    test(
      'dedups concurrent downloads of the same blob into one inner call',
      () async {
        final storage = _ControllableStorage();
        storage.bytes['x'] = Uint8List.fromList([1, 2, 3]);
        final gate = storage.downloadGate('x');

        final hub = BlobTransferHub(inner: storage);

        final f1 = hub.download(['x']);
        final f2 = hub.download(['x']);
        await Future<void>.delayed(Duration.zero);

        gate.complete();
        final r1 = await f1;
        final r2 = await f2;

        expect(r1['x'], [1, 2, 3]);
        expect(r2['x'], [1, 2, 3]);
        expect(
          storage.downloadCalls,
          1,
          reason: 'second download must subscribe, not re-fetch',
        );
      },
    );

    test('dedups concurrent uploads of the same blob id', () async {
      final storage = _ControllableStorage();
      final gate = storage.uploadGate('x');

      final hub = BlobTransferHub(inner: storage);
      final bytes = Uint8List.fromList([1]);

      final f1 = hub.upload([(bytes, 'x')]);
      final f2 = hub.upload([(bytes, 'x')]);
      await Future<void>.delayed(Duration.zero);

      gate.complete();
      await f1;
      await f2;

      expect(storage.uploadCalls, 1);
    });

    test('caller cancellation detaches without killing shared task', () async {
      final storage = _ControllableStorage();
      storage.bytes['x'] = Uint8List.fromList([7]);
      final gate = storage.downloadGate('x');

      final hub = BlobTransferHub(inner: storage);

      final aToken = RpcCancellationToken();
      final ctxA = RpcContext.withCancellation(aToken);
      final fA = hub.download(['x'], context: ctxA);
      final fB = hub.download(['x']);
      await Future<void>.delayed(Duration.zero);

      aToken.cancel('A bored');

      await expectLater(fA, throwsA(isA<RpcCancelledException>()));

      // B is still alive; storage should not have been cancelled.
      gate.complete();
      final r = await fB;
      expect(r['x'], [7]);
      expect(storage.downloadCalls, 1);
    });

    test('last subscriber leaving fires real cancellation', () async {
      final storage = _ControllableStorage();
      storage.bytes['x'] = Uint8List.fromList([1]);
      storage.downloadGate('x'); // blocks until cancelled

      final hub = BlobTransferHub(inner: storage);

      final tokenA = RpcCancellationToken();
      final tokenB = RpcCancellationToken();
      final fA = hub.download([
        'x',
      ], context: RpcContext.withCancellation(tokenA));
      final fB = hub.download([
        'x',
      ], context: RpcContext.withCancellation(tokenB));
      await Future<void>.delayed(Duration.zero);

      tokenA.cancel();
      tokenB.cancel();

      await expectLater(fA, throwsA(isA<RpcCancelledException>()));
      await expectLater(fB, throwsA(isA<RpcCancelledException>()));
    });

    test('cancelAll aborts in-flight + pending', () async {
      final storage = _ControllableStorage();
      storage.downloadGate('a');
      storage.downloadGate('b');
      storage.downloadGate('c');
      storage.downloadGate('d');

      final hub = BlobTransferHub(inner: storage, maxConcurrent: 2);

      final fA = hub.download(['a']);
      final fB = hub.download(['b']);
      final fC = hub.download(['c']); // waits for slot
      final fD = hub.download(['d']); // waits for slot

      await Future<void>.delayed(Duration.zero);

      hub.cancelAll();

      await expectLater(fA, throwsA(isA<RpcCancelledException>()));
      await expectLater(fB, throwsA(isA<RpcCancelledException>()));
      await expectLater(fC, throwsA(isA<RpcCancelledException>()));
      await expectLater(fD, throwsA(isA<RpcCancelledException>()));
    });

    test('respects maxConcurrent', () async {
      final storage = _ControllableStorage();
      final gates = [
        'a',
        'b',
        'c',
      ].map((id) => MapEntry(id, storage.downloadGate(id))).toList();
      for (final e in gates) {
        storage.bytes[e.key] = Uint8List.fromList([1]);
      }

      final hub = BlobTransferHub(inner: storage, maxConcurrent: 2);

      final fa = hub.download(['a']);
      final fb = hub.download(['b']);
      final fc = hub.download(['c']);

      await Future<void>.delayed(Duration.zero);
      // Only first two should have entered inner.download.
      expect(storage.downloadCalls, 2);

      gates[0].value.complete();
      await fa;
      await Future<void>.delayed(Duration.zero);
      expect(storage.downloadCalls, 3);

      gates[1].value.complete();
      gates[2].value.complete();
      await fb;
      await fc;
    });

    test('one call for many ids stays ONE call to the backend', () async {
      // The hub used to open a task, and therefore a request, per id — which
      // silently undid any batching done above it. Everything upstream can ask
      // for eight blobs in one list and still pay eight round trips.
      final storage = _ControllableStorage();
      for (var i = 0; i < 8; i++) {
        storage.bytes['b$i'] = Uint8List.fromList([i]);
      }
      final hub = BlobTransferHub(inner: storage);
      addTearDown(hub.dispose);

      final got = await hub.download([for (var i = 0; i < 8; i++) 'b$i']);

      expect(got.length, 8, reason: 'every id must still come back');
      expect(
        storage.downloadCalls,
        1,
        reason: 'the list is the point — one request, not one per id',
      );
    });

    test(
      'an id already in flight joins its call instead of opening another',
      () async {
        // Dedup is the hub's other job and grouping must not cost it: a second
        // caller wanting a blob someone is already fetching still waits on that
        // fetch.
        final storage = _ControllableStorage();
        storage.bytes['shared'] = Uint8List.fromList([1]);
        storage.bytes['other'] = Uint8List.fromList([2]);
        final gate = storage.downloadGate('shared');
        final hub = BlobTransferHub(inner: storage);
        addTearDown(hub.dispose);

        final first = hub.download(['shared']);
        await Future<void>.delayed(Duration.zero);
        expect(storage.downloadCalls, 1);

        // 'shared' joins the in-flight call; only 'other' is new.
        final second = hub.download(['shared', 'other']);
        await Future<void>.delayed(Duration.zero);
        expect(
          storage.downloadCalls,
          2,
          reason: 'one more call for the fresh id, not for the joined one',
        );

        gate.complete();
        expect((await first)['shared'], isNotNull);
        expect((await second).keys.toSet(), {'shared', 'other'});
      },
    );

    test('one caller walking away does not cancel its neighbours in the '
        'same call', () async {
      // Cancellation used to be per id, which grouping cannot keep: the tasks
      // now share a request, so honouring the first abandoned id would take
      // the others' bytes with it. The call dies only when the last waiter
      // has gone.
      final storage = _ControllableStorage();
      storage.bytes['keep'] = Uint8List.fromList([1]);
      storage.bytes['leave'] = Uint8List.fromList([2]);
      final gate = storage.downloadGate('keep');
      final hub = BlobTransferHub(inner: storage);
      addTearDown(hub.dispose);

      final staying = hub.download(['keep', 'leave']);
      await Future<void>.delayed(Duration.zero);

      // A second caller asks for one of them and immediately gives up.
      final leaving = RpcCancellationToken();
      final abandoned = hub.download([
        'leave',
      ], context: RpcContext.withCancellation(leaving));
      leaving.cancel('gone');
      await abandoned.then((_) {}, onError: (_) {});
      await Future<void>.delayed(Duration.zero);

      gate.complete();
      final got = await staying;
      expect(
        got.keys.toSet(),
        {'keep', 'leave'},
        reason:
            'the caller that stayed must still get everything it asked '
            'for, including the id the other one abandoned',
      );
    });

    test(
      'a rejoined upload is not cancelled when the OTHER ids leave',
      () async {
        // The batch used to count live tasks down, decrementing whenever a task
        // reached zero subscribers. But a task stays in the map until it
        // completes, so it can be joined again afterwards — and then reach zero
        // a second time, decrementing twice for one slot. The count hits zero
        // while somebody is still waiting, and their upload is cancelled.
        //
        // Reaching it needs three callers: one to put both ids in a batch, one
        // to keep the second id alive while the first drops to zero, and one to
        // rejoin the first.
        final storage = _ControllableStorage();
        final gate = storage.uploadGate('a'); // keeps the call in flight
        final hub = BlobTransferHub(inner: storage);
        addTearDown(hub.dispose);

        final bytesA = Uint8List.fromList([1]);
        final bytesB = Uint8List.fromList([2]);

        final tokenX = RpcCancellationToken();
        final x = hub.upload([
          (bytesA, 'a'),
          (bytesB, 'b'),
        ], context: RpcContext.withCancellation(tokenX));
        await Future<void>.delayed(Duration.zero);

        // W keeps 'b' subscribed, so X leaving cannot take the batch down.
        final tokenW = RpcCancellationToken();
        final w = hub.upload([
          (bytesB, 'b'),
        ], context: RpcContext.withCancellation(tokenW));
        await Future<void>.delayed(Duration.zero);

        // X goes: 'a' reaches zero subscribers (one decrement), 'b' does not.
        tokenX.cancel('gone');
        await x.then((_) {}, onError: (_) {});
        await Future<void>.delayed(Duration.zero);

        // Z comes back for 'a'. Invisible to a counter already decremented.
        final z = hub.upload([(bytesA, 'a')]);
        await Future<void>.delayed(Duration.zero);

        // W goes: 'b' reaches zero. Under the counter that is the second
        // decrement of a two-slot batch — cancel, with Z still waiting.
        tokenW.cancel('gone');
        await w.then((_) {}, onError: (_) {});
        await Future<void>.delayed(Duration.zero);

        gate.complete();
        await z;
        expect(
          storage.bytes['a'],
          isNotNull,
          reason:
              'Z was waiting on this upload and nothing had a right to '
              'cancel it',
        );
      },
    );

    test('disposed hub rejects new calls', () async {
      final hub = BlobTransferHub(inner: _ControllableStorage());
      hub.dispose();
      // A distinct type, not a StateError: callers need to tell "the session
      // that owned this hub is gone" from a transient failure, and the startup
      // diff decides whether to abort on exactly that. Matching a message
      // string instead would be one rewording away from grinding on.
      const disposed = TypeMatcher<BlobTransferHubDisposed>();
      expect(() => hub.download(['x']), throwsA(disposed));
      expect(() => hub.upload([(Uint8List(0), 'x')]), throwsA(disposed));
      expect(() => hub.deleteMany(['x']), throwsA(disposed));
    });
  });
}
