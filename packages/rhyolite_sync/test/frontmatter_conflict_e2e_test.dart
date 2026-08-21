import 'dart:convert';
import 'dart:io';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_store.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_tail.dart';
import 'package:rhyolite_sync/src/sync_v3/disk_reconciler.dart';
import 'package:rhyolite_sync/src/sync_v3/remote_applier.dart';
import 'package:rhyolite_sync/src/sync_v3/state_record_codec.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

const _vaultPath = '/vault';
const _vaultId = '00000000-0000-4000-8000-000000000001';
const _note = 'Acme onboarding.md';
const _notePath = 'test/fixtures/frontmatter_heavy_note.md';

String fileIdFor(String relPath) => const Uuid().v5(_vaultId, relPath);

class _IdentityCipher implements IVaultCipher {
  @override
  Future<Uint8List> encrypt(Uint8List p) async => p;
  @override
  Future<Uint8List> decrypt(Uint8List c) async => c;
}

class _NoopChanges implements IChangeProvider {
  @override
  Stream<FileChangeEvent> get changes => const Stream.empty();
  @override
  Stream<String> get typing => const Stream.empty();
  @override
  void suppress(String path,
      {int count = 1, Duration holdFor = const Duration(seconds: 2)}) {}
  @override
  void unsuppress(String path) {}
}

class _MemIo implements IPlatformIO {
  final Map<String, Uint8List> files = {};

  /// Real filesystems move mtime on every write. Deriving it from the file
  /// length instead makes a same-length edit invisible to the reconciler's
  /// stat short-circuit, which is a property of the fake, not of the engine.
  final Map<String, int> mtimes = {};
  static int _clock = 0;

  @override
  Future<bool> fileExists(String p) async => files.containsKey(p);
  @override
  Future<bool> dirExists(String p) async => true;
  @override
  Future<Uint8List> readFile(String p) async {
    final b = files[p];
    if (b == null) throw StateError('no file at $p');
    return b;
  }

  @override
  Future<void> writeFile(String p, Uint8List b) async {
    files[p] = b;
    mtimes[p] = ++_clock;
  }
  @override
  Future<void> deleteFile(String p) async => files.remove(p);
  @override
  Future<void> moveFile(String a, String b) async {
    final v = files.remove(a);
    if (v != null) files[b] = v;
  }

  @override
  Future<void> deleteEmptyDirsUpTo(String d, String s) async {}
  @override
  Future<List<String>> listFiles(String d) async =>
      files.keys.where((p) => p.startsWith(d)).toList();
  @override
  Future<FileStatInfo?> statFile(String p) async {
    final b = files[p];
    return b == null
        ? null
        : FileStatInfo(mtimeMs: mtimes[p] ?? 0, sizeBytes: b.length);
  }
}

/// The server: one shared blob bucket and an append-only record log.
class _Server {
  final Map<String, Uint8List> blobs = {};
  final List<StateRecord> records = [];
  int seq = 0;

  late final IBlobStorage storage = _ServerBlobs(blobs);

  void put(StatePutItem item) {
    records.add(StateRecord(
      fileId: item.fileId,
      encryptedState: item.encryptedState,
      blobRef: item.blobRef,
      hlcPacked: item.hlcPacked,
      contextPacked: item.contextPacked,
      serverSeq: ++seq,
      tombstone: item.tombstone,
      chunks: item.chunks,
    ));
  }

  List<StateRecord> since(int cursor) =>
      records.where((r) => r.serverSeq > cursor).toList();
}

class _ServerBlobs implements IBlobStorage {
  _ServerBlobs(this.store);
  final Map<String, Uint8List> store;

  @override
  Future<Set<String>> exists(List<String> ids, {RpcContext? context}) async =>
      {for (final i in ids) if (store.containsKey(i)) i};
  @override
  Future<void> upload(List<(Uint8List, String)> blobs,
      {RpcContext? context}) async {
    for (final (b, i) in blobs) {
      store[i] = b;
    }
  }

