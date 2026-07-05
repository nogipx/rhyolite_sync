import 'dart:async';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Characterization tests for StateSyncEngine.
//
// These pin the engine's orchestration behavior BEFORE the pull/push
// pipelines are extracted into their own classes. They drive the real
// reconciler / chunked-blob / store machinery and fake only the network —
// via the injected SyncConnection + remote-blob-storage seams — so a
// regression in the extracted pipelines surfaces here.
// ---------------------------------------------------------------------------

// Valid UUID v4 — VaultConfig validates the format.
const _vaultId = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';
const _vaultPath = '/vault';

void main() {
  group('StateSyncEngine seams', () {
    test('start() connects via the injected SyncConnection and pulls from '
        'cursor 0 on an empty vault', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);

      // Broadcast events deliver on microtasks, so await the terminal
      // startup signal rather than inspecting the collected list.
      final connected = h.engine.events
          .firstWhere((e) => e is SyncConnected)
          .timeout(const Duration(seconds: 10));
      await h.engine.start();
      await connected;

      expect(
        h.connection.connectCalled,
        isTrue,
        reason: 'engine must drive the injected connection',
      );
      expect(
        h.state.getSince,
        isNotEmpty,
        reason: 'startup performs an initial pull',
      );
      expect(
        h.state.getSince.first,
        0,
        reason: 'first pull asks from cursor 0',
      );
    });

    test(
      'push does NOT advance the pull cursor (documented invariant)',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);

        // Server hands back a high cursor on putStates; the engine must NOT
        // adopt it as its pull cursor — that cursor includes other devices'
        // writes the engine has not pulled yet (engine comment in _push).
        h.state.getCursor = 0;
        h.state.putCursor = 99;

        await h.engine.start();

        // Create a binary file after startup so it flows through the
        // immediate reconcile+push path (text would hit the 3s debounce).
        final pushed = h.engine.events
            .firstWhere((e) => e is SyncFilePushed)
            .timeout(const Duration(seconds: 10));
        h.io.files['$_vaultPath/data.bin'] = Uint8List.fromList([
          0,
          1,
          2,
          3,
          4,
          5,
          6,
          7,
          8,
          9,
        ]);
        h.changes.emit(const FileCreatedEvent(relativePath: 'data.bin'));
        await pushed;

        expect(h.state.puts, isNotEmpty, reason: 'the new file must be pushed');
        expect(h.state.puts.last.items, hasLength(1));

        // Now pull again — it must ask from cursor 0, not the push's 99.
        h.state.getSince.clear();
        await h.engine.triggerPull();

        expect(h.state.getSince, isNotEmpty);
        expect(
          h.state.getSince.last,
          0,
          reason:
              'push returned cursor 99 but the next pull must still ask '
              'from 0 so other devices\' interleaved writes are not skipped',
        );
      },
    );

    test('returning to online after the initial connect reissues a catch-up '
        'pull (guards notify-dies-on-reconnect)', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);

      final firstConnected = h.engine.events
          .firstWhere((e) => e is SyncConnected)
          .timeout(const Duration(seconds: 10));
      await h.engine.start();
      await firstConnected;
      final pullsAfterStart = h.state.getSince.length;

      // rpc_dart does not carry in-flight calls across a reconnect, so the
      // engine must re-pull (and reissue notify) on each return to online —
      // otherwise the notify server-stream stays silent forever.
      h.connection.emitState(SyncConnState.online);
      await _eventually(() => h.state.getSince.length > pullsAfterStart);

      expect(
        h.state.getSince.length,
        greaterThan(pullsAfterStart),
        reason: 'reconnect must trigger a catch-up pull',
      );
    });

    test('a second device pulls the first device\'s pushed file and '
        'materialises it to disk', () async {
      // One shared remote blob store = one server seen by two devices.
      final remote = _MemRemote();

      // Device A pushes a binary file.
      final a = await _Harness.create(sharedRemote: remote);
      addTearDown(a.dispose);
      await a.engine.start();

      final pushed = a.engine.events
          .firstWhere((e) => e is SyncFilePushed)
          .timeout(const Duration(seconds: 10));
      final content = Uint8List.fromList(
        List.generate(2000, (i) => (i * 7) % 256),
      );
      a.io.files['$_vaultPath/photo.bin'] = content;
      a.changes.emit(const FileCreatedEvent(relativePath: 'photo.bin'));
      await pushed;

      final records = _recordsFromPuts(a.state);
      expect(records, isNotEmpty, reason: 'A must have pushed a record');

      // Device B: same vault, shared remote, empty disk. Its startup pull
      // receives A's records and must reconstruct the file from the blob
      // store and write it to its own disk.
      final b = await _Harness.create(sharedRemote: remote);
      addTearDown(b.dispose);
      b.state.recordsFor = (since) => since == 0 ? records : const [];
      b.state.getCursor = records.last.serverSeq;

      await b.engine.start();

      expect(
        b.io.files.containsKey('$_vaultPath/photo.bin'),
        isTrue,
        reason: 'B must materialise A\'s file to disk',
      );
      expect(
        b.io.files['$_vaultPath/photo.bin'],
        equals(content),
        reason: 'reconstructed bytes must match A\'s original content',
      );
    });

    test('concurrent divergent create of the same path keeps BOTH versions '
        'via a deterministic line-union (CRDT, no data loss)', () async {
      final remote = _MemRemote();

      // Device A creates note.md = "AAAA"; startup reconcile pushes it.
      final a = await _Harness.create(sharedRemote: remote);
      addTearDown(a.dispose);
      a.io.files['$_vaultPath/note.md'] = Uint8List.fromList('AAAA'.codeUnits);
      await a.engine.start();
      final recordsA = _recordsFromPuts(a.state);
      expect(recordsA, isNotEmpty, reason: 'A must publish its note');

      // Device B independently creates note.md = "BBBB" — a concurrent write
      // with no shared history. When B pulls A's record the MvRegister holds
      // two divergent seed-only values that cannot be char-merged losslessly,
      // so the resolver must keep the register multi-valued and render a
      // deterministic line-union view to disk — never dropping either side.
      final b = await _Harness.create(sharedRemote: remote);
      addTearDown(b.dispose);
      b.io.files['$_vaultPath/note.md'] = Uint8List.fromList('BBBB'.codeUnits);
      await b.engine.start();

      final resolved = b.engine.events
          .firstWhere((e) => e is SyncConflictResolved)
          .timeout(const Duration(seconds: 10));
      b.state.recordsFor = (since) => recordsA;
      b.state.getCursor = recordsA.last.serverSeq;
      await b.engine.triggerPull();
      final event = await resolved as SyncConflictResolved;

      expect(
        event.strategy,
        'text-union',
        reason: 'no shared history → line-union view, not a lossy char-join',
      );
      final merged = String.fromCharCodes(b.io.files['$_vaultPath/note.md']!);
      expect(merged.contains('AAAA'), isTrue,
          reason: 'A\'s note must survive — merged="$merged"');
      expect(merged.contains('BBBB'), isTrue,
          reason: 'B\'s note must survive — merged="$merged"');
    });

    test('three divergent creates converge to the SAME union on every device '
        '(confluence, independent of pull order)', () async {
      final remote = _MemRemote();

      Future<List<StateRecord>> createOn(String content) async {
        final h = await _Harness.create(sharedRemote: remote);
        addTearDown(h.dispose);
        h.io.files['$_vaultPath/note.md'] =
            Uint8List.fromList(content.codeUnits);
        await h.engine.start();
        return _recordsFromPuts(h.state);
      }

      final ra = await createOn('AAAA');
      final rb = await createOn('BBBB');
      final rc = await createOn('CCCC');

      // Device D pulls in order A,B,C; device E pulls in order C,B,A.
      Future<String> pullOrder(List<StateRecord> records) async {
        final d = await _Harness.create(sharedRemote: remote);
        addTearDown(d.dispose);
        final resolved = d.engine.events
            .firstWhere((e) => e is SyncConflictResolved)
            .timeout(const Duration(seconds: 10));
        d.state.recordsFor = (since) => records;
        d.state.getCursor = 99;
        await d.engine.start();
        await resolved;
        return String.fromCharCodes(d.io.files['$_vaultPath/note.md']!);
      }

      final dDisk = await pullOrder([...ra, ...rb, ...rc]);
      final eDisk = await pullOrder([...rc, ...rb, ...ra]);

      expect(dDisk, eDisk,
          reason: 'pull order must not change the union (confluence)');
      for (final c in ['AAAA', 'BBBB', 'CCCC']) {
        expect(dDisk.contains(c), isTrue,
            reason: '$c must survive — union="$dDisk"');
      }
    });

    test('editing the union collapses the multi-value register so it becomes '
        'pushable again', () async {
      final remote = _MemRemote();

      final a = await _Harness.create(sharedRemote: remote);
      addTearDown(a.dispose);
      a.io.files['$_vaultPath/note.md'] = Uint8List.fromList('AAAA'.codeUnits);
      await a.engine.start();
      final recordsA = _recordsFromPuts(a.state);

      final b = await _Harness.create(sharedRemote: remote);
      addTearDown(b.dispose);
      b.io.files['$_vaultPath/note.md'] = Uint8List.fromList('BBBB'.codeUnits);
      await b.engine.start();
      final unionResolved = b.engine.events
          .firstWhere((e) => e is SyncConflictResolved)
          .timeout(const Duration(seconds: 10));
      b.state.recordsFor = (since) => recordsA;
      b.state.getCursor = recordsA.last.serverSeq;
      await b.engine.triggerPull();
      await unionResolved;

      // The user reconciles the two versions by hand. That dominating edit
      // must collapse the MV-register to a single value — observable as a
      // fresh push (conflicting registers are never pushed).
      final pushedAfterEdit = b.engine.events
          .firstWhere((e) => e is SyncFilePushed)
          .timeout(const Duration(seconds: 10));
      b.io.files['$_vaultPath/note.md'] =
          Uint8List.fromList('reconciled by hand'.codeUnits);
      b.changes.emit(const FileModifiedEvent(relativePath: 'note.md'));
      await pushedAfterEdit;

      expect(
        b.state.puts.last.items.single.tombstone,
        isFalse,
        reason: 'the collapsed, edited value is pushed as live content',
      );
      final disk = String.fromCharCodes(b.io.files['$_vaultPath/note.md']!);
      expect(disk, 'reconciled by hand',
          reason: 'the user edit is what remains on disk');
    });

    test('a file edited DURING startup (after the disk scan) is queued and '
        'synced, not dropped', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);

      // A pre-existing file makes the startup push fire; we gate that push to
      // freeze the engine AFTER StartupDiff has already scanned the disk.
      h.io.files['$_vaultPath/existing.bin'] =
          Uint8List.fromList([9, 9, 9, 9]);
      final gate = Completer<void>();
      h.state.putStatesGate = gate;

      // SyncPushing fires right before the gated putStates → startup has
      // reached the push, so StartupDiff's scan is already done.
      final reachedStartupPush =
          h.engine.events.firstWhere((e) => e is SyncPushing).timeout(
                const Duration(seconds: 10),
              );
      final started = h.engine.start();
      await reachedStartupPush;

      // Edit a NEW file now — it was NOT on disk when StartupDiff scanned, so
      // only the during-startup change queue can catch it.
      final duringPushed = h.engine.events
          .firstWhere(
            (e) => e is SyncFilePushed && e.path == 'during.bin',
          )
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/during.bin'] =
          Uint8List.fromList([1, 2, 3, 4, 5]);
      h.changes.emit(const FileCreatedEvent(relativePath: 'during.bin'));

      gate.complete(); // let startup finish → drain the queued edit
      await started;
      await duringPushed; // would time out under the old late-subscribe code
    });

    test('scheduleBackground runs a sibling task on the engine scheduler '
        '(settings-sync hook)', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.engine.start();
      var ran = false;
      // Priority/gate/preemption semantics are covered by the scheduler unit
      // tests; here we just pin the public hook the plugin's settings sync
      // uses to share the engine's connection-fair lane.
      await h.engine.scheduleBackground(() async => ran = true);
      expect(ran, isTrue);
    });

    test('stop() cancels only the engine\'s own work and never disposes the '
        'host-owned scheduler', () async {
      final scheduler = PriorityTaskScheduler();
      final h = await _Harness.create(scheduler: scheduler);
      addTearDown(h.dispose);
      await h.engine.start();

      // A host-owned sibling task, gated out so it is still PENDING when the
      // engine tears down. Its group is one the engine never uses, so engine
      // teardown (cancelGroup of the engine's own group) must leave it alone.
      var siblingRan = false;
      scheduler.setMinPriority(1000);
      unawaited(
        scheduler.schedule(
          group: 'host',
          priority: 10,
          run: (_) async => siblingRan = true,
        ),
      );

      await h.engine.stop();

      // stop() cancels only the engine's group and lifts the gate it set — so
      // the foreign-group sibling was not dropped and now runs.
      await _eventually(() => siblingRan);

      // And the shared instance was not disposed: post-stop work still runs
      // (a disposed scheduler silently drops new schedules).
      var postStopRan = false;
      await scheduler.schedule(run: (_) async => postStopRan = true);
      expect(postStopRan, isTrue, reason: 'scheduler must still be alive');
    });
  });
}

