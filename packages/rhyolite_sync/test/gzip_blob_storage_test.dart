import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class _Memory implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  @override
  Future<Set<String>> exists(List<String> blobIds, {RpcContext? context}) async =>
      {for (final id in blobIds) if (store.containsKey(id)) id};

  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    RpcContext? context,
  }) async {
    for (final (b, id) in blobs) {
      store[id] = b;
    }
  }

  @override
  Future<Map<String, Uint8List>> download(
    List<String> ids, {
    RpcContext? context,
  }) async =>
      {for (final id in ids) if (store.containsKey(id)) id: store[id]!};

  @override
  Future<void> deleteMany(
    List<String> ids, {
    RpcContext? context,
  }) async {
    for (final id in ids) {
      store.remove(id);
    }
  }
}

void main() {
  group('GzipBlobStorage', () {
    test('roundtrips a compressible payload', () async {
      final mem = _Memory();
      final gz = GzipBlobStorage(inner: mem);

      // Highly compressible: 50KB of one repeated character.
      final payload = Uint8List.fromList(List<int>.filled(50000, 0x41));
      await gz.upload([(payload, 'a')]);

      // Inner storage should hold compressed bytes, much shorter.
      expect(mem.store['a']!.length, lessThan(payload.length ~/ 10));

      final out = await gz.download(['a']);
      expect(out['a'], payload);
    });

    test('roundtrips a Fugue-like JSON payload', () async {
      final mem = _Memory();
      final gz = GzipBlobStorage(inner: mem);

      // Mimic a v3 Fugue blob shape — long array of similar entries.
      final entries = <List<Object?>>[];
      for (var i = 0; i < 500; i++) {
        entries.add([1234567890 + i, 0, 0, null, null, null, 0, 'x']);
      }
      final payload = Uint8List.fromList(
        utf8.encode(jsonEncode({'v': 3, 'n': ['dev-A'], 'c': entries})),
      );

      await gz.upload([(payload, 'fugue')]);

      final compressed = mem.store['fugue']!;
      expect(compressed.length, lessThan(payload.length ~/ 2),
          reason: 'Fugue JSON should compress at least 2x');

      final out = await gz.download(['fugue']);
      expect(out['fugue'], payload);
    });

    test('passes pre-existing non-gzip blobs through on download', () async {
      final mem = _Memory();
      // Simulate a blob written before the decorator was added: raw
      // bytes in inner storage, no gzip header.
      final legacy = Uint8List.fromList(utf8.encode('legacy raw payload'));
      mem.store['legacy'] = legacy;

      final gz = GzipBlobStorage(inner: mem);
      final out = await gz.download(['legacy']);
      expect(out['legacy'], legacy);
    });

    test('upload writes gzip-magic bytes to inner', () async {
      final mem = _Memory();
      final gz = GzipBlobStorage(inner: mem);
      await gz.upload([(Uint8List.fromList(utf8.encode('hello')), 'h')]);
      final stored = mem.store['h']!;
      expect(stored[0], 0x1f);
      expect(stored[1], 0x8b);
    });

    test('deleteMany passes through', () async {
      final mem = _Memory();
      mem.store['x'] = Uint8List(1);
      final gz = GzipBlobStorage(inner: mem);
      await gz.deleteMany(['x']);
      expect(mem.store.containsKey('x'), isFalse);
    });

    test('respects cancellation between blobs on upload', () async {
      final mem = _Memory();
      final gz = GzipBlobStorage(inner: mem);
      final token = RpcCancellationToken.cancelled('test');
      final ctx = RpcContext.withCancellation(token);
      await expectLater(
        gz.upload([
          (Uint8List.fromList([1, 2, 3]), 'a'),
        ], context: ctx),
        throwsA(isA<RpcCancelledException>()),
      );
    });
  });
}
