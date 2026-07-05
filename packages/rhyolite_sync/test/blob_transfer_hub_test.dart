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
  Future<Set<String>> exists(List<String> blobIds, {RpcContext? context}) async =>
      {for (final id in blobIds) if (bytes.containsKey(id)) id};
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
  Future<void> deleteMany(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    deleteCalls++;
    context?.cancellationToken?.throwIfCancelled();
    for (final id in blobIds) {
      bytes.remove(id);
    }
  }
}

void main() {
  group('BlobTransferHub', () {
    test('dedups concurrent downloads of the same blob into one inner call',
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
      expect(storage.downloadCalls, 1,
          reason: 'second download must subscribe, not re-fetch');
    });

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

    test('caller cancellation detaches without killing shared task',
        () async {
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
      final fA =
          hub.download(['x'], context: RpcContext.withCancellation(tokenA));
      final fB =
          hub.download(['x'], context: RpcContext.withCancellation(tokenB));
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
      final gates = ['a', 'b', 'c']
          .map((id) => MapEntry(id, storage.downloadGate(id)))
          .toList();
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

    test('disposed hub rejects new calls', () async {
      final hub = BlobTransferHub(inner: _ControllableStorage());
      hub.dispose();
      expect(() => hub.download(['x']), throwsStateError);
      expect(() => hub.upload([(Uint8List(0), 'x')]), throwsStateError);
      expect(() => hub.deleteMany(['x']), throwsStateError);
    });
  });
}