/// Turns the put requests one device sent into the pull records another
/// device would receive, assigning monotonic server seqs.
List<StateRecord> _recordsFromPuts(_FakeStateContract sender) {
  var seq = 0;
  final out = <StateRecord>[];
  for (final put in sender.puts) {
    for (final it in put.items) {
      out.add(
        StateRecord(
          fileId: it.fileId,
          encryptedState: it.encryptedState,
          blobRef: it.blobRef,
          hlcPacked: it.hlcPacked,
          contextPacked: it.contextPacked,
          serverSeq: ++seq,
          tombstone: it.tombstone,
          chunks: it.chunks,
        ),
      );
    }
  }
  return out;
}

/// Polls [cond] until true or [timeout] elapses. Used to await fire-and-
/// forget engine reactions (e.g. the reconnect-driven pull) deterministically
/// without a fixed sleep.
Future<void> _eventually(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _Harness {
  _Harness({
    required this.engine,
    required this.connection,
    required this.state,
    required this.io,
    required this.changes,
    required this.remote,
    required this.events,
    required this.disposeEnv,
    required this.eventsSub,
    required this.scheduler,
  });

  final StateSyncEngine engine;
  final _FakeConnection connection;
  final _FakeStateContract state;
  final _InMemoryIO io;
  final _ManualChangeProvider changes;
  final _MemRemote remote;
  final List<SyncEngineEvent> events;
  final Future<void> Function() disposeEnv;
  final StreamSubscription<SyncEngineEvent> eventsSub;
  final PriorityTaskScheduler scheduler;

  static Future<_Harness> create({
    _MemRemote? sharedRemote,
    PriorityTaskScheduler? scheduler,
  }) async {
    final env = await DataServiceFactory.inMemory();
    final state = _FakeStateContract();
    final connection = _FakeConnection(
      stateCaller: state,
      historyCaller: _FakeHistoryContract(),
    );
    final io = _InMemoryIO();
    final changes = _ManualChangeProvider();
    // Two harnesses sharing one remote model two devices against one server.
    final remote = sharedRemote ?? _MemRemote();
    final events = <SyncEngineEvent>[];
    final sched = scheduler ?? PriorityTaskScheduler();

    final engine = StateSyncEngine(
      vaultPath: _vaultPath,
      serverUrl: 'ws://unused',
      config: const VaultConfig(vaultId: _vaultId, vaultName: 'test'),
      cipher: _IdentityCipher(),
      dataClient: env.client,
      blobStore: LocalBlobStore(InMemoryBlobRepository()),
      io: io,
      changeProvider: changes,
      scheduler: sched,
      connectionFactory: ({required serverUrl, tokenProvider, logger}) =>
          connection,
      blobStorageBuilder:
          ({
            required config,
            required cipher,
            required httpClient,
            required endpoint,
          }) => remote,
    );

    final sub = engine.events.listen(events.add);
    return _Harness(
      engine: engine,
      connection: connection,
      state: state,
      io: io,
      changes: changes,
      remote: remote,
      events: events,
      disposeEnv: () async => env.dispose(),
      eventsSub: sub,
      scheduler: sched,
    );
  }

  Future<void> dispose() async {
    await engine.dispose();
    await eventsSub.cancel();
    await changes.dispose();
    await disposeEnv();
  }
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _IdentityCipher implements IVaultCipher {
  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async => plaintext;
  @override
  Future<Uint8List> decrypt(Uint8List ciphertext) async => ciphertext;
}

/// Records the cursors getStates is asked for and the putStates requests
/// received; returns canned responses.
class _FakeStateContract implements IStateSyncContract {
  int epoch = 1;
  int getCursor = 0;
  int putCursor = 0;
  List<StateRecord> Function(int sinceCursor)? recordsFor;

  final List<int> getSince = [];
  final List<StatePutRequest> puts = [];

  /// If set, the FIRST putStates awaits this before responding — lets a test
  /// pause the engine mid-startup (after StartupDiff) to inject an edit.
  Completer<void>? putStatesGate;
  bool _putGateUsed = false;

  @override
  Future<StateGetResponse> getStates(
    StateGetRequest request, {
    RpcContext? context,
  }) async {
    getSince.add(request.sinceCursor);
    return StateGetResponse(
      records: recordsFor?.call(request.sinceCursor) ?? const [],
      cursor: getCursor,
      epoch: epoch,
    );
  }

  @override
  Future<StatePutResponse> putStates(
    StatePutRequest request, {
    RpcContext? context,
  }) async {
    if (putStatesGate != null && !_putGateUsed) {
      _putGateUsed = true;
      await putStatesGate!.future;
    }
    puts.add(request);
    return StatePutResponse(results: const [], cursor: putCursor, epoch: epoch);
  }

  @override
  Future<StateWipeResponse> wipeVault(
    StateWipeRequest request, {
    RpcContext? context,
  }) async => StateWipeResponse(epoch: ++epoch);
}

/// Empty history — the engine reports heads/frontiers best-effort.
class _FakeHistoryContract implements IHistoryContract {
  @override
  Future<HistoryGetResponse> getHistory(
    HistoryGetRequest request, {
    RpcContext? context,
  }) async => HistoryGetResponse(events: const [], epoch: 0);

  @override
  Future<HistoryDeleteEventsResponse> deleteEvents(
    HistoryDeleteEventsRequest request, {
    RpcContext? context,
  }) async => HistoryDeleteEventsResponse(deleted: 0);

  @override
  Future<ReportHistoryHeadResponse> reportHistoryHead(
    ReportHistoryHeadRequest request, {
    RpcContext? context,
  }) async => const ReportHistoryHeadResponse();

  @override
  Future<GetHistoryHeadsResponse> getHistoryHeads(
    GetHistoryHeadsRequest request, {
    RpcContext? context,
  }) async => GetHistoryHeadsResponse(heads: const []);
}

class _FakeConnection implements SyncConnection {
  _FakeConnection({required this.stateCaller, required this.historyCaller});

  @override
  final IStateSyncContract stateCaller;
  @override
  final IHistoryContract historyCaller;

  final _state = StreamController<SyncConnState>.broadcast();
  RpcCallerEndpoint? _endpoint;
  bool connectCalled = false;
  bool disposed = false;

  @override
  Future<void> connect() async {
    connectCalled = true;
    // A real (but unconnected) endpoint: notify subscribes over it and
    // simply never receives anything, which is fine for these tests.
    _endpoint = RpcCallerEndpoint(transport: RpcInMemoryTransport.pair().$1);
  }

  @override
  RpcCallerEndpoint get endpoint => _endpoint!;

  @override
  Stream<SyncConnState> get stateChanges => _state.stream;

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_state.isClosed) await _state.close();
  }

  void emitState(SyncConnState s) => _state.add(s);
}

