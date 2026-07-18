import 'dart:typed_data';

import 'package:convergent/convergent.dart' show Hlc;
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

class _FakeIO implements IPlatformIO {
  final writes = <String, Uint8List>{};
  @override
  Future<void> writeFile(String absolutePath, Uint8List bytes) async {
    writes[absolutePath] = bytes;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

StateRecord _rec(String fileId, {int seq = 1}) => StateRecord(
      fileId: fileId,
      encryptedState: 'enc-$fileId-$seq',
      blobRef: 'ref-$fileId-$seq',
      hlcPacked: 'h$seq',
      contextPacked: '',
      serverSeq: seq,
      tombstone: false,
    );

FileState _fs(String path, String blobRef, {bool tombstone = false, int ms = 1}) =>
    FileState(
      fileId: 'id',
      path: path,
      blobRef: blobRef,
      sizeBytes: 0,
      hlc: Hlc(ms, 0, 'x'),
      tombstone: tombstone,
    );

void main() {
  test('restores files in place; skips tombstones; resolves concurrent by LWW',
      () async {
    final io = _FakeIO();
    final records = [
      _rec('a'),
      _rec('b'),
      _rec('c', seq: 1),
      _rec('c', seq: 2), // concurrent versions → LWW winner (max HLC) wins
    ];
    final byEnvelope = <String, FileState>{
      'enc-a-1': _fs('notes/a.md', 'ref-a-1'),
      'enc-b-1': _fs('notes/b.md', '', tombstone: true),
      'enc-c-1': _fs('notes/c.md', 'ref-c-1', ms: 1),
      'enc-c-2': _fs('notes/c.md', 'ref-c-2', ms: 2), // higher HLC → winner
    };
    final blobs = <String, Uint8List>{
      'ref-a-1': Uint8List.fromList([1, 2, 3]),
      'ref-c-2': Uint8List.fromList([9]), // winner content
    };

    final report = await RestoreBackupUseCase(
      records: records,
      decodeRecord: (r) async => byEnvelope[r.encryptedState]!,
      downloadContent: (ref, path) async => blobs[ref],
      targetIO: io,
      targetRoot: 'vault',
    )();

    expect(report.restoredFiles, 2); // a.md + c.md (LWW winner)
    expect(report.skippedTombstones, 1);
    expect(report.success, isTrue);
    expect(io.writes.keys, unorderedEquals(['vault/notes/a.md', 'vault/notes/c.md']));
    expect(io.writes['vault/notes/c.md'], [9]); // winner, not ref-c-1
  });

  test('a file identical to the current vault is skipped (no churn)', () async {
    final io = _FakeIO();
    final byEnvelope = <String, FileState>{
      'enc-a-1': _fs('a.md', 'ref-a-1'), // same as current → skip
      'enc-b-1': _fs('b.md', 'ref-b-1'), // differs → restore
    };
    final report = await RestoreBackupUseCase(
      records: [_rec('a'), _rec('b')],
      decodeRecord: (r) async => byEnvelope[r.encryptedState]!,
      downloadContent: (ref, path) async => Uint8List.fromList([7]),
      targetIO: io,
      targetRoot: 'vault',
      currentLiveBlobByPath: const {
        'a.md': 'ref-a-1', // identical
        'b.md': 'ref-b-OLD', // differs
      },
    )();

    expect(report.restoredFiles, 1);
    expect(report.skippedIdentical, 1);
    expect(io.writes.keys, ['vault/b.md']);
  });

  test('a missing blob is reported without aborting the rest', () async {
    final io = _FakeIO();
    final byEnvelope = <String, FileState>{
      'enc-a-1': _fs('a.md', 'ref-a-1'),
      'enc-b-1': _fs('b.md', 'ref-b-1'),
    };
    final report = await RestoreBackupUseCase(
      records: [_rec('a'), _rec('b')],
      decodeRecord: (r) async => byEnvelope[r.encryptedState]!,
      downloadContent: (ref, path) async =>
          ref == 'ref-a-1' ? Uint8List.fromList([9]) : null, // b unavailable
      targetIO: io,
      targetRoot: 'r',
    )();

    expect(report.restoredFiles, 1);
    expect(report.errors, hasLength(1));
    expect(report.success, isFalse);
    expect(io.writes.keys, ['r/a.md']);
  });
}