  @override
  Future<Map<String, Uint8List>> download(List<String> ids,
      {RpcContext? context}) async =>
      {for (final i in ids) if (store.containsKey(i)) i: store[i]!};
  @override
  Future<void> deleteMany(List<String> ids, {RpcContext? context}) async {
    for (final i in ids) {
      store.remove(i);
    }
  }
}

class _Device {
  _Device._(this.name, this.io, this.store, this.fugueStore, this.fmStore,
      this.reconciler, this.applier, this.codec, this.resolver, this.server,
      this.events);

  final String name;
  final _MemIo io;
  final FileStateStore store;
  final FugueStore fugueStore;
  final FmStore fmStore;
  final DiskReconciler reconciler;
  final RemoteApplier applier;
  final StateRecordCodec codec;
  final IStateConflictResolver resolver;
  final _Server server;
  final List<SyncEngineEvent> events;
  int cursor = 0;

  static Future<_Device> create(String name, _Server server) async {
    final env = await DataServiceFactory.inMemory();
    addTearDown(env.dispose);

    final store = FileStateStore(client: env.client, vaultId: _vaultId);
    await store.load();
    final fugueStore = FugueStore(client: env.client, vaultId: _vaultId);
    await fugueStore.load();
    final fmStore = FmStore(client: env.client, vaultId: _vaultId);
    await fmStore.load();

    final io = _MemIo();
    final changes = _NoopChanges();
    final localBlobs = LocalBlobStore(InMemoryBlobRepository());
    final events = <SyncEngineEvent>[];

    ChunkedBlobIO? builder() => ChunkedBlobIO(
          blobStore: localBlobs,
          remoteBlobStorage: server.storage,
          vaultId: _vaultId,
        );

    final reconciler = DiskReconciler(
      vaultPath: _vaultPath,
      vaultId: _vaultId,
      io: io,
      blobStore: localBlobs,
      changeProvider: changes,
      store: store,
      fugueStore: fugueStore,
      fmStore: fmStore,
      chunkedIOBuilder: builder,
      knownChunks: () => {for (final s in store.allValuesFlat) ...s.chunks},
      fileIdFor: fileIdFor,
      emit: events.add,
    );

    final codec = StateRecordCodec(cipher: _IdentityCipher());

    final applier = RemoteApplier(
      store: store,
      fugueStore: fugueStore,
      fmStore: fmStore,
      reconciler: reconciler,
      codec: codec,
      blobStore: localBlobs,
      io: io,
      changeProvider: changes,
      vaultId: _vaultId,
      vaultPath: _vaultPath,
      newChunkedIO: builder,
      collectKnownChunks: () => <String>{},
      emit: events.add,
      isFatalRejection: (_) => false,
      log: LogScope.noop,
    );

    final resolver = StateConflictResolver(
      store: store,
      blobStore: localBlobs,
      vaultId: _vaultId,
      nodeId: store.deviceId,
      remoteBlobStorage: server.storage,
      chunkedBlobIO: builder(),
    );

    return _Device._(name, io, store, fugueStore, fmStore, reconciler,
        applier, codec, resolver, server, events);
  }

  String get diskNote => utf8.decode(io.files['$_vaultPath/$_note']!);
  set diskNote(String text) {
    io.files['$_vaultPath/$_note'] = Uint8List.fromList(utf8.encode(text));
    _MemIo._clock++;
    io.mtimes['$_vaultPath/$_note'] = _MemIo._clock;
  }

  /// One local reconcile + push of everything this device owes.
  Future<void> pushAll() async {
    await reconciler.reconcileWithDisk(_note);
    for (final fileId in store.fileIds) {
      final register = store.registerFor(fileId);
      if (register == null) continue;
      final tv = register.hasConflict
          ? register.values.firstWhere((t) => t.hlc.nodeId == store.deviceId,
              orElse: () => register.values.first)
          : register.values.first;
      final synced = store.lastSyncedBlobRefFor(fileId);
      final dirty = register.hasConflict ||
          synced == null ||
          synced != tv.value.blobRef;
      if (!dirty) continue;
      server.put(await codec.encode(tv.value, tv.context));
    }
  }

