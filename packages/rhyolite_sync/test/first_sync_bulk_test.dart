@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob_sqlite/rpc_blob_sqlite.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// A first sync of a vault full of attachments, on ONE connection, at the
// concurrency the plugin uses.
//
// This is the shape that broke, and none of the existing startup-diff tests
// could see it: they give the store an in-memory data service and the blob
// cache a separate in-memory repository, so the two never contend. Production
// gives both the same SQLite handle.
//
// The three conditions together are what matters, and each is load-bearing:
//   * BINARIES — the text path passes `cacheLocally: false`, so notes never
//     write to the blob cache and never produce a second writer.
//   * MANY of them — groups are 8 files and the pool is 4 workers, so fewer
//     than ~32 never has two workers writing at once.
//   * ONE connection — the whole point.
//
// The vault that reported this had 6280 attachments and banked nothing across
// two days. Groups 0-7 failed on every pass: the first 64 files.
// ---------------------------------------------------------------------------

const _vaultPath = '/vault';
const _vaultId = '00000000-0000-4000-8000-0000000000cc';

/// Enough files to keep all four workers writing at once, few enough to stay
/// quick. Eight groups of eight is the span that failed in the field.
const _fileCount = 300;

void main() {
  test('a first sync of $_fileCount attachments banks every one', () async {
    final conn = await openInMemoryDb();
    addTearDown(conn.close);

    // Wired as the hosts wire it: one gate, both writers behind it.
    final gate = ConnectionGate();
    final dataClient = SerialisedDataClient(
      IDataClient.repository(
        repository: SqliteDataRepository(
          storage: SqliteDataStorageAdapter.connection(conn),
        ),
      ),
      gate: gate,
    );
    final blobStore = LocalBlobStore(
      GatedBlobRepository(
        SqliteBlobRepository.db(conn.database, enableWal: false),
        gate: gate,
      ),
    );

    final store = FileStateStore(client: dataClient, vaultId: _vaultId);
    await store.load();

    final io = _MemIo();
    for (var i = 0; i < _fileCount; i++) {
      // Binary by extension, and distinct content so nothing dedups away.
      io.files['$_vaultPath/img$i.jpg'] = Uint8List.fromList(
        List<int>.generate(96, (b) => (i * 31 + b * 7) & 0xFF),
      );
    }

    final remote = _MemRemote();
    final result = await StateStartupDiff(
      store: store,
      blobStore: blobStore,
      remoteBlobStorage: remote,
      io: io,
      vaultPath: _vaultPath,
      vaultId: _vaultId,
      nodeId: 'test-device',
      readClock: store.nextHlc,
      writeClock: (_) {},
      // The plugin's desktop value. At 1 the pass is serial and the whole
      // point of the test is gone.
      uploadConcurrency: 4,
    ).call();

    expect(
      result.skippedGroups,
      0,
      reason:
          'a skipped group is the symptom: in the field every pass lost groups '
          '0-7 to `cannot start a transaction within a transaction`',
    );
    expect(result.newFiles, _fileCount);
    expect(
      store.fileIds.length,
      _fileCount,
      reason: 'every file must have a state, or the push has nothing to send',
    );
    expect(
      remote.store.length,
      greaterThanOrEqualTo(_fileCount),
      reason: 'and its bytes must have reached the backend',
    );
  });
}

class _MemIo implements IPlatformIO {
  final Map<String, Uint8List> files = {};

  @override
  Future<bool> fileExists(String absolutePath) async =>
      files.containsKey(absolutePath);
  @override
  Future<bool> dirExists(String absolutePath) async => true;
  @override
  Future<Uint8List> readFile(String absolutePath) async {
    final b = files[absolutePath];
    if (b == null) throw StateError('no file $absolutePath');
    return b;
  }

  @override
  Future<void> writeFile(String absolutePath, Uint8List bytes) async {
    files[absolutePath] = bytes;
  }

  @override
  Future<void> deleteFile(String absolutePath) async {
    files.remove(absolutePath);
  }

  @override
  Future<void> moveFile(String from, String to) async {}
  @override
  Future<void> deleteEmptyDirsUpTo(String dirPath, String stopAt) async {}
  @override
  Future<List<String>> listFiles(String absoluteDirPath) async =>
      files.keys.where((p) => p.startsWith(absoluteDirPath)).toList();
  @override
  Future<FileStatInfo?> statFile(String absolutePath) async {
    final b = files[absolutePath];
    if (b == null) return null;
    return FileStatInfo(mtimeMs: 0, sizeBytes: b.length);
  }
}

class _MemRemote implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    covariant Object? context,
  }) async => {
    for (final id in blobIds)
      if (store.containsKey(id)) id,
  };
  int uploads = 0;

  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    covariant Object? context,
  }) async {
    uploads += blobs.length;
    for (final (bytes, id) in blobs) {
      store[id] = bytes;
    }
  }

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    covariant Object? context,
  }) async => {
    for (final id in blobIds)
      if (store.containsKey(id)) id: store[id]!,
  };

  @override
  Future<void> deleteMany(
    List<String> blobIds, {
    covariant Object? context,
  }) async {
    for (final id in blobIds) {
      store.remove(id);
    }
  }
}