/// In-memory remote blob backend. Treats blobs as plain bytes.
class _MemRemote implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    RpcContext? context,
  }) async => {
    for (final id in blobIds)
      if (store.containsKey(id)) id,
  };

  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    RpcContext? context,
  }) async {
    for (final (bytes, id) in blobs) {
      store[id] = bytes;
    }
  }

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async => {
    for (final id in blobIds)
      if (store.containsKey(id)) id: store[id]!,
  };

  @override
  Future<void> deleteMany(List<String> blobIds, {RpcContext? context}) async {
    for (final id in blobIds) {
      store.remove(id);
    }
  }
}

/// Minimal in-memory filesystem. Paths are opaque keys; listFiles returns
/// everything under the given dir prefix.
class _InMemoryIO implements IPlatformIO {
  final Map<String, Uint8List> files = {};

  @override
  Future<Uint8List> readFile(String absolutePath) async {
    final b = files[absolutePath];
    if (b == null) throw StateError('not found: $absolutePath');
    return b;
  }

  @override
  Future<bool> fileExists(String absolutePath) async =>
      files.containsKey(absolutePath);

  @override
  Future<bool> dirExists(String absolutePath) async => true;

  @override
  Future<List<String>> listFiles(String absoluteDirPath) async => files.keys
      .where((p) => p.startsWith('$absoluteDirPath/'))
      .toList(growable: false);

