import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart' show RpcContext;
import 'package:test/test.dart';

class _FakeCipher implements IVaultCipher {
  // "Encryption" here is just identity — we trust the unit-test boundary.
  // The test harness encrypts JSON by encoding it as UTF-8 bytes; the
  // browser decodes them back to the same JSON.
  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async => plaintext;

  @override
  Future<Uint8List> decrypt(Uint8List ciphertext) async => ciphertext;
}

class _FakeHistory implements IHistoryContract {
  final List<HistoryEvent> events = [];

  @override
  Future<HistoryGetResponse> getHistory(
    HistoryGetRequest request, {
    RpcContext? context,
  }) async {
    final all = events.where((e) {
      if (request.fileId != null && e.fileId != request.fileId) return false;
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
  }) async => const HistoryDeleteEventsResponse(deleted: 0);

  @override
  Future<ReportHistoryHeadResponse> reportHistoryHead(
    ReportHistoryHeadRequest request, {
    RpcContext? context,
  }) async => const ReportHistoryHeadResponse();

  @override
  Future<GetHistoryHeadsResponse> getHistoryHeads(
    GetHistoryHeadsRequest request, {
    RpcContext? context,
  }) async => const GetHistoryHeadsResponse(heads: []);
}

String _encMeta(String path, int size, {bool tombstone = false}) {
  final payload = {
    'path': path,
    'sizeBytes': size,
    'blobRef': 'sha-x',
    if (tombstone) 'tombstone': true,
  };
  return base64Encode(utf8.encode(jsonEncode(payload)));
}

HistoryEvent _evt({
  required String id,
  required String fileId,
  required String hlc,
  required HistoryOperation op,
  required String blobRef,
  required int createdAtMs,
  required String path,
  int size = 100,
}) => HistoryEvent(
  eventId: id,
  fileId: fileId,
  blobRef: blobRef,
  hlcPacked: hlc,
  operation: op,
  encryptedMeta: _encMeta(path, size, tombstone: op == HistoryOperation.delete),
  createdAtMs: createdAtMs,
);

void main() {
  late _FakeHistory fakeHistory;
  late HistoryBrowser browser;

  setUp(() {
    fakeHistory = _FakeHistory();
    browser = HistoryBrowser(
      historyCaller: fakeHistory,
      cipher: _FakeCipher(),
      vaultId: 'v1',
    );
  });

  test('decrypts encryptedMeta into path + sizeBytes', () async {
    fakeHistory.events.add(
      _evt(
        id: 'e1',
        fileId: 'fA',
        hlc: '100-0-A',
        op: HistoryOperation.create,
        blobRef: 'sha-A',
        createdAtMs: 1700000000000,
        path: 'notes/important.md',
        size: 1234,
      ),
    );
    final list = await browser.list();
    expect(list.length, 1);
    expect(list.single.path, 'notes/important.md');
    expect(list.single.sizeBytes, 1234);
    expect(list.single.operation, HistoryOperation.create);
    expect(list.single.blobRef, 'sha-A');
  });

  test('returns entries in newest-first order by default', () async {
    fakeHistory.events.add(
      _evt(
        id: 'old',
        fileId: 'fA',
        hlc: '100-0-A',
        op: HistoryOperation.create,
        blobRef: 'sha-1',
        createdAtMs: 100,
        path: 'a.md',
      ),
    );
    fakeHistory.events.add(
      _evt(
        id: 'newest',
        fileId: 'fA',
        hlc: '300-0-A',
        op: HistoryOperation.modify,
        blobRef: 'sha-3',
        createdAtMs: 300,
        path: 'a.md',
      ),
    );
    fakeHistory.events.add(
      _evt(
        id: 'mid',
        fileId: 'fA',
        hlc: '200-0-A',
        op: HistoryOperation.modify,
        blobRef: 'sha-2',
        createdAtMs: 200,
        path: 'a.md',
      ),
    );
    final list = await browser.list();
    expect(list.map((e) => e.eventId).toList(), ['newest', 'mid', 'old']);
  });

  test('filters by fileId', () async {
    fakeHistory.events.add(
      _evt(
        id: 'a',
        fileId: 'fA',
        hlc: '100-0-A',
        op: HistoryOperation.create,
        blobRef: 'sha-A',
        createdAtMs: 100,
        path: 'a.md',
      ),
    );
    fakeHistory.events.add(
      _evt(
        id: 'b',
        fileId: 'fB',
        hlc: '110-0-A',
        op: HistoryOperation.create,
        blobRef: 'sha-B',
        createdAtMs: 110,
        path: 'b.md',
      ),
    );
    final onlyA = await browser.list(fileId: 'fA');
    expect(onlyA.length, 1);
    expect(onlyA.single.fileId, 'fA');
  });

  test('skips entries whose encryptedMeta cannot be parsed', () async {
    fakeHistory.events.add(
      _evt(
        id: 'good',
        fileId: 'fA',
        hlc: '100-0-A',
        op: HistoryOperation.create,
        blobRef: 'sha-G',
        createdAtMs: 100,
        path: 'a.md',
      ),
    );
    fakeHistory.events.add(
      HistoryEvent(
        eventId: 'broken',
        fileId: 'fA',
        blobRef: 'sha-B',
        hlcPacked: '200-0-A',
        operation: HistoryOperation.modify,
        encryptedMeta: base64Encode([1, 2, 3]), // not valid utf8 JSON
        createdAtMs: 200,
      ),
    );
    final list = await browser.list();
    expect(list.map((e) => e.eventId).toList(), ['good']);
  });

  test('limit caps the number of returned entries', () async {
    for (var i = 0; i < 20; i++) {
      fakeHistory.events.add(
        _evt(
          id: 'e$i',
          fileId: 'fA',
          hlc: '${100 + i}-0-A',
          op: HistoryOperation.modify,
          blobRef: 'sha-$i',
          createdAtMs: 100 + i,
          path: 'a.md',
        ),
      );
    }
    final list = await browser.list(limit: 5);
    expect(list.length, 5);
  });
}