  /// Pushes a blob that shares this file's causal history but carries NO
  /// `\0fm1` tail — what `repair` writes today, and what every client before
  /// 3.12.0 wrote. The tree is the real one, so the sides still char-join.
  Future<void> pushStrippingFmTail() async {
    await reconciler.reconcileWithDisk(_note);
    final fileId = fileIdFor(_note);
    final seq = (await fugueStore.get(fileId))!;
    final up = await reconciler.uploadSequenceBlob(seq);
    final hlc = store.nextHlc();
    store.applyLocal(FileState(
      fileId: fileId,
      path: _note,
      blobRef: up!.manifestHash,
      sizeBytes: up.blobSize,
      hlc: hlc,
      tombstone: false,
      chunks: up.chunkHashes,
    ));
    await store.persistOne(fileId);
    final register = store.registerFor(fileId)!;
    final tv = register.values.firstWhere((t) => t.hlc.nodeId == store.deviceId);
    server.put(await codec.encode(tv.value, tv.context));
  }

  Future<void> pull() async {
    final fresh = server.since(cursor);
    if (fresh.isEmpty) return;
    cursor = fresh.last.serverSeq;
    final byFile = <String, List<StateRecord>>{};
    for (final r in fresh) {
      byFile.putIfAbsent(r.fileId, () => []).add(r);
    }
    for (final e in byFile.entries) {
      await applier.apply(e.key, e.value, resolver);
    }
  }

  /// Does this device's currently-pushed blob carry an `\0fm1` tail?
  Future<bool> lastBlobHasFmTail() async {
    final state = store.get(fileIdFor(_note));
    if (state == null) return false;
    final io = ChunkedBlobIO(
      blobStore: LocalBlobStore(InMemoryBlobRepository()),
      remoteBlobStorage: server.storage,
      vaultId: _vaultId,
    );
    final bytes = await io.download(state.blobRef);
    return bytes != null && hasFmTail(bytes);
  }
}

void main() {
  final base = File(_notePath).readAsStringSync();

  test('offline divergence on both devices: what reaches disk', () async {
    final server = _Server();
    final a = await _Device.create('A', server);
    final b = await _Device.create('B', server);

    // 1. Device A owns the vault and pushes it, then pulls its own record
    //    back exactly as the engine's post-push cycle does.
    a.diskNote = base;
    await a.pushAll();
    await a.pull();

    // 2. Device B syncs cleanly — pull, then materialise.
    await b.pull();
    expect(b.io.files.containsKey('$_vaultPath/$_note'), isTrue,
        reason: 'B must receive the note');
    expect(b.diskNote, base, reason: 'B starts converged');
    await b.pushAll(); // B adopts the state, nothing new owed

    print('A blob carries fm tail: ${await a.lastBlobHasFmTail()}');
    print('B blob carries fm tail: ${await b.lastBlobHasFmTail()}');

    // 3. Both go offline and edit the SAME properties.
    a.diskNote = base
        .replaceFirst('start: 2026-08-04', 'start: 2026-08-01')
        .replaceFirst('end: 2026-09-28', 'end: 2026-09-30')
        .replaceFirst('updated: 2026-08-21T11:36:01+03:00',
            'updated: 2026-08-12T11:23:01+03:00');
    b.diskNote = base
        .replaceFirst('start: 2026-08-04', 'start: 2026-08-06')
        .replaceFirst('end: 2026-09-28', 'end: 2026-09-15')
        .replaceFirst('updated: 2026-08-21T11:36:01+03:00',
            'updated: 2026-08-19T09:02:44+03:00');

    await a.pushAll();
    await b.pushAll();
    print('server records: ${server.seq}');

    // 4. Both come back and pull each other.
    for (var round = 0; round < 3; round++) {
      await a.pull();
      await b.pull();
      await a.pushAll();
      await b.pushAll();
      final fid = fileIdFor(_note);
      print('round $round: A conflict=${a.store.hasConflict(fid)} '
          'B conflict=${b.store.hasConflict(fid)} seq=${server.seq}');
    }

    print('=== A disk after merge ===');
    print(a.diskNote.substring(0, a.diskNote.indexOf('\n---\n') + 5));
    print('=== B disk after merge ===');
    print(b.diskNote.substring(0, b.diskNote.indexOf('\n---\n') + 5));

    final conflicts = [...a.events, ...b.events]
        .whereType<SyncConflictResolved>()
        .map((e) => e.strategy)
        .toList();
    print('conflict strategies: $conflicts');

    for (final blended in ['016', '3015', '4422', '0644', '1519']) {
      expect(a.diskNote.contains(blended), isFalse,
          reason: 'A blended values: $blended');
      expect(b.diskNote.contains(blended), isFalse,
          reason: 'B blended values: $blended');
    }
    expect(a.diskNote, b.diskNote, reason: 'devices must converge');
  });

  _fieldScenario(base);
  _tailLessSide(base);
  _rawSideScenario(base);
}