  @override
  Future<void> writeFile(String absolutePath, Uint8List bytes) async {
    files[absolutePath] = bytes;
  }

  @override
  Future<void> moveFile(String from, String to) async {
    final b = files.remove(from);
    if (b != null) files[to] = b;
  }

  @override
  Future<void> deleteFile(String absolutePath) async {
    files.remove(absolutePath);
  }

  @override
  Future<void> deleteEmptyDirsUpTo(String dirPath, String stopAt) async {}

  @override
  Future<FileStatInfo?> statFile(String absolutePath) async {
    final b = files[absolutePath];
    if (b == null) return null;
    return FileStatInfo(mtimeMs: 1000, sizeBytes: b.length);
  }
}

class _ManualChangeProvider implements IChangeProvider {
  final _changes = StreamController<FileChangeEvent>.broadcast();
  final _typing = StreamController<String>.broadcast();

  @override
  Stream<FileChangeEvent> get changes => _changes.stream;

  @override
  Stream<String> get typing => _typing.stream;

  @override
  void suppress(
    String path, {
    int count = 1,
    Duration holdFor = const Duration(seconds: 2),
  }) {}

  @override
  void unsuppress(String path) {}

  void emit(FileChangeEvent e) => _changes.add(e);

  Future<void> dispose() async {
    if (!_changes.isClosed) await _changes.close();
    if (!_typing.isClosed) await _typing.close();
  }
}
