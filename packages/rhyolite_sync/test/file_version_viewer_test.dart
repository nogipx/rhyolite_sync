import 'dart:convert';
import 'dart:typed_data';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart' show RpcContext;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

const _v = '12345678-1234-4abc-8def-1234567890ab';

class _FakeCipher implements IVaultCipher {
  @override
  Future<Uint8List> encrypt(Uint8List p) async => p;
  @override
  Future<Uint8List> decrypt(Uint8List c) async => c;
}

class _MemBlobStorage implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  @override
  Future<Set<String>> exists(List<String> blobIds, {RpcContext? context}) async =>
      {for (final id in blobIds) if (store.containsKey(id)) id};
  @override
  Future<void> deleteMany(List<String> ids, {RpcContext? context}) async {
    for (final id in ids) store.remove(id);
  }

  @override
  Future<Map<String, Uint8List>> download(
    List<String> ids, {
    RpcContext? context,
  }) async => {
    for (final id in ids)
      if (store.containsKey(id)) id: store[id]!,
  };
  @override
  Future<void> upload(List<(Uint8List, String)> blobs, {RpcContext? context}) async {
    for (final (bytes, id) in blobs) store[id] = bytes;
  }
}

class _MemIO implements IPlatformIO {
  final Map<String, Uint8List> files = {};
  @override
  Future<Uint8List> readFile(String p) async =>
      files[p] ?? (throw StateError('no file $p'));
  @override
  Future<bool> fileExists(String p) async => files.containsKey(p);
  @override
  Future<bool> dirExists(String p) async => true;
  @override
  Future<List<String>> listFiles(String p) async =>
      files.keys.where((k) => k.startsWith('$p/')).toList();
  @override
  Future<void> writeFile(String p, Uint8List b) async => files[p] = b;
  @override
  Future<void> deleteFile(String p) async => files.remove(p);
  @override
  Future<void> moveFile(String f, String t) async {
    final b = files.remove(f);
    if (b != null) files[t] = b;
  }

  @override
  Future<void> deleteEmptyDirsUpTo(String d, String s) async {}
  @override
  Future<FileStatInfo?> statFile(String p) async => null;
}

class _NoopChangeProvider implements IChangeProvider {
  @override
  Stream<FileChangeEvent> get changes => const Stream.empty();
  @override
  Stream<String> get typing => const Stream.empty();
  @override
  void suppress(
    String path, {
    int count = 1,
    Duration holdFor = const Duration(seconds: 2),
  }) {}

  @override
  void unsuppress(String path) {}
}

class _FakeHistory implements IHistoryContract {
  final List<HistoryEvent> events = [];

  @override
  Future<HistoryGetResponse> getHistory(
    HistoryGetRequest request, {
    RpcContext? context,
  }) async {
    final filtered = events.where((e) {
      if (request.fileId != null && e.fileId != request.fileId) return false;
      return true;
    }).toList();
    filtered.sort(
      (a, b) => request.ascending
          ? a.hlcPacked.compareTo(b.hlcPacked)
          : b.hlcPacked.compareTo(a.hlcPacked),
    );
    return HistoryGetResponse(
      events: filtered.take(request.limit).toList(),
      epoch: 0,
    );
  }

  @override
  Future<HistoryDeleteEventsResponse> deleteEvents(
    HistoryDeleteEventsRequest req, {
    RpcContext? context,
  }) async => const HistoryDeleteEventsResponse(deleted: 0);

  @override
  Future<ReportHistoryHeadResponse> reportHistoryHead(
    ReportHistoryHeadRequest req, {
    RpcContext? context,
  }) async => const ReportHistoryHeadResponse();

  @override
  Future<GetHistoryHeadsResponse> getHistoryHeads(
    GetHistoryHeadsRequest req, {
    RpcContext? context,
  }) async => const GetHistoryHeadsResponse(heads: []);
}

String _meta(String path, int size) =>
    base64Encode(utf8.encode(jsonEncode({'path': path, 'sizeBytes': size})));

HistoryEvent _evt({
  required String id,
  required String fileId,
  required String hlc,
  required HistoryOperation op,
  required String blobRef,
  required int createdAtMs,
  required String path,
  required int size,
}) => HistoryEvent(
  eventId: id,
  fileId: fileId,
  blobRef: blobRef,
  hlcPacked: hlc,
  operation: op,
  encryptedMeta: _meta(path, size),
  createdAtMs: createdAtMs,
);

