import 'package:convergent/convergent.dart' show Hlc;
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

StateRecord _rec(String fileId, {int seq = 1}) => StateRecord(
      fileId: fileId,
      encryptedState: 'enc-$fileId-$seq',
      blobRef: 'ref-$fileId-$seq',
      hlcPacked: 'h$seq',
      contextPacked: '',
      serverSeq: seq,
      tombstone: false,
    );

FileState _fs(String path, String blobRef,
        {bool tombstone = false, int size = 10, int ms = 1}) =>
    FileState(
      fileId: 'id',
      path: path,
      blobRef: blobRef,
      sizeBytes: size,
      hlc: Hlc(ms, 0, 'x'),
      tombstone: tombstone,
    );

BackupEntry _byPath(BackupInspection i, String path) =>
    i.entries.firstWhere((e) => e.path == path);

void main() {
  test('categorises each file against the current vault', () async {
    final records = [
      _rec('same'),
      _rec('changed'),
      _rec('deleted'), // absent from current → restores it
      _rec('gone', seq: 1), // tombstone in the snapshot
      _rec('mv', seq: 1),
      _rec('mv', seq: 2), // concurrent binary versions → LWW resolves, not conflict
    ];
    final byEnvelope = <String, FileState>{
      'enc-same-1': _fs('a/same.md', 'ref-same-1'),
      'enc-changed-1': _fs('a/changed.md', 'ref-changed-1'),
      'enc-deleted-1': _fs('b/deleted.md', 'ref-deleted-1'),
      'enc-gone-1': _fs('gone.md', '', tombstone: true),
      'enc-mv-1': _fs('img.png', 'ref-mv-OLD', ms: 1),
      'enc-mv-2': _fs('img.png', 'ref-mv-NEW', ms: 2), // higher HLC → winner
    };
    // Current vault: same is identical, changed differs, deleted is absent,
    // img.png currently holds the older content.
    final current = <String, String>{
      'a/same.md': 'ref-same-1',
      'a/changed.md': 'ref-changed-1-NEWER',
      'img.png': 'ref-mv-OLD',
    };

    final inspection = await InspectBackupUseCase(
      records: records,
      decodeRecord: (r) async => byEnvelope[r.encryptedState]!,
      currentLiveBlobByPath: current,
    )();

    expect(_byPath(inspection, 'a/same.md').status, BackupEntryStatus.identical);
    expect(_byPath(inspection, 'a/changed.md').status, BackupEntryStatus.changed);
    expect(_byPath(inspection, 'b/deleted.md').status,
        BackupEntryStatus.restoresDeleted);
    expect(
        _byPath(inspection, 'gone.md').status, BackupEntryStatus.deletedInBackup);
    // Concurrent versions resolve to the max-HLC winner (ref-mv-NEW), which
    // differs from the current ref-mv-OLD → changed, NOT "conflict".
    expect(_byPath(inspection, 'img.png').status, BackupEntryStatus.changed);
    expect(_byPath(inspection, 'img.png').blobRef, 'ref-mv-NEW');

    expect(inspection.identical, 1);
    expect(inspection.changed, 2); // a/changed.md + img.png
    expect(inspection.restoresDeleted, 1);
    expect(inspection.deletedInBackup, 1);
    expect(inspection.differing, 3);

    expect(inspection.entries.map((e) => e.path).toList(),
        ['a/changed.md', 'a/same.md', 'b/deleted.md', 'gone.md', 'img.png']);
    expect(_byPath(inspection, 'a/changed.md').blobRef, 'ref-changed-1');
  });

  test('an undecodable record is skipped, not fatal', () async {
    final inspection = await InspectBackupUseCase(
      records: [_rec('a'), _rec('bad')],
      decodeRecord: (r) async {
        if (r.fileId == 'bad') throw StateError('key mismatch');
        return _fs('a.md', 'ref-a-1');
      },
      currentLiveBlobByPath: const {},
    )();

    expect(inspection.entries, hasLength(1));
    expect(inspection.entries.single.path, 'a.md');
    expect(inspection.entries.single.status, BackupEntryStatus.restoresDeleted);
  });
}