/// A device that joins with its own, older copy of the vault already on disk
/// and has never synced. The engine pulls first, then runs StateStartupDiff,
/// then pushes — so the pull must not flatten what is already there.
void _fieldScenario(String base) {
  test('a device joining with a divergent copy keeps it and merges', () async {
    final server = _Server();
    final a = await _Device.create('A', server);
    final b = await _Device.create('B', server);

    a.diskNote = base;
    await a.pushAll();
    await a.pull();

    // B's own copy, last touched before the vault ever reached the server.
    // Present BEFORE B's first pull, and unknown to B's (empty) store.
    final stale = base
        .replaceFirst('start: 2026-08-04', 'start: 2026-08-01')
        .replaceFirst('end: 2026-09-28', 'end: 2026-09-30')
        .replaceFirst('updated: 2026-08-21T11:36:01+03:00',
            'updated: 2026-08-12T11:23:01+03:00')
        .replaceFirst('уточнить сроки', 'запросить статус');
    b.diskNote = stale;

    // start(): pull, then startup diff, then push.
    await b.pull();
    expect(b.diskNote, stale,
        reason: 'the first pull must not overwrite content B never synced');
    expect(b.events.whereType<SyncFileKeptUnsynced>(), isNotEmpty,
        reason: 'and it must say so rather than silently skipping');

    for (var i = 0; i < 4; i++) {
      await b.pushAll();
      await a.pull();
      await b.pull();
      await a.pushAll();
    }

    // Neither side may vanish. B's own edit and A's base both survive.
    expect(b.diskNote.contains('запросить статус'), isTrue,
        reason: "B's local-only edit must survive the merge");
    expect(a.diskNote.contains('запросить статус'), isTrue,
        reason: 'and must reach A');
    expect(a.diskNote, b.diskNote, reason: 'devices must converge');

    // Whatever the merge chose, the region must still be a valid single
    // mapping — no duplicated keys, no blended values.
    for (final disk in [a.diskNote, b.diskNote]) {
      for (final key in ['start', 'end', 'updated', 'tasks', 'tags']) {
        expect(RegExp('^$key:', multiLine: true).allMatches(disk).length, 1,
            reason: '$key must appear exactly once');
      }
      expect(disk.contains('2026-08-0401'), isFalse);
      expect(disk.contains('2026-09-2830'), isFalse);
    }
  });
}