void main() {
  late _FakeHistory fakeHistory;
  late _MemBlobStorage remote;
  late LocalBlobStore localStore;
  late _MemIO io;
  late _NoopChangeProvider changes;
  late FileVersionViewer viewer;
  late HistoryBrowser browser;
  const vaultPath = '/vault';

  setUp(() {
    fakeHistory = _FakeHistory();
    remote = _MemBlobStorage();
    localStore = LocalBlobStore(InMemoryBlobRepository());
    io = _MemIO();
    changes = _NoopChangeProvider();
    browser = HistoryBrowser(
      historyCaller: fakeHistory,
      cipher: _FakeCipher(),
      vaultId: _v,
    );
    viewer = FileVersionViewer(
      browser: browser,
      remoteBlobStorage: remote,
      localBlobStore: localStore,
      io: io,
      changeProvider: changes,
      vaultPath: vaultPath,
      vaultId: _v,
    );
  });

  String fid(String path) => const Uuid().v5(_v, path);

  test('versionsOf returns events only for the given path', () async {
    fakeHistory.events.add(
      _evt(
        id: 'a',
        fileId: fid('notes/a.md'),
        hlc: '100-0-A',
        op: HistoryOperation.create,
        blobRef: 'sha-a1',
        createdAtMs: 1,
        path: 'notes/a.md',
        size: 10,
      ),
    );
    fakeHistory.events.add(
      _evt(
        id: 'b',
        fileId: fid('notes/b.md'),
        hlc: '110-0-A',
        op: HistoryOperation.create,
        blobRef: 'sha-b1',
        createdAtMs: 2,
        path: 'notes/b.md',
        size: 12,
      ),
    );
    fakeHistory.events.add(
      _evt(
        id: 'a2',
        fileId: fid('notes/a.md'),
        hlc: '200-0-A',
        op: HistoryOperation.modify,
        blobRef: 'sha-a2',
        createdAtMs: 3,
        path: 'notes/a.md',
        size: 20,
      ),
    );

    final v = await viewer.versionsOf('notes/a.md');
    expect(v.length, 2);
    expect(v.first.eventId, 'a2'); // newest first
    expect(v.last.eventId, 'a');
  });

  test('contentAt downloads from remote when not in local cache', () async {
    final body = Uint8List.fromList(utf8.encode('hello world'));
    remote.store['sha-x'] = body;
    final entry = HistoryEntry(
      eventId: 'e',
      fileId: 'f1',
      path: 'a.md',
      sizeBytes: 11,
      blobRef: 'sha-x',
      operation: HistoryOperation.modify,
      createdAt: DateTime.now(),
      hlc: Hlc(1, 0, 'A'),
    );

    final result = await viewer.contentAt(entry);
    expect(result, isNotNull);
    expect(utf8.decode(result!), 'hello world');

    // Also self-heals into the local cache for next time.
    final cached = await localStore.read('sha-x', vaultId: _v);
    expect(cached, isNotNull);
  });

  test('contentAt returns null when blob is gone everywhere', () async {
    final entry = HistoryEntry(
      eventId: 'e',
      fileId: 'f1',
      path: 'a.md',
      sizeBytes: 1,
      blobRef: 'sha-missing',
      operation: HistoryOperation.modify,
      createdAt: DateTime.now(),
      hlc: Hlc(1, 0, 'A'),
    );
    final result = await viewer.contentAt(entry);
    expect(result, isNull);
  });

  test(
    'restore writes the version content to disk at the recorded path',
    () async {
      final v1 = Uint8List.fromList(utf8.encode('original'));
      remote.store['sha-v1'] = v1;
      // Disk currently has a different version.
      io.files['$vaultPath/note.md'] = Uint8List.fromList(utf8.encode('newer'));

      final entry = HistoryEntry(
        eventId: 'e',
        fileId: fid('note.md'),
        path: 'note.md',
        sizeBytes: 8,
        blobRef: 'sha-v1',
        operation: HistoryOperation.modify,
        createdAt: DateTime.now(),
        hlc: Hlc(1, 0, 'A'),
      );

      await viewer.restore(entry);

      expect(utf8.decode(io.files['$vaultPath/note.md']!), 'original');
    },
  );

  test('restore throws when blob is no longer available', () async {
    final entry = HistoryEntry(
      eventId: 'e',
      fileId: fid('x.md'),
      path: 'x.md',
      sizeBytes: 1,
      blobRef: 'sha-gone',
      operation: HistoryOperation.modify,
      createdAt: DateTime.now(),
      hlc: Hlc(1, 0, 'A'),
    );
    expect(() => viewer.restore(entry), throwsStateError);
  });
}
