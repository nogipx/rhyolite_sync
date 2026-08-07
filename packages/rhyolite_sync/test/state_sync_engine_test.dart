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

    test('a failed startup tears the engine down, not a zombie reporting '
        'healthy (L1-6)', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);

      // The connection succeeds, then the initial startup pull throws a
      // generic (non-auth) error. Only the first getStates fails, so
      // healthCheck's own getStates would succeed — exposing a zombie.
      h.state.failFirstGetStatesWith = StateError('transient startup pull');

      await h.engine.start();

      final healthy = await h.engine.healthCheck();
      expect(
        healthy,
        isFalse,
        reason:
            'a startup that failed after connecting must leave the engine '
            'idle (torn down), not a half-wired zombie (no notify / typing / '
            'reconnect-watch) whose healthCheck reports healthy and blocks the '
            "host's health-gated restart",
      );
      expect(
        h.events.whereType<SyncError>(),
        isNotEmpty,
        reason: 'the failure is still surfaced',
      );
    });

    test('changing the cipher across a restart re-derives the blob-id key '
        '(L1-7)', () async {
      final cipherA = VaultCipher.fromRawKey(
        Uint8List.fromList(List.filled(32, 1)),
      );
      final cipherB = VaultCipher.fromRawKey(
        Uint8List.fromList(List.filled(32, 2)),
      );
      final h = await _Harness.create(cipher: cipherA);
      addTearDown(h.dispose);
      final content = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

      // Session A: push a binary file; its blobRef (manifest hash) is keyed
      // by cipherA's derived blob-id key.
      await h.engine.start();
      final pushedA = h.engine.events
          .firstWhere((e) => e is SyncFilePushed)
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/a.bin'] = content;
      h.changes.emit(const FileCreatedEvent(relativePath: 'a.bin'));
      await pushedA;
      final refA = h.state.puts.last.items.first.blobRef;

      // Restart with a DIFFERENT cipher.
      await h.engine.stop();
      h.engine.cipher = cipherB;
      await h.engine.start();

      // Session B: push the SAME content under a different path. With the new
      // cipher the blob-id key differs, so the manifest hash must differ.
      final pushedB = h.engine.events
          .firstWhere((e) => e is SyncFilePushed)
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/b.bin'] = content;
      h.changes.emit(const FileCreatedEvent(relativePath: 'b.bin'));
      await pushedB;
      // In session B the a.bin re-upload (under the new key) may coalesce
      // with b.bin's push; both carry the same content so share one blobRef.
      final refB = h.state.puts.last.items.first.blobRef;

      expect(
        refB,
        isNot(refA),
        reason:
            'same content under a different cipher must hash to a '
            "different blob id; a stale memoized key reuses the old vault's id",
      );
    });

    test('restore surfaces a local delete failure instead of silently leaving '
        'a stale file (L1-10a)', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.engine.start();

      // A local file restore will try to delete, but the filesystem refuses.
      // Swallowing this would leave the file shadowing the server copy the
      // user clicked Restore to recover.
      h.io.files['$_vaultPath/stuck.md'] = Uint8List.fromList([1, 2, 3]);
      h.io.failDeletePaths.add('$_vaultPath/stuck.md');
      h.events.clear();

      await h.engine.triggerRestoreFromServer();

      expect(
        h.events.whereType<SyncError>(),
        isNotEmpty,
        reason:
            'a delete that failed during restore must be surfaced, not '
            'swallowed',
      );
    });

    test('a failed epoch-triggered restore is observed, not an unobserved '
        'async error (L1-10b)', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.engine.start(); // adopts the fake's epoch (1)

      // Server jumps to a higher epoch → the next pull triggers an automatic
      // restore. Make that restore fail (listFiles throws) and confirm the
      // failure is surfaced rather than lost in the detached microtask.
      h.state.epoch = 2;
      h.io.failListFiles = true;
      h.events.clear();

      await h.engine.triggerPull();
      // The restore runs in a detached microtask; let it settle.
      await pumpEventQueue();

      expect(
        h.events.whereType<SyncVaultReset>(),
        isNotEmpty,
        reason: 'the epoch mismatch still signals a reset is under way',
      );
      expect(
        h.events.whereType<SyncError>(),
        isNotEmpty,
        reason:
            'the failed restore must be observed and surfaced, correcting '
            'the optimistic SyncVaultReset',
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
      expect(
        merged.contains('AAAA'),
        isTrue,
        reason: 'A\'s note must survive — merged="$merged"',
      );
      expect(
        merged.contains('BBBB'),
        isTrue,
        reason: 'B\'s note must survive — merged="$merged"',
      );
    });

    test('three divergent creates converge to the SAME union on every device '
        '(confluence, independent of pull order)', () async {
      final remote = _MemRemote();

      Future<List<StateRecord>> createOn(String content) async {
        final h = await _Harness.create(sharedRemote: remote);
        addTearDown(h.dispose);
        h.io.files['$_vaultPath/note.md'] = Uint8List.fromList(
          content.codeUnits,
        );
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

      expect(
        dDisk,
        eDisk,
        reason: 'pull order must not change the union (confluence)',
      );
      for (final c in ['AAAA', 'BBBB', 'CCCC']) {
        expect(
          dDisk.contains(c),
          isTrue,
          reason: '$c must survive — union="$dDisk"',
        );
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
      b.io.files['$_vaultPath/note.md'] = Uint8List.fromList(
        'reconciled by hand'.codeUnits,
      );
      b.changes.emit(const FileModifiedEvent(relativePath: 'note.md'));
      await pushedAfterEdit;

      expect(
        b.state.puts.last.items.single.tombstone,
        isFalse,
        reason: 'the collapsed, edited value is pushed as live content',
      );
      final disk = String.fromCharCodes(b.io.files['$_vaultPath/note.md']!);
      expect(
        disk,
        'reconciled by hand',
        reason: 'the user edit is what remains on disk',
      );
    });

    test('a file edited DURING startup (after the disk scan) is queued and '
        'synced, not dropped', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);

      // A pre-existing file makes the startup push fire; we gate that push to
      // freeze the engine AFTER StartupDiff has already scanned the disk.
      h.io.files['$_vaultPath/existing.bin'] = Uint8List.fromList([9, 9, 9, 9]);
      final gate = Completer<void>();
      h.state.putStatesGate = gate;

      // SyncPushing fires right before the gated putStates → startup has
      // reached the push, so StartupDiff's scan is already done.
      final reachedStartupPush = h.engine.events
          .firstWhere((e) => e is SyncPushing)
          .timeout(const Duration(seconds: 10));
      final started = h.engine.start();
      await reachedStartupPush;

      // Edit a NEW file now — it was NOT on disk when StartupDiff scanned, so
      // only the during-startup change queue can catch it.
      final duringPushed = h.engine.events
          .firstWhere((e) => e is SyncFilePushed && e.path == 'during.bin')
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/during.bin'] = Uint8List.fromList([
        1,
        2,
        3,
        4,
        5,
      ]);
      h.changes.emit(const FileCreatedEvent(relativePath: 'during.bin'));

      gate.complete(); // let startup finish → drain the queued edit
      await started;
      await duringPushed; // would time out under the old late-subscribe code
    });

    test('an edit made inside the pull window still reaches the peer '
        '(no under-sync)', () async {
      final remote = _MemRemote();

      // A publishes a base version of a text note.
      final a = await _Harness.create(sharedRemote: remote);
      addTearDown(a.dispose);
      a.io.files['$_vaultPath/note.md'] = Uint8List.fromList(
        'base\n'.codeUnits,
      );
      await a.engine.start();
      final base = _recordsFromPuts(a.state);
      expect(base, isNotEmpty, reason: 'A must publish the base note');

      // A edits → the remote version B will pull.
      final aPushed = a.engine.events
          .firstWhere((e) => e is SyncFilePushed)
          .timeout(const Duration(seconds: 10));
      a.io.files['$_vaultPath/note.md'] = Uint8List.fromList(
        'base\nA\n'.codeUnits,
      );
      a.changes.emit(const FileModifiedEvent(relativePath: 'note.md'));
      await aPushed;
      final remoteEdit = _recordsFromPuts(a.state); // base + A's edit

      // B starts from the same base (shared history), so its own edit will be
      // a genuine concurrent value, not a divergent create.
      final b = await _Harness.create(sharedRemote: remote);
      addTearDown(b.dispose);
      b.state.recordsFor = (since) => since == 0 ? base : const [];
      b.state.getCursor = base.last.serverSeq;
      await b.engine.start();

      // B edits the note ON DISK inside the pull window: the bytes are present
      // but no change event fired, so no standalone reconcile+push ran. The
      // imminent pull's pre-join reconcile is what captures this edit.
      b.io.files['$_vaultPath/note.md'] = Uint8List.fromList(
        'base\nB\n'.codeUnits,
      );
      final putsBefore = b.state.puts.length;

      // A's edit arrives; B pulls it. preReconcile captures B's disk edit, the
      // conflict resolves, and the post-pull push must publish B's contribution
      // — otherwise A never receives B's edit (the under-sync bug).
      b.state.recordsFor = (since) => remoteEdit;
      b.state.getCursor = remoteEdit.last.serverSeq;
      await b.engine.triggerPull();

      expect(
        b.state.puts.length,
        greaterThan(putsBefore),
        reason:
            "B's edit made inside the pull window must still be pushed — "
            'otherwise the peer never receives it (under-sync)',
      );
      expect(
        b.state.puts.last.items.any((it) => !it.tombstone),
        isTrue,
        reason: "B must publish its live content, not a tombstone",
      );
    });

    test('an interactive edit preempts a wedged pull download so the push '
        'still goes out (single lane no longer starved)', () async {
      final remote = _BlockingRemote();

      // Device A publishes a binary file so B has a real blob to pull.
      final a = await _Harness.create(sharedRemote: remote);
      addTearDown(a.dispose);
      a.io.files['$_vaultPath/photo.bin'] = Uint8List.fromList(
        List.generate(2000, (i) => (i * 7) % 256),
      );
      await a.engine.start();
      final records = _recordsFromPuts(a.state);
      expect(
        records,
        isNotEmpty,
        reason: 'A must publish a record with a blob',
      );

      // Device B starts empty — its startup pull sees no records, so nothing
      // blocks yet.
      final b = await _Harness.create(sharedRemote: remote);
      addTearDown(b.dispose);
      await b.engine.start();

      // Arm: B's next pull returns A's records, and every blob download now
      // wedges until its RpcContext is cancelled — models the iOS WS stall.
      b.state.recordsFor = (since) => records;
      b.state.getCursor = records.last.serverSeq;
      remote.blockDownloads = true;

      // Kick a preemptible pull; it wedges inside the blob download.
      unawaited(b.engine.triggerPull());
      await remote.downloadEntered.future.timeout(const Duration(seconds: 10));

      // While the pull is wedged, the user creates a NEW file. Its interactive
      // reconcile+push (priority _pInteractive) must PREEMPT the pull and free
      // the single lane, so this push completes instead of starving behind the
      // stalled download. Under the old non-preemptible pull this times out.
      final pushed = b.engine.events
          .firstWhere((e) => e is SyncFilePushed && e.path == 'edit.bin')
          .timeout(const Duration(seconds: 10));
      b.io.files['$_vaultPath/edit.bin'] = Uint8List.fromList([1, 2, 3, 4, 5]);
      b.changes.emit(const FileCreatedEvent(relativePath: 'edit.bin'));

      await pushed;

      // The wedged download was aborted by the preempt, not left hanging.
      await _eventually(() => remote.downloadsCancelled > 0);

      remote.blockDownloads = false; // let any re-scheduled pull finish cleanly
    });

    test('a file whose extension is on the per-device denylist is skipped, '
        'others still sync', () async {
      final h = await _Harness.create(excludedExtensions: () => {'bin'});
      addTearDown(h.dispose);
      await h.engine.start();

      // A non-excluded binary pushes (the sync barrier); the .bin is excluded.
      final pushed = h.engine.events
          .firstWhere((e) => e is SyncFilePushed && e.path == 'ok.dat')
          .timeout(const Duration(seconds: 10));
      final excluded = h.engine.events
          .firstWhere((e) => e is SyncFileTypeExcluded && e.path == 'skip.bin')
          .timeout(const Duration(seconds: 10));

      h.io.files['$_vaultPath/skip.bin'] = Uint8List.fromList([1, 2, 3]);
      h.changes.emit(const FileCreatedEvent(relativePath: 'skip.bin'));
      h.io.files['$_vaultPath/ok.dat'] = Uint8List.fromList([4, 5, 6]);
      h.changes.emit(const FileCreatedEvent(relativePath: 'ok.dat'));

      await pushed;
      final ex = await excluded as SyncFileTypeExcluded;
      expect(ex.extension, 'bin');

      expect(
        h.events.whereType<SyncFilePushed>().where((e) => e.path == 'skip.bin'),
        isEmpty,
        reason: 'an excluded-type file must never be pushed',
      );
    });

    test('the folder filter keeps out-of-scope files off disk, and widening '
        'it backfills them', () async {
      final remote = _MemRemote();

      // Device A syncs the whole vault and publishes two files in different
      // folders.
      final a = await _Harness.create(sharedRemote: remote);
      addTearDown(a.dispose);
      a.io.files['$_vaultPath/Work/plan.bin'] =
          Uint8List.fromList(List.generate(64, (i) => i));
      a.io.files['$_vaultPath/Personal/diary.bin'] =
          Uint8List.fromList(List.generate(64, (i) => 255 - i));
      await a.engine.start();
      final records = _recordsFromPuts(a.state);
      expect(records.length, 2, reason: 'A must publish both files');

      // Device B syncs only Work/. The scope is read live, so the same engine
      // instance can be restarted with a wider one below — exactly what the
      // settings callback does.
      var scope = PathScope(include: ['Work']);
      final b = await _Harness.create(
        sharedRemote: remote,
        pathScope: () => scope,
      );
      addTearDown(b.dispose);
      b.state.recordsFor = (since) => since == 0 ? records : const [];
      b.state.getCursor = records.last.serverSeq;
      await b.engine.start();

      expect(b.io.files.containsKey('$_vaultPath/Work/plan.bin'), isTrue,
          reason: 'the in-scope file is materialised');
      expect(b.io.files.containsKey('$_vaultPath/Personal/diary.bin'), isFalse,
          reason: 'the out-of-scope file must not be written to disk');
      expect(
        b.events.whereType<SyncFileOutOfScope>().map((e) => e.path),
        contains('Personal/diary.bin'),
      );

      // The user widens the scope to the whole vault and the host restarts the
      // engine. The pull cursor has long since passed those records, so only
      // the startup backfill can bring the file down.
      scope = PathScope.everything;
      await b.engine.stop();
      // Cursor already at the head: a fresh pull returns nothing new, which is
      // the whole point — the backfill works off local state, not the wire.
      b.state.recordsFor = (since) => const [];
      await b.engine.start();

      expect(b.io.files.containsKey('$_vaultPath/Personal/diary.bin'), isTrue,
          reason: 'widening the scope must backfill what was skipped');
      expect(
        b.io.files['$_vaultPath/Personal/diary.bin'],
        a.io.files['$_vaultPath/Personal/diary.bin'],
        reason: 'and the bytes must be the real content',
      );
    });

    test('an out-of-scope file costs no bandwidth — its blobs are never '
        'requested, not merely discarded after the fact', () async {
      final remote = _MemRemote();

      final a = await _Harness.create(sharedRemote: remote);
      addTearDown(a.dispose);
      a.io.files['$_vaultPath/Work/plan.bin'] =
          Uint8List.fromList(List.generate(64, (i) => i));
      a.io.files['$_vaultPath/Personal/diary.bin'] =
          Uint8List.fromList(List.generate(64, (i) => 255 - i));
      await a.engine.start();
      final records = _recordsFromPuts(a.state);
      expect(records.length, 2);

      final b = await _Harness.create(
        sharedRemote: remote,
        pathScope: () => PathScope(include: ['Work']),
      );
      addTearDown(b.dispose);
      b.state.recordsFor = (since) => since == 0 ? records : const [];
      b.state.getCursor = records.last.serverSeq;
      remote.downloadedIds.clear();
      await b.engine.start();

      expect(b.io.files.containsKey('$_vaultPath/Work/plan.bin'), isTrue);
      expect(b.io.files.containsKey('$_vaultPath/Personal/diary.bin'), isFalse);

      // Which record carries which path is only visible after decrypting, so
      // identify them by what was fetched: exactly one file's chunks may have
      // been asked for, and the other's must never appear on the wire.
      final asked = remote.downloadedIds.toSet();
      final fetched =
          records.where((r) => r.chunks.any(asked.contains)).toList();
      expect(fetched, hasLength(1),
          reason: 'only the in-scope file may reach the network');
      final skipped =
          records.firstWhere((r) => !identical(r, fetched.single));
      for (final chunk in skipped.chunks) {
        expect(asked, isNot(contains(chunk)),
            reason: 'no chunk of a filtered file may be requested');
      }
      expect(asked, isNot(contains(skipped.blobRef)),
          reason: 'not even its manifest');
    });

    test("an attachment's chunks leave the cache once the file itself holds "
        'them, and it still syncs', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.engine.start();

      final pushed = h.engine.events
          .firstWhere((e) => e is SyncFilePushed && e.path == 'att/photo.bin')
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/att/photo.bin'] =
          Uint8List.fromList(List.generate(4096, (i) => (i * 37) % 256));
      h.changes.emit(const FileCreatedEvent(relativePath: 'att/photo.bin'));
      await pushed;

      // Right after the upload the cache holds a full second copy: that is
      // what the eviction exists to remove.
      final cachedBefore =
          await h.engine.blobStore.listBlobIds(vaultId: _vaultId);
      expect(cachedBefore, isNotEmpty);

      await h.engine.runLocalBlobGc();

      final cachedAfter =
          await h.engine.blobStore.listBlobIds(vaultId: _vaultId);
      expect(cachedAfter, isEmpty,
          reason: 'the vault file is the copy; the cache need not be a second');

      // And the file is still perfectly syncable: the record the peer needs
      // was pushed, and its bytes are on the server, not in our cache.
      final pushedState = h.state.puts
          .expand((p) => p.items)
          .lastWhere((it) => !it.tombstone);
      expect(pushedState.chunks, isNotEmpty);
      for (final chunk in pushedState.chunks) {
        expect(h.remote.store.containsKey(chunk), isTrue,
            reason: 'evicting locally must never touch the server copy');
      }
    });

    test('a text note keeps its cached blob — disk holds a projection, not it',
        () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.engine.start();

      final pushed = h.engine.events
          .firstWhere((e) => e is SyncFilePushed && e.path == 'note.md')
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/note.md'] =
          Uint8List.fromList('hello notes'.codeUnits);
      h.changes.emit(const FileCreatedEvent(relativePath: 'note.md'));
      await pushed;

      await h.engine.runLocalBlobGc();

      expect(await h.engine.blobStore.listBlobIds(vaultId: _vaultId), isNotEmpty,
          reason: "a note's blob is its Fugue tree, which disk does not hold");
    });

    test('a pushed file is not re-pushed on every notify-triggered pull '
        '(no push -> notify -> pull -> push storm)', () async {
      // Regression: the server echoes a device's own write back as a notify;
      // getStates since our cursor then returns nothing (own writes filtered).
      // Each notify triggers a pull whose post-pull _push() re-collects dirty
      // files. A locally-created file's synced LCA never advances on push (only
      // _materialise / a sealed merge do), so it stays "isNew" forever — and
      // without the _lastPushed guard on the plain path it was re-pushed on
      // EVERY pull, an unbounded push/notify/pull/push loop (cursor climbed
      // hundreds of seqs in seconds in the field).
      final h = await _Harness.create();
      addTearDown(h.dispose);

      // Binary so the blobRef is a deterministic manifest hash (no Fugue
      // re-serialization noise) and the file never converges with a peer.
      h.io.files['$_vaultPath/photo.bin'] = Uint8List.fromList(
        List.generate(2000, (i) => (i * 7) % 256),
      );
      await h.engine.start();

      final putsAfterStartup = h.state.puts.length;
      expect(
        putsAfterStartup,
        greaterThan(0),
        reason: 'startup must publish the new file exactly once',
      );

      // Model the echo: every pull returns no records (server filtered our own
      // write), and its post-pull push must find nothing new to send.
      h.state.recordsFor = (since) => const [];
      for (var i = 0; i < 5; i++) {
        await h.engine.triggerPull();
      }

      expect(
        h.state.puts.length,
        putsAfterStartup,
        reason:
            'an unchanged, already-pushed file must not be re-pushed on '
            'every pull — otherwise push/notify/pull/push loops forever',
      );

      // A genuine content change must STILL push (the guard keys on blobRef, so
      // a new version clears it) — the fix must not wedge real edits.
      final pushed = h.engine.events
          .firstWhere((e) => e is SyncFilePushed && e.path == 'photo.bin')
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/photo.bin'] = Uint8List.fromList(
        List.generate(2000, (i) => (i * 11) % 256),
      );
      h.changes.emit(const FileModifiedEvent(relativePath: 'photo.bin'));
      await pushed;
      expect(
        h.state.puts.length,
        greaterThan(putsAfterStartup),
        reason: 'a real edit (new blobRef) must still be pushed',
      );
    });

    test('a file the pusher will not send is dropped from the pending set '
        '(no stuck "pending changes" indicator)', () async {
      // Regression: a rename/delete could mark a file pending, but the pusher
      // then finds nothing to send for it (its value is already on the server,
      // or a tombstone whose create was never confirmed can't be committed).
      // Before the fix the fileId lingered in the pending set forever and the
      // amber "pending changes" status never cleared.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.engine.start();

      // Create + push a file. Its create reaches the server but is never
      // materialised back (synced stays null) — the ordinary single-file case.
      final pushed = h.engine.events
          .firstWhere((e) => e is SyncFilePushed && e.path == 'photo.bin')
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/photo.bin'] = Uint8List.fromList(
        List.generate(64, (i) => i),
      );
      h.changes.emit(const FileCreatedEvent(relativePath: 'photo.bin'));
      await pushed;

      // Delete it. reconcile writes a tombstone and marks the file pending, but
      // the tombstone cannot be committed (synced == null), so the pusher sends
      // nothing. The pending set must still be reconciled to empty.
      final wentPending = h.engine.events
          .firstWhere((e) => e is SyncPending && e.hasPending)
          .timeout(const Duration(seconds: 10));
      h.io.files.remove('$_vaultPath/photo.bin');
      h.changes.emit(const FileDeletedEvent(relativePath: 'photo.bin'));
      await wentPending;

      // The indicator must return to "no pending" — this is the fix. Under the
      // old code the last SyncPending stayed hasPending:true forever.
      await _eventually(
        () =>
            h.events.whereType<SyncPending>().isNotEmpty &&
            !h.events.whereType<SyncPending>().last.hasPending,
      );
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

  // -------------------------------------------------------------------------
  // Auth binding. A connection takes its bearer provider ONCE, at connect
  // time. These pin what that implies for a host that signs in while the
  // engine is already running — the shape of a real production loop where a
  // re-authenticated user kept being told the session had expired.
  // -------------------------------------------------------------------------
  group('token provider binding', () {
    test('each start binds the connection to the config it has AT THAT MOMENT '
        '— a provider swapped in later is not retroactive', () async {
      final first = MutableTokenProvider(StaticTokenProvider('first'));
      final h = await _Harness.create(tokenProvider: first);
      addTearDown(h.dispose);

      await h.engine.start();
      expect(h.connection.boundProviders, [same(first)]);

      // Host swaps in a different provider (the pattern that broke: build a
      // new provider per sign-in and assign it to engine.config).
      final second = MutableTokenProvider(StaticTokenProvider('second'));
      h.engine.config = h.engine.config.copyWith(tokenProvider: second);
      expect(
        h.connection.boundProviders,
        [same(first)],
        reason:
            'the live connection still authenticates as whoever opened '
            'it — assigning config cannot re-authenticate a bound socket',
      );

      await h.engine.stop();
      await h.engine.start();
      expect(
        h.connection.boundProviders.last,
        same(second),
        reason:
            'only a restart rebinds — so a host that swaps providers '
            'MUST restart the engine',
      );
    });

    test('a provider mutated in place reaches a connection that was opened '
        'before the sign-in', () async {
      // The other half of the fix: keep one provider for the whole session
      // and mutate it, and the already-bound connection picks up the new
      // session on its next call — no restart needed to authenticate.
      final provider = MutableTokenProvider();
      final h = await _Harness.create(tokenProvider: provider);
      addTearDown(h.dispose);

      await h.engine.start();
      final bound = h.connection.boundProviders.single!;
      expect(bound, same(provider));
      await expectLater(
        bound.getToken(),
        throwsA(isA<MissingAuthTokenException>()),
        reason:
            'signed out: calls must fail locally, never go out with no '
            'Authorization header',
      );

      provider.delegate = StaticTokenProvider('after-sign-in');

      expect(await bound.getToken(), 'after-sign-in');
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
    IVaultCipher? cipher,
    Set<String> Function()? excludedExtensions,
    PathScope Function()? pathScope,
    ITokenProvider? tokenProvider,
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
      config: VaultConfig(
        vaultId: _vaultId,
        vaultName: 'test',
        tokenProvider: tokenProvider,
      ),
      cipher: cipher ?? _IdentityCipher(),
      dataClient: env.client,
      blobStore: LocalBlobStore(InMemoryBlobRepository()),
      io: io,
      changeProvider: changes,
      scheduler: sched,
      excludedExtensions: excludedExtensions,
      pathScope: pathScope,
      connectionFactory: ({required serverUrl, tokenProvider, logger}) {
        connection.boundProviders.add(tokenProvider);
        return connection;
      },
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

  /// When set, getStates throws this on its FIRST call only — models a
  /// transient startup-pull failure. Later calls (e.g. healthCheck) behave
  /// normally, so a test can observe whether the engine was left a zombie.
  Object? failFirstGetStatesWith;
  bool _firstGetStatesFailed = false;

  @override
  Future<StateGetResponse> getStates(
    StateGetRequest request, {
    RpcContext? context,
  }) async {
    getSince.add(request.sinceCursor);
    if (failFirstGetStatesWith != null && !_firstGetStatesFailed) {
      _firstGetStatesFailed = true;
      throw failFirstGetStatesWith!;
    }
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
  @override
  Future<StatePurgeResponse> purgeVault(
    StatePurgeRequest request, {
    RpcContext? context,
  }) async => const StatePurgeResponse();
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

  @override
  Future<ForgetDeviceResponse> forgetDevice(
    ForgetDeviceRequest request, {
    RpcContext? context,
  }) async => const ForgetDeviceResponse(removed: false);
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

  /// The token provider handed to the factory on each (re)start. A
  /// connection binds its bearer interceptor once, at connect time, so this
  /// is the complete record of what a socket can authenticate as.
  final List<ITokenProvider?> boundProviders = [];

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

  /// Every blob id this device actually asked the server for. Lets a test
  /// assert that a filtered file cost no bandwidth, not merely that it was
  /// left off disk.
  final List<String> downloadedIds = [];

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
  }) async {
    downloadedIds.addAll(blobIds);
    return {
      for (final id in blobIds)
        if (store.containsKey(id)) id: store[id]!,
    };
  }

  @override
  Future<void> deleteMany(List<String> blobIds, {RpcContext? context}) async {
    for (final id in blobIds) {
      store.remove(id);
    }
  }
}

/// Like [_MemRemote], but when [blockDownloads] is set a download wedges until
/// its [RpcContext] is cancelled, then throws [RpcCancelledException] — modelling
/// a stalled server-stream that honours cancellation. Lets a test drive the
/// pull-preemption path deterministically. Extends [_MemRemote] so it satisfies
/// the harness's `sharedRemote` type and reuses upload/exists/delete.
class _BlockingRemote extends _MemRemote {
  bool blockDownloads = false;

  /// Completes the first time a blocked download is entered, so the test can
  /// wait for the pull to actually reach the stall before preempting it.
  final Completer<void> downloadEntered = Completer<void>();

  /// How many blocked downloads were released by a cancellation (preempt).
  int downloadsCancelled = 0;

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    if (blockDownloads) {
      if (!downloadEntered.isCompleted) downloadEntered.complete();
      final token = context?.cancellationToken;
      if (token != null) {
        await token.cancelled;
        downloadsCancelled += 1;
        throw RpcCancelledException(token.reason ?? 'cancelled');
      }
    }
    return super.download(blobIds, context: context);
  }
}

/// Minimal in-memory filesystem. Paths are opaque keys; listFiles returns
/// everything under the given dir prefix.
class _InMemoryIO implements IPlatformIO {
  final Map<String, Uint8List> files = {};

  /// Absolute paths whose deleteFile should throw — models a filesystem
  /// that refuses to remove a file (permissions, lock, etc.).
  final Set<String> failDeletePaths = {};

  /// When true, listFiles throws — used to make a restore fail mid-way.
  bool failListFiles = false;

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
  Future<List<String>> listFiles(String absoluteDirPath) async {
    if (failListFiles) throw StateError('listFiles failed');
    return files.keys
        .where((p) => p.startsWith('$absoluteDirPath/'))
        .toList(growable: false);
  }

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
    if (failDeletePaths.contains(absolutePath)) {
      throw StateError('refusing to delete $absolutePath');
    }
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