/// The reported bug: one concurrent side reaches the merge without a
/// frontmatter tail. Before the lift, that disabled the region rewrite and the
/// two versions were blended character by character.
void _tailLessSide(String base) {
  test('a side without an fm tail must not blend the region', () async {
    final server = _Server();
    final a = await _Device.create('A', server);
    final b = await _Device.create('B', server);

    a.diskNote = base;
    await a.pushAll();
    await a.pull();
    await b.pull();
    await b.pushAll();

    // Both edit the SAME three properties offline.
    a.diskNote = base
        .replaceFirst('start: 2026-08-04', 'start: 2026-08-01')
        .replaceFirst('end: 2026-09-28', 'end: 2026-09-30')
        .replaceFirst('updated: 2026-08-21T11:36:01+03:00',
            'updated: 2026-08-12T11:23:01+03:00');
    b.diskNote = base
        .replaceFirst('start: 2026-08-04', 'start: 2026-08-06')
        .replaceFirst('end: 2026-09-28', 'end: 2026-09-15')
        .replaceFirst('updated: 2026-08-21T11:36:01+03:00',
            'updated: 2026-08-19T09:02:44+03:00');

    // A pushes the way repair / a pre-3.12 client does: no tail.
    await a.pushStrippingFmTail();
    await b.pushAll();
    print('A blob has fm tail: ${await a.lastBlobHasFmTail()}');
    print('B blob has fm tail: ${await b.lastBlobHasFmTail()}');

    for (var i = 0; i < 3; i++) {
      await a.pull();
      await b.pull();
      await a.pushAll();
      await b.pushAll();
    }

    print('=== A region ===');
    print(a.diskNote.substring(0, a.diskNote.indexOf('\n---\n') + 5));
    print('strategies: ${[...a.events, ...b.events].whereType<SyncConflictResolved>().map((e) => e.strategy).toSet()}');

    // Each property must hold ONE of the two written values, never a blend.
    for (final line in [a.diskNote, b.diskNote]) {
      for (final blended in ['016', '3015', '4422', '0644', '1519', '1223']) {
        expect(line.contains(blended), isFalse, reason: 'blended: $blended');
      }
      expect(RegExp(r'^start: 2026-08-0[16]$', multiLine: true).hasMatch(line),
          isTrue, reason: 'start must be one of the two written values');
      expect(RegExp(r'^end: 2026-09-(30|15)$', multiLine: true).hasMatch(line),
          isTrue, reason: 'end must be one of the two written values');
      // Every key exactly once — the duplicate-key bug this feature exists for.
      for (final key in ['start', 'end', 'updated', 'category', 'tasks']) {
        expect(RegExp('^$key:', multiLine: true).allMatches(line).length, 1,
            reason: '$key must appear exactly once');
      }
    }
    expect(a.diskNote, b.diskNote, reason: 'devices must converge');
  });
}

/// A region one side cannot model at all. `joinFm` resolves a shape
/// disagreement by taking the NEWER shape whole, so if the mapping side is
/// newer it wins the entire region — and rewriting the text from it would drop
/// whatever the unmodelled side had, which the character join had just kept.
void _rawSideScenario(String base) {
  test('a side whose region cannot be modelled is not dropped', () async {
    final server = _Server();
    final a = await _Device.create('A', server);
    final b = await _Device.create('B', server);

    a.diskNote = base;
    await a.pushAll();
    await a.pull();
    await b.pull();
    await b.pushAll();

    // B's region picks up a tab in its indentation — YAML forbids it, so the
    // recogniser refuses the whole region and holds it verbatim.
    b.diskNote = base.replaceFirst(
      '  - status/wip\n',
      '\t- status/wip\n  - b-only-marker\n',
    );
    await b.pushAll();

    // A edits a property normally, and does it LAST so its clock is newer.
    a.diskNote = base.replaceFirst('start: 2026-08-04', 'start: 2026-08-09');
    await a.pushAll();

    for (var i = 0; i < 3; i++) {
      await a.pull();
      await b.pull();
      await a.pushAll();
      await b.pushAll();
    }

    print('=== A disk ===');
    print(a.diskNote.substring(0, a.diskNote.indexOf('\n---\n') + 5));

    expect(a.diskNote.contains('b-only-marker'), isTrue,
        reason: "B's unmodelled region must survive the merge");
    expect(a.diskNote, b.diskNote, reason: 'devices must converge');
  });
}
