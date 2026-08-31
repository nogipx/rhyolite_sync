import 'dart:async';
import 'dart:convert';

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
  _repairPullsFirst();
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

    test('restore deletes only what this device syncs — the folder filter and '
        'the type denylist are not a delete list', () async {
      // Restore means "make this device match the server". A file the filters
      // keep out was never uploaded, so nothing downloads it back: sweeping it
      // up with the rest is a one-way loss of a file the user explicitly told
      // us not to manage.
      final h = await _Harness.create(
        pathScope: () => PathScope(include: ['Work']),
        excludedExtensions: () => {'tmp'},
      );
      addTearDown(h.dispose);
      h.io.files['$_vaultPath/Work/plan.md'] = Uint8List.fromList(
        'synced'.codeUnits,
      );
      h.io.files['$_vaultPath/Work/scratch.tmp'] = Uint8List.fromList(
        'excluded type'.codeUnits,
      );
      h.io.files['$_vaultPath/Personal/diary.md'] = Uint8List.fromList(
        'out of scope'.codeUnits,
      );
      await h.engine.start();

      await h.engine.triggerRestoreFromServer();

      expect(
        h.io.files.containsKey('$_vaultPath/Work/plan.md'),
        isFalse,
        reason: 'the synced file still yields to the server copy',
      );
      expect(
        h.io.files['$_vaultPath/Work/scratch.tmp'],
        isNotNull,
        reason: 'an excluded type has no server copy to come back as',
      );
      expect(
        h.io.files['$_vaultPath/Personal/diary.md'],
        isNotNull,
        reason: 'an out-of-scope folder has no server copy to come back as',
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
      a.io.files['$_vaultPath/Work/plan.bin'] = Uint8List.fromList(
        List.generate(64, (i) => i),
      );
      a.io.files['$_vaultPath/Personal/diary.bin'] = Uint8List.fromList(
        List.generate(64, (i) => 255 - i),
      );
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

      expect(
        b.io.files.containsKey('$_vaultPath/Work/plan.bin'),
        isTrue,
        reason: 'the in-scope file is materialised',
      );
      expect(
        b.io.files.containsKey('$_vaultPath/Personal/diary.bin'),
        isFalse,
        reason: 'the out-of-scope file must not be written to disk',
      );
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

      expect(
        b.io.files.containsKey('$_vaultPath/Personal/diary.bin'),
        isTrue,
        reason: 'widening the scope must backfill what was skipped',
      );
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
      a.io.files['$_vaultPath/Work/plan.bin'] = Uint8List.fromList(
        List.generate(64, (i) => i),
      );
      a.io.files['$_vaultPath/Personal/diary.bin'] = Uint8List.fromList(
        List.generate(64, (i) => 255 - i),
      );
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
      final fetched = records
          .where((r) => r.chunks.any(asked.contains))
          .toList();
      expect(
        fetched,
        hasLength(1),
        reason: 'only the in-scope file may reach the network',
      );
      final skipped = records.firstWhere((r) => !identical(r, fetched.single));
      for (final chunk in skipped.chunks) {
        expect(
          asked,
          isNot(contains(chunk)),
          reason: 'no chunk of a filtered file may be requested',
        );
      }
      expect(
        asked,
        isNot(contains(skipped.blobRef)),
        reason: 'not even its manifest',
      );
    });

    test("an attachment's chunks leave the cache once the file itself holds "
        'them, and it still syncs', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.engine.start();

      final pushed = h.engine.events
          .firstWhere((e) => e is SyncFilePushed && e.path == 'att/photo.bin')
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/att/photo.bin'] = Uint8List.fromList(
        List.generate(4096, (i) => (i * 37) % 256),
      );
      h.changes.emit(const FileCreatedEvent(relativePath: 'att/photo.bin'));
      await pushed;

      // Right after the upload the cache holds a full second copy: that is
      // what the eviction exists to remove.
      final cachedBefore = await h.engine.blobStore.listBlobIds(
        vaultId: _vaultId,
      );
      expect(cachedBefore, isNotEmpty);

      await h.engine.runLocalBlobGc();

      final cachedAfter = await h.engine.blobStore.listBlobIds(
        vaultId: _vaultId,
      );
      expect(
        cachedAfter,
        isEmpty,
        reason: 'the vault file is the copy; the cache need not be a second',
      );

      // And the file is still perfectly syncable: the record the peer needs
      // was pushed, and its bytes are on the server, not in our cache.
      final pushedState = h.state.puts
          .expand((p) => p.items)
          .lastWhere((it) => !it.tombstone);
      expect(pushedState.chunks, isNotEmpty);
      for (final chunk in pushedState.chunks) {
        expect(
          h.remote.store.containsKey(chunk),
          isTrue,
          reason: 'evicting locally must never touch the server copy',
        );
      }
    });

    test('a large file being pulled names itself while it transfers', () async {
      // The applier used to do the downloading and knew the path. Now the
      // prefetch warms the cache first, so by the time the applier runs there
      // is nothing left to narrate — and the minutes spent on a big
      // attachment looked, from the panel, exactly like a hang.
      final remote = _MemRemote();

      final a = await _Harness.create(sharedRemote: remote);
      addTearDown(a.dispose);
      // Comfortably over the 1 MiB narration floor, and incompressible so it
      // really is chunked rather than deduped away.
      a.io.files['$_vaultPath/att/big.bin'] = Uint8List.fromList(
        List.generate(3 << 20, (i) => (i * 2654435761) & 0xFF),
      );
      await a.engine.start();
      final records = _recordsFromPuts(a.state);

      final b = await _Harness.create(sharedRemote: remote);
      addTearDown(b.dispose);
      b.state.recordsFor = (since) => since == 0 ? records : const [];
      b.state.getCursor = records.last.serverSeq;
      await b.engine.start();
      await pumpEventQueue();

      final named = b.events
          .whereType<SyncBlobTransfer>()
          .where((e) => e.path == 'att/big.bin')
          .toList();
      expect(
        named,
        isNotEmpty,
        reason: 'the file has to say what it is while it is being fetched',
      );
      expect(
        named.any((e) => !e.upload),
        isTrue,
        reason: 'and say that it is coming down, not going up',
      );
      // Partial progress is what distinguishes the prefetch — the applier's
      // own download runs off a warm cache and reports one finished step, so
      // an assertion that only checks "some event exists" passes either way.
      expect(
        named.any(
          (e) => !e.done && e.totalBytes > 0 && e.sentBytes < e.totalBytes,
        ),
        isTrue,
        reason:
            'the transfer must be narrated WHILE it moves, not summarised '
            'after it is already in the cache',
      );
      expect(
        named.last.done,
        isTrue,
        reason:
            'and be retired from the active list when the batch ends, '
            'or it hangs around forever',
      );
    });

    test(
      'a start during a start supersedes it quietly instead of colliding',
      () async {
        // start() opens by stopping, and stop() nulls _store, _reconciler and
        // the connection. Nothing guarded that, so a second start pulled the
        // fields out from under the first, which died on `_store!`. Cheap to hit
        // once the auth path began restarting the engine repeatedly: four starts
        // in sixty seconds, two ending in "Null check operator used on a null
        // value" and a disposed BlobTransferHub.
        //
        // Worse than the noise: the loser's catch called stop(), so a dying
        // start could tear down the live one.
        final h = await _Harness.create();
        addTearDown(h.dispose);
        h.io.files['$_vaultPath/note.md'] = Uint8List.fromList(
          utf8.encode('hello\n'),
        );

        // Park the first start inside its initial pull — where a real start
        // spends its time, and where the collisions were observed.
        final gate = Completer<void>();
        h.state.getStatesGate = gate;
        final first = h.engine.start();
        for (var i = 0; i < 20 && h.state.getSince.isEmpty; i++) {
          await pumpEventQueue();
        }

        // A second start arrives while the first is still inside its pipeline.
        final second = h.engine.start();
        gate.complete();
        await first;
        await second;
        await pumpEventQueue();

        expect(
          h.events.whereType<SyncError>(),
          isEmpty,
          reason:
              'being superseded is not a sync failure and must not be '
              'reported as one',
        );

        // And the survivor is actually alive: it answers, which a torn-down
        // engine cannot.
        expect(
          await h.engine.healthCheck(),
          isTrue,
          reason: 'the losing start must not have stopped the winning one',
        );
      },
    );

    test('a stopped engine still reports the numbers it had', () async {
      // stop() nulls the store, so a stopped engine could answer nothing — and
      // a bug report is written about a stopped engine almost by definition.
      // One arrived with its entire sync-state section blank: no file count,
      // no cursor, nothing to reason from, in the document that existed to
      // carry exactly that.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      for (var i = 0; i < 3; i++) {
        h.io.files['$_vaultPath/note$i.md'] = Uint8List.fromList(
          utf8.encode('hello $i\n'),
        );
      }

      await h.engine.start();
      await pumpEventQueue();
      final live = h.engine.statsSnapshot();
      expect(live, isNotNull);
      expect(live!.capturedAt, isNull, reason: 'a live read is not stale');
      expect(live.totalFiles, 3);

      await h.engine.stop();
      final afterStop = h.engine.statsSnapshot();

      expect(
        afterStop,
        isNotNull,
        reason: 'the report must not go blank the moment sync stops',
      );
      expect(afterStop!.totalFiles, 3);
      expect(
        afterStop.capturedAt,
        isNotNull,
        reason: 'and it must say the numbers are no longer current',
      );
    });

    test(
      'unsent files are reported as pending, not as a finished sync',
      () async {
        // The indicator paints idle-without-pending GREEN. Pending was filled by
        // file-change events and nothing else, so the thousands of files a
        // startup pass creates never entered it — a vault with nine thousand
        // unsynced files reported none, and the dot said the sync was done. A
        // user reported exactly that: green, with about two thousand to go.
        final h = await _Harness.create();
        addTearDown(h.dispose);
        for (var i = 0; i < 3; i++) {
          h.io.files['$_vaultPath/note$i.md'] = Uint8List.fromList(
            utf8.encode('hello $i\n'),
          );
        }
        // The server refuses, so the files stay unsent and the question the
        // indicator asks has an unambiguous answer.
        h.state.failPutsAfter = 0;

        await h.engine.start();
        await pumpEventQueue();

        expect(
          h.events.whereType<SyncPending>().map((e) => e.hasPending),
          contains(true),
          reason:
              'files the server never took are unsent, whatever filled the '
              'in-memory set',
        );
      },
    );

    test('a vault the server has taken reports nothing pending', () async {
      // The other half: the set is a conservative superset until a push
      // classifies it, so it has to actually drain — or the indicator would
      // sit amber on a vault that is perfectly in sync.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      for (var i = 0; i < 3; i++) {
        h.io.files['$_vaultPath/note$i.md'] = Uint8List.fromList(
          utf8.encode('hello $i\n'),
        );
      }

      await h.engine.start();
      await pumpEventQueue();

      expect(
        h.events.whereType<SyncPending>().where((e) => e.hasPending),
        isEmpty,
        reason:
            'everything was accepted, so it must never have claimed '
            'otherwise — the set is a superset until a push drains it, and '
            'this is the check that it does drain',
      );
    });

    test('a big first sync is pushed in batches, not one giant call', () async {
      // The push sent everything in one request. Invisible at a hundred files
      // and fatal at nine thousand: the server writes the items one at a time
      // inside the call, the client allows thirty seconds, and a timeout keeps
      // every file dirty — the signature is only recorded on a response — so
      // the next attempt sends the same nine thousand again, forever.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      for (var i = 0; i < 250; i++) {
        h.io.files['$_vaultPath/note$i.md'] = Uint8List.fromList(
          utf8.encode('hello $i\n'),
        );
      }

      await h.engine.start();
      await pumpEventQueue();

      expect(
        h.state.puts.length,
        greaterThan(1),
        reason: '250 files must not go out as a single request',
      );
      for (final put in h.state.puts) {
        expect(
          put.items.length,
          lessThanOrEqualTo(200),
          reason: 'no batch may exceed the size the deadline was chosen for',
        );
      }
      final pushed = <String>{
        for (final put in h.state.puts)
          for (final item in put.items) item.fileId,
      };
      expect(pushed, hasLength(250), reason: 'batching must not drop any file');
    });

    test('states are published while the upload is still running', () async {
      // They used to wait for the whole pass. On a large vault that is an hour
      // in which the server learns nothing — one report showed 780 blob
      // uploads and not one state record — and an interruption anywhere in it
      // left the server as empty as it started.
      //
      // Timing is the whole claim, so it is tested as timing: the uploads are
      // frozen part-way and the question is whether anything reached the
      // server before that point. Counting calls could not tell the two apart.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      for (var i = 0; i < 60; i++) {
        h.io.files['$_vaultPath/note$i.md'] = Uint8List.fromList(
          utf8.encode('hello $i\n'),
        );
      }
      // Zero, so the interval does not make the test wait on a wall clock.
      // What is being pinned is that publishing happens DURING the pass, not
      // how often — the production interval is documented where it lives.
      h.engine.startupPublishInterval = Duration.zero;
      // Counted in upload CALLS, and a call is now a group of eight notes
      // rather than one note: four workers × two requests each (chunks, then
      // manifests) is eight calls before any group is free to commit. Parking
      // at the ninth lets the first four groups land and freezes the rest.
      h.remote.parkUploadsFrom = 9;

      final started = h.engine.start();
      await h.remote.uploadsParked.future.timeout(const Duration(seconds: 20));
      await pumpEventQueue();

      final publishedMidPass = <String>{
        for (final put in h.state.puts)
          for (final item in put.items) item.fileId,
      };
      expect(
        publishedMidPass,
        isNotEmpty,
        reason: 'the server must hear about files before the pass ends',
      );

      h.remote.releaseUploads();
      await started;
      await pumpEventQueue();
      final all = <String>{
        for (final put in h.state.puts)
          for (final item in put.items) item.fileId,
      };
      expect(all, hasLength(60), reason: 'and still all of them by the end');
    });

    test('a batch that lands is banked when a later one fails', () async {
      // The same lesson as everywhere else today: a long operation must not be
      // all-or-nothing. Signatures for the batches that landed are on their
      // rows, so the retry sends what is left instead of starting over.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      for (var i = 0; i < 250; i++) {
        h.io.files['$_vaultPath/note$i.md'] = Uint8List.fromList(
          utf8.encode('hello $i\n'),
        );
      }
      h.state.failPutsAfter = 1;

      await h.engine.start();
      await pumpEventQueue();

      final firstRunPuts = h.state.puts.length;
      expect(firstRunPuts, 1, reason: 'the second batch was refused');

      // Retry with a healthy server.
      h.state.failPutsAfter = null;
      h.state.puts.clear();
      await h.engine.stop();
      await h.engine.start();
      await pumpEventQueue();

      final resent = <String>{
        for (final put in h.state.puts)
          for (final item in put.items) item.fileId,
      };
      expect(
        resent,
        hasLength(50),
        reason: 'only the files the failed batch never carried',
      );
    });

    test('files found by the startup scan are pushed', () async {
      // The push path no longer walks the whole vault to work out what the
      // server is missing; it walks a set the store maintains. The startup
      // diff writes its states straight into the store and tells nobody, and
      // the host's pending set is memory-only and empty after a restart — so
      // if those writes did not land in that set, a first sync would upload
      // every blob and publish nothing. Which is exactly what one vault did
      // for an hour, for a different reason.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      for (var i = 0; i < 3; i++) {
        h.io.files['$_vaultPath/note$i.md'] = Uint8List.fromList(
          utf8.encode('hello $i\n'),
        );
      }

      await h.engine.start();
      await pumpEventQueue();

      final pushed = <String>{
        for (final put in h.state.puts)
          for (final item in put.items) item.fileId,
      };
      expect(
        pushed,
        hasLength(3),
        reason: 'every file the scan found must reach the server',
      );
    });

    test('a start superseded DURING the connect dies quietly too', () async {
      // The sibling above parks the loser in the initial pull, which is past
      // the point where the fields are first dereferenced. The connect is
      // earlier and far longer — a report showed 46 seconds — and the
      // generation was checked before it and not again after, so a start
      // superseded in that window came back to `_store!` and threw "Null check
      // operator used on a null value" in the same millisecond the socket
      // came up.
      final h = await _Harness.create();
      addTearDown(h.dispose);

      final gate = Completer<void>();
      h.connection.connectGate = gate;
      final first = h.engine.start();
      await pumpEventQueue();

      // Supersede while the first is still inside connect(). Its own gate must
      // be cleared, or the second start parks on the same completer.
      h.connection.connectGate = null;
      final second = h.engine.start();
      gate.complete();
      await first;
      await second;
      await pumpEventQueue();

      expect(
        h.events.whereType<SyncError>(),
        isEmpty,
        reason:
            'a superseded start is not a failure, and above all must '
            'not surface as a null-check crash',
      );
      // The observable consequence of the guard, and the one the fake can
      // show: the loser returns at the checkpoint instead of carrying on into
      // the pipeline. Asserting on a null-check crash directly is not possible
      // here — the winner reassigns `_store` before the loser resumes, so in a
      // fake the loser finds the WINNER's store rather than a null one and
      // corrupts it quietly instead of throwing. Announcing a connection it is
      // no longer running is the same wrong behaviour, visibly.
      expect(
        h.events.whereType<SyncConnected>().length,
        1,
        reason: 'only the surviving start may announce a connection',
      );
      expect(
        await h.engine.healthCheck(),
        isTrue,
        reason: 'the survivor must still be running',
      );
    });

    test('a pull asked for during startup does not race the startup pull, and '
        'is not lost either', () async {
      // The startup pull runs outside the scheduler, so the 'pull' key cannot
      // coalesce against it. A notify or a visibility resume landing mid-start
      // used to begin a SECOND pull from the same un-advanced cursor and
      // re-fetch every record the first was still applying — observed on a
      // restore as 270 records applied twice, 68 s instead of 45.
      final h = await _Harness.create();
      addTearDown(h.dispose);

      // Park start() mid-pipeline: a file to push means StartupDiff reaches
      // putStates, which the fake gates.
      h.io.files['$_vaultPath/note.md'] = Uint8List.fromList(
        utf8.encode('hello\n'),
      );
      final gate = Completer<void>();
      h.state.putStatesGate = gate;
      final starting = h.engine.start();
      for (var i = 0; i < 20 && h.state.puts.isEmpty; i++) {
        await pumpEventQueue();
      }

      final beforeTrigger = h.state.getSince.length;
      await h.engine.triggerPull();
      await pumpEventQueue();

      expect(
        h.state.getSince.length,
        beforeTrigger,
        reason:
            'no second getStates while the startup pull still owns the '
            'cursor — that is the race: both read it un-advanced and fetch '
            'the same records',
      );

      // And it is not dropped: startup completing releases it. It goes back
      // through the scheduler, so give that a few turns.
      gate.complete();
      await starting;
      for (var i = 0; i < 20 && h.state.getSince.length == beforeTrigger; i++) {
        await pumpEventQueue();
      }
      expect(
        h.state.getSince.length,
        greaterThan(beforeTrigger),
        reason:
            'a pull requested during startup has to happen eventually — '
            'dropping it loses whatever the notify was about',
      );
    });

    test(
      'busy is held across the whole startup pipeline and released after',
      () async {
        // The indicator must not be inferred from how densely a phase reports
        // progress. Before this, a gap between progress events let the UI say
        // "up to date" mid-download — and someone who believes that and quits
        // loses the rest of the transfer.
        final remote = _MemRemote();
        final a = await _Harness.create(sharedRemote: remote);
        addTearDown(a.dispose);
        for (var i = 0; i < 4; i++) {
          a.io.files['$_vaultPath/n$i.md'] = Uint8List.fromList(
            utf8.encode('note $i\n'),
          );
        }
        await a.engine.start();
        final records = _recordsFromPuts(a.state);

        final b = await _Harness.create(sharedRemote: remote);
        addTearDown(b.dispose);
        b.state.recordsFor = (since) => since == 0 ? records : const [];
        b.state.getCursor = records.last.serverSeq;
        await b.engine.start();
        // Broadcast delivery is asynchronous: the listener has not run yet.
        await pumpEventQueue();

        final busy = b.events.whereType<SyncBusy>().toList();
        expect(
          busy.map((e) => e.busy),
          [true, false],
          reason: 'exactly one transition each way for one start',
        );

        final order = b.events.toList();
        final busyOn = order.indexWhere((e) => e is SyncBusy && e.busy);
        final busyOff = order.indexWhere((e) => e is SyncBusy && !e.busy);
        final pulled = order.indexWhere((e) => e is SyncFilePulled);
        expect(busyOn, lessThan(pulled));
        expect(
          busyOff,
          greaterThan(pulled),
          reason:
              'busy must still be held while the pull is applying, or the '
              'UI goes quiet in the middle of it',
        );
      },
    );

    test(
      'busy is released even when the work is torn down mid-flight',
      () async {
        // The release lives in a finally for this reason: these bodies end by
        // being preempted at least as often as they end by finishing, and a
        // release only on the success path leaves the UI claiming work forever.
        final h = await _Harness.create();
        addTearDown(h.dispose);
        await h.engine.start();
        h.events.clear();

        // Stop mid-session: whatever is in flight is torn down without any
        // finally further up getting to run.
        await h.engine.stop();
        await pumpEventQueue();

        final busy = h.events.whereType<SyncBusy>().toList();
        if (busy.isNotEmpty) {
          expect(
            busy.last.busy,
            isFalse,
            reason: 'a torn-down engine must not leave the indicator busy',
          );
        }
        expect(h.events.whereType<SyncStopped>(), isNotEmpty);
      },
    );

    test('the engine calls itself connected once the socket is up, not once '
        'the startup pipeline finishes', () async {
      // These events used to straddle the whole pipeline, so on a full
      // download the engine reported "connecting" for the entire initial pull
      // — 49 s of it, while visibly transferring files. The panel then showed
      // "Connecting…" every time its activity debounce lapsed mid-pull.
      final remote = _MemRemote();

      final a = await _Harness.create(sharedRemote: remote);
      addTearDown(a.dispose);
      for (var i = 0; i < 4; i++) {
        a.io.files['$_vaultPath/n$i.md'] = Uint8List.fromList(
          utf8.encode('note $i\n'),
        );
      }
      await a.engine.start();
      final records = _recordsFromPuts(a.state);

      final b = await _Harness.create(sharedRemote: remote);
      addTearDown(b.dispose);
      b.state.recordsFor = (since) => since == 0 ? records : const [];
      b.state.getCursor = records.last.serverSeq;
      await b.engine.start();

      final order = b.events.map((e) => e.runtimeType.toString()).toList();
      final connected = order.indexOf('SyncConnected');
      final pulled = order.indexWhere((t) => t == 'SyncFilePulled');
      expect(
        connected,
        greaterThanOrEqualTo(0),
        reason: 'the engine must announce the connection at all',
      );
      expect(
        pulled,
        greaterThanOrEqualTo(0),
        reason: 'and this pull must have applied something',
      );
      expect(
        connected,
        lessThan(pulled),
        reason:
            'connected must precede the pull it is meant to enable — if '
            'it trails, the UI spends the whole download being told the '
            'engine is still connecting',
      );
    });

    test(
      'startup progress counts files, whatever the uploads are packed into',
      () async {
        // Jobs used to be one per file; grouping the uploads made a job up to
        // eight, and the counter followed it — the log read "processing 2
        // file(s)" for sixteen and the bar advanced in steps of eight. The unit
        // the user sees must not depend on how the work happens to be packed.
        final h = await _Harness.create();
        addTearDown(h.dispose);
        for (var i = 0; i < 12; i++) {
          h.io.files['$_vaultPath/att/f$i.bin'] = Uint8List.fromList(
            List.generate(64, (b) => (b + i) % 256),
          );
        }
        await h.engine.start();
        await pumpEventQueue();

        final progress = h.events
            .whereType<SyncStartupBlobUploadProgress>()
            .toList();
        expect(progress, isNotEmpty);
        expect(
          progress.last.total,
          12,
          reason: 'twelve files is twelve, not two groups',
        );
        expect(progress.last.completed, 12);
        // Two groups would report at most three distinct completed values
        // (0, 8, 12); per file gives thirteen.
        expect(
          progress.map((e) => e.completed).toSet().length,
          greaterThan(4),
          reason: 'the bar must move per file, not once per group',
        );
      },
    );

    test('a startup upload sends a group in a couple of round trips, not two '
        'per file', () async {
      // Symmetric to the pull. upload() costs a request for a file's chunks
      // and another for its manifest, and the startup path called it once per
      // file: a 251-file re-upload was 502 requests. Counting CALLS is the
      // point — the per-file version moved exactly the same bytes.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      for (var i = 0; i < 12; i++) {
        h.io.files['$_vaultPath/att/f$i.bin'] = Uint8List.fromList(
          List.generate(64, (b) => (b + i) % 256),
        );
      }
      h.remote.uploadCalls = 0;
      await h.engine.start();

      expect(h.state.puts, isNotEmpty, reason: 'the files must have published');
      expect(
        h.remote.uploadCalls,
        lessThan(12),
        reason:
            'fewer calls than files is impossible per-file, which is '
            'what makes this meaningful',
      );
      expect(
        h.remote.uploadCalls,
        lessThanOrEqualTo(6),
        reason:
            'twelve files are two groups of eight and four, each costing '
            'a chunk request and a manifest request',
      );
    });

    test('notes are grouped too, not two round trips each', () async {
      // The half that was missed. Binaries have been grouped for a while;
      // notes went through the reconciler, which decided, uploaded and
      // committed one file at a time — so 188 notes cost 376 requests where
      // 188 binaries would have cost 48.
      //
      // Invisible on the managed backend, where a request is cheap. On a BYO
      // WebDAV each one costs seconds: a 188-note vault took 411s, and the
      // per-file log said `upload=4823ms` for a 2 KB blob — almost all of it
      // waiting for a slot, not moving bytes.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      for (var i = 0; i < 12; i++) {
        h.io.files['$_vaultPath/note$i.md'] = Uint8List.fromList(
          utf8.encode('hello $i\n'),
        );
      }
      h.remote.uploadCalls = 0;
      await h.engine.start();

      expect(h.state.puts, isNotEmpty, reason: 'the notes must have published');
      final pushed = <String>{
        for (final put in h.state.puts)
          for (final item in put.items) item.fileId,
      };
      expect(
        pushed,
        hasLength(12),
        reason: 'and all of them, not just a group',
      );
      expect(
        h.remote.uploadCalls,
        lessThanOrEqualTo(6),
        reason:
            'twelve notes are two groups of eight and four, each costing '
            'a chunk request and a manifest request — 24 means one file at '
            'a time again',
      );
    });

    test(
      'a pull fetches a batch in a couple of round trips, not two per file',
      () async {
        // The wire contract has always taken a LIST of blob ids and streamed
        // them back; the puller called it with one element, twice per file —
        // once for the manifest, once for its chunks. On a link with ~250 ms of
        // latency that, not bytes, was the cost of a pull: 207 files meant 414
        // requests for 8 s of actual apply.
        //
        // Counting CALLS rather than ids is the whole point of the test: the
        // per-file version moved exactly the same bytes.
        final remote = _MemRemote();

        final a = await _Harness.create(sharedRemote: remote);
        addTearDown(a.dispose);
        for (var i = 0; i < 12; i++) {
          a.io.files['$_vaultPath/note$i.md'] = Uint8List.fromList(
            utf8.encode('note number $i\n'),
          );
        }
        await a.engine.start();
        final records = _recordsFromPuts(a.state);
        expect(records.length, 12, reason: 'A must publish all twelve');

        final b = await _Harness.create(sharedRemote: remote);
        addTearDown(b.dispose);
        b.state.recordsFor = (since) => since == 0 ? records : const [];
        b.state.getCursor = records.last.serverSeq;
        remote.downloadCalls = 0;
        await b.engine.start();

        for (var i = 0; i < 12; i++) {
          expect(
            b.io.files.containsKey('$_vaultPath/note$i.md'),
            isTrue,
            reason: 'every note must still arrive',
          );
        }

        // Twelve files are one step of 32, fetched as two concurrent groups of
        // eight and four: a manifest request and a chunk request each. The old
        // code needed twenty-four.
        expect(
          remote.downloadCalls,
          lessThanOrEqualTo(6),
          reason:
              'a batch costs a request for its manifests and one for its '
              'chunks — if this climbs toward one per file, the prefetch went '
              'back to fetching files one at a time',
        );
        expect(
          remote.downloadCalls,
          lessThan(records.length),
          reason:
              'fewer calls than files is impossible per-file, which is '
              'what makes this assertion meaningful at all',
        );
      },
    );

    test('editing a note does not download the note being edited', () async {
      // A reconcile asks the document store for the note's tree, and the tree
      // is right there — the last reconcile wrote it. It fetched the blob
      // anyway, because the short-circuit demanded BOTH halves of the document
      // and a note with no frontmatter has no second half to demand. That is
      // most notes, and the cost was a round trip on every edit and on the
      // pre-join reconcile of every pull.
      //
      // How it surfaced: a startup uploaded 188 notes over 411 seconds and
      // then fetched 185 of them back a second later.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      // No frontmatter, deliberately — that is the shape that never cached.
      h.io.files['$_vaultPath/plain.md'] = Uint8List.fromList(
        utf8.encode('just a note\n'),
      );
      await h.engine.start();
      await pumpEventQueue();

      h.remote.downloadCalls = 0;
      final pushed = h.engine.events
          .firstWhere((e) => e is SyncFilePushed)
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/plain.md'] = Uint8List.fromList(
        utf8.encode('just a note, edited a bit longer\n'),
      );
      h.changes.emit(const FileModifiedEvent(relativePath: 'plain.md'));
      await pushed;

      expect(
        h.remote.downloadCalls,
        0,
        reason:
            'the tree this reconcile needs was written by the last one; '
            'fetching the blob to re-read a frontmatter tail that was never '
            'written is a round trip for nothing',
      );
    });

    test('this device does not fetch back what it just pushed', () async {
      // The pull goes out with a cursor from before the push was assigned its
      // seq, so the server hands our own records straight back. Nothing in
      // them is new here — the join collapses to the value already held, and
      // the file on disk is the one those bytes were made from. They were
      // fetched and then never read.
      //
      // One real startup uploaded 188 notes over 411 seconds and then fetched
      // 185 of them back a second later. Cheap where a round trip is cheap; on
      // a BYO WebDAV it is a second flight of the whole vault.
      final remote = _MemRemote();
      final h = await _Harness.create(sharedRemote: remote);
      addTearDown(h.dispose);
      for (var i = 0; i < 12; i++) {
        h.io.files['$_vaultPath/note$i.md'] = Uint8List.fromList(
          utf8.encode('note number $i\n'),
        );
      }
      await h.engine.start();
      final own = _recordsFromPuts(h.state);
      expect(own.length, 12, reason: 'the notes must have published');

      remote.downloadCalls = 0;
      h.state.recordsFor = (since) => own;
      h.state.getCursor = own.last.serverSeq;
      await h.engine.triggerPull();
      await pumpEventQueue();

      expect(
        remote.downloadCalls,
        0,
        reason: 'our own records name blobs whose bytes are already on disk',
      );
      for (var i = 0; i < 12; i++) {
        expect(
          h.io.files.containsKey('$_vaultPath/note$i.md'),
          isTrue,
          reason: 'and nothing may be lost by not fetching them',
        );
      }
    });

    test('a pull samples its per-file lines instead of one per file', () async {
      // The scan learned this the hard way and the pull did not. One report
      // came back 98% a single INFO line, and two other faults in it could not
      // be diagnosed at all because the segment holding them had been evicted.
      // A pull of 9000 files writes two lines each — applying, then the disk
      // write — which is the same accident with a different message.
      final captured = <String>[];
      final remote = _MemRemote();
      final a = await _Harness.create(sharedRemote: remote);
      addTearDown(a.dispose);
      for (var i = 0; i < 120; i++) {
        a.io.files['$_vaultPath/note$i.md'] = Uint8List.fromList(
          utf8.encode('note number $i\n'),
        );
      }
      await a.engine.start();
      final records = _recordsFromPuts(a.state);
      expect(records.length, 120);

      final b = await _Harness.create(
        sharedRemote: remote,
        captureLog: captured,
      );
      addTearDown(b.dispose);
      b.state.recordsFor = (since) => since == 0 ? records : const [];
      b.state.getCursor = records.last.serverSeq;
      await b.engine.start();

      expect(
        captured.where((l) => l.startsWith('Pull: applying file')).length,
        lessThanOrEqualTo(20),
        reason: '120 files must not produce 120 applying lines',
      );
      expect(
        captured.where((l) => l.startsWith('disk write')).length,
        lessThanOrEqualTo(20),
        reason: 'nor 120 disk-write lines',
      );
      expect(
        captured.where((l) => l.contains('line(s) withheld')),
        isNotEmpty,
        reason:
            'a sample that does not say it is a sample reads as the '
            'whole run, which is worse than the flood',
      );
      // The files themselves must still all arrive — this is about the log,
      // not about doing less work.
      for (var i = 0; i < 120; i++) {
        expect(b.io.files.containsKey('$_vaultPath/note$i.md'), isTrue);
      }
    });

    test('a pull sweeps the cache it just filled, without waiting for the '
        'next session', () async {
      // Prefetch stages every downloaded chunk in the cache — that is how it
      // hands bytes to apply. Once apply has written the file, the vault holds
      // those bytes and the staged copy is dead weight. The sweep used to be
      // scheduled once, at start, so everything pulled today stayed duplicated
      // in the database until tomorrow; on a first full sync that is the whole
      // vault.
      final remote = _MemRemote();

      final a = await _Harness.create(sharedRemote: remote);
      addTearDown(a.dispose);
      a.io.files['$_vaultPath/att/photo.bin'] = Uint8List.fromList(
        List.generate(4096, (i) => (i * 37) % 256),
      );
      await a.engine.start();
      final records = _recordsFromPuts(a.state);
      expect(records, isNotEmpty, reason: 'A must publish the attachment');

      // B starts with nothing to pull, so the sweep start() schedules runs and
      // finds an empty cache. Anything below is therefore the PULL's doing —
      // the startup sweep has already had its turn and will not come again
      // this session, which is exactly the gap being closed.
      final b = await _Harness.create(sharedRemote: remote);
      addTearDown(b.dispose);
      b.state.recordsFor = (_) => const [];
      await b.engine.start();
      for (var i = 0; i < 20; i++) {
        await pumpEventQueue();
      }

      // Now the attachment shows up on a later pull.
      b.state.recordsFor = (since) => since == 0 ? records : const [];
      b.state.getCursor = records.last.serverSeq;
      await b.engine.triggerPull();

      // The pull really did materialise it.
      expect(b.io.files.containsKey('$_vaultPath/att/photo.bin'), isTrue);

      // Nobody calls runLocalBlobGc here on purpose: the pull has to ask for
      // the sweep itself. Let the maintenance tier drain.
      for (var i = 0; i < 40; i++) {
        if ((await b.engine.blobStore.listBlobIds(vaultId: _vaultId)).isEmpty) {
          break;
        }
        await pumpEventQueue();
      }

      expect(
        await b.engine.blobStore.listBlobIds(vaultId: _vaultId),
        isEmpty,
        reason:
            'the pulled chunks are a second copy of a file now on disk, '
            'and the pull must not leave them for the next session',
      );
      expect(
        b.io.files['$_vaultPath/att/photo.bin'],
        a.io.files['$_vaultPath/att/photo.bin'],
        reason: 'and sweeping must not disturb the file it wrote',
      );
    });

    test("a text note's blob leaves the cache too — the FugueStore holds the "
        'tree it is made of', () async {
      // The cache used to keep every note's blob because disk holds only a
      // rendered projection of the tree. True, and beside the point: the tree
      // itself is in the FugueStore, in the very encoding the blob wraps, so
      // the cached copy was pure duplication.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.engine.start();

      final pushed = h.engine.events
          .firstWhere((e) => e is SyncFilePushed && e.path == 'note.md')
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/note.md'] = Uint8List.fromList(
        'hello notes'.codeUnits,
      );
      h.changes.emit(const FileCreatedEvent(relativePath: 'note.md'));
      await pushed;
      // Not "evicted by the next sweep" — never written. The sweep runs once
      // a session, so caching first would keep a second copy of everything
      // edited today until tomorrow.
      expect(
        await h.engine.blobStore.listBlobIds(vaultId: _vaultId),
        isEmpty,
        reason: 'the tree is already persisted; the blob is the same bytes',
      );

      await h.engine.runLocalBlobGc();

      expect(
        await h.engine.blobStore.listBlobIds(vaultId: _vaultId),
        isEmpty,
        reason: 'and a sweep finds nothing to do either',
      );
    });

    test("a note evicted from the cache is still healable — eviction and "
        'recovery agree on what the tree can rebuild', () async {
      // The two halves must hold together: the GC drops a blob because the
      // tree can rebuild it, so the recovery path had better actually rebuild
      // it. Testing them apart would let them drift into a cache that evicts
      // what nothing can bring back.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.engine.start();

      final pushed = h.engine.events
          .firstWhere((e) => e is SyncFilePushed && e.path == 'note.md')
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/note.md'] = Uint8List.fromList(
        utf8.encode('---\ntags: [a]\n---\n\nтекст заметки\n'),
      );
      h.changes.emit(const FileCreatedEvent(relativePath: 'note.md'));
      await pushed;
      final uploaded = h.remote.store.keys.toSet();

      await h.engine.runLocalBlobGc();
      expect(await h.engine.blobStore.listBlobIds(vaultId: _vaultId), isEmpty);

      // Now the server loses them, with no cached copy left anywhere.
      h.remote.store.clear();
      final verify = await h.engine.runVerifyBlobs();

      expect(verify.unhealable, 0);
      expect(
        h.remote.store.keys.toSet(),
        uploaded,
        reason:
            'the same ids must come back, or the GC evicted something '
            'the tree cannot actually reproduce',
      );
    });

    test('a text note whose blob the server lost is healed from its Fugue '
        'tree, frontmatter and all', () async {
      // Text used to be unhealable here: the recovery path only knew how to
      // re-chunk the file on disk, and a note's disk bytes are the rendered
      // projection, not the tree the blob holds. Rebuilding from the tree only
      // works if it reproduces the uploader's bytes EXACTLY — including the
      // frontmatter tail, which is appended after the tree and is the part
      // most likely to be forgotten.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.engine.start();

      final pushed = h.engine.events
          .firstWhere((e) => e is SyncFilePushed && e.path == 'note.md')
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/note.md'] = Uint8List.fromList(
        utf8.encode('---\ntags: [a, b]\ntitle: Заметка\n---\n\nтекст\n'),
      );
      h.changes.emit(const FileCreatedEvent(relativePath: 'note.md'));
      await pushed;

      final uploaded = h.remote.store.keys.toSet();
      expect(uploaded, isNotEmpty, reason: 'the note must have been uploaded');

      // The server silently loses every one of them, and the local cache is
      // gone too — so nothing but the tree can produce these bytes again.
      h.remote.store.clear();
      await h.engine.blobStore.wipeAll(vaultId: _vaultId);

      final verify = await h.engine.runVerifyBlobs();

      expect(
        verify.unhealable,
        0,
        reason: 'every lost blob of a text note must be recoverable',
      );
      expect(
        h.remote.store.keys.toSet(),
        uploaded,
        reason:
            'healed blobs must land under the SAME ids — anything else '
            'means the tree did not reproduce the uploaded bytes',
      );
    });

    test(
      'a file deleted while nothing was watching is reported, not deleted',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        await h.engine.start();

        final pushed = h.engine.events
            .firstWhere((e) => e is SyncFilePushed && e.path == 'note.bin')
            .timeout(const Duration(seconds: 10));
        h.io.files['$_vaultPath/note.bin'] = Uint8List.fromList([1, 2, 3]);
        h.changes.emit(const FileCreatedEvent(relativePath: 'note.bin'));
        await pushed;

        // Stop, delete behind its back, start again — Obsidian closed, or sync
        // paused. No watcher event is ever produced for this.
        await h.engine.stop();
        h.io.files.remove('$_vaultPath/note.bin');
        final putsBefore = h.state.puts.length;
        await h.engine.start();

        final reported = h.events.whereType<SyncFilesVanished>().toList();
        expect(
          reported,
          isNotEmpty,
          reason: 'the user has to learn the delete never propagated',
        );
        expect(reported.last.pathsByFileId.values, contains('note.bin'));
        expect(
          h.state.puts
              .skip(putsBefore)
              .expand((p) => p.items)
              .where((it) => it.tombstone),
          isEmpty,
          reason:
              'reporting is not deleting — an unmounted vault looks the '
              'same, so the engine must not decide this on its own',
        );
      },
    );

    test('confirming the report is what propagates the delete', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.engine.start();

      final pushed = h.engine.events
          .firstWhere((e) => e is SyncFilePushed && e.path == 'note.bin')
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/note.bin'] = Uint8List.fromList([1, 2, 3]);
      h.changes.emit(const FileCreatedEvent(relativePath: 'note.bin'));
      await pushed;

      await h.engine.stop();
      h.io.files.remove('$_vaultPath/note.bin');
      await h.engine.start();

      final reported = h.events
          .whereType<SyncFilesVanished>()
          .last
          .pathsByFileId;
      final n = await h.engine.confirmVanishedDeletes(reported.keys);

      expect(n, 1);
      final stats = h.engine.statsSnapshot()!;
      expect(
        stats.tombstones,
        1,
        reason:
            'the confirmed delete becomes a tombstone; getting it onto '
            'the wire is the pusher\'s job and is covered where deletes '
            'made with sync running are tested',
      );
    });

    test('a file that came back is not deleted on confirmation', () async {
      // The user approved a list they were shown; anything that changed since
      // is outside that approval.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.engine.start();

      final pushed = h.engine.events
          .firstWhere((e) => e is SyncFilePushed && e.path == 'note.bin')
          .timeout(const Duration(seconds: 10));
      h.io.files['$_vaultPath/note.bin'] = Uint8List.fromList([1, 2, 3]);
      h.changes.emit(const FileCreatedEvent(relativePath: 'note.bin'));
      await pushed;

      await h.engine.stop();
      h.io.files.remove('$_vaultPath/note.bin');
      await h.engine.start();
      final reported = h.events
          .whereType<SyncFilesVanished>()
          .last
          .pathsByFileId;

      // It reappears before the user answers.
      h.io.files['$_vaultPath/note.bin'] = Uint8List.fromList([1, 2, 3]);

      expect(await h.engine.confirmVanishedDeletes(reported.keys), 0);
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
      TaskCancelToken? handed;
      // Priority/gate/preemption semantics are covered by the scheduler unit
      // tests; here we just pin the public hook the plugin's settings sync
      // uses to share the engine's connection-fair lane — including that the
      // task is HANDED the cancel token. Discarding it is what let settings
      // sync keep writing through a pause, holding the shared data client
      // while the engine's own restart timed out waiting on it.
      await h.engine.scheduleBackground((token) async {
        handed = token;
        ran = true;
      });
      expect(ran, isTrue);
      expect(handed, isNotNull);
      expect(handed!.isCancelled, isFalse);
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
    List<String>? captureLog,
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
      logger: captureLog == null
          ? null
          : LogController(outputs: [_CapturingOutput(captureLog)]).scope('e'),
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

  /// If set, the FIRST getStates awaits this before responding — parks the
  /// engine inside its INITIAL PULL, which is where a real start spends most
  /// of its time and therefore where a second start is most likely to land on
  /// top of it.
  Completer<void>? getStatesGate;
  bool _getGateUsed = false;

  /// If set, the FIRST putStates awaits this before responding — lets a test
  /// pause the engine mid-startup (after StartupDiff) to inject an edit.
  Completer<void>? putStatesGate;
  bool _putGateUsed = false;

  /// When set, getStates throws this on its FIRST call only — models a
  /// transient startup-pull failure. Later calls (e.g. healthCheck) behave
  /// normally, so a test can observe whether the engine was left a zombie.
  Object? failFirstGetStatesWith;
  bool _firstGetStatesFailed = false;

  /// When set, putStates refuses every call after this many have succeeded —
  /// so a test can watch a multi-batch push stop part-way and check that what
  /// landed stayed landed.
  int? failPutsAfter;

  @override
  Future<StateGetResponse> getStates(
    StateGetRequest request, {
    RpcContext? context,
  }) async {
    getSince.add(request.sinceCursor);
    final gate = getStatesGate;
    if (gate != null && !_getGateUsed) {
      _getGateUsed = true;
      await gate.future;
    }
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
    final cap = failPutsAfter;
    if (cap != null && puts.length >= cap) {
      throw StateError('putStates refused');
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

  /// Parks `connect()` until completed, so a test can land a second start
  /// while the first is still waiting on its socket.
  Completer<void>? connectGate;

  @override
  Future<void> connect() async {
    connectCalled = true;
    final gate = connectGate;
    if (gate != null) await gate.future;
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
/// Collects log MESSAGES so a test can assert on their VOLUME — the thing
/// that made one real report unreadable and evicted two other faults from it.
class _CapturingOutput extends LogOutput {
  _CapturingOutput(this.lines);

  final List<String> lines;

  @override
  void write(LogRecord record) {
    if (record is LogEvent) lines.add(record.message);
  }
}

class _MemRemote implements IBlobStorage {
  final Map<String, Uint8List> store = {};

  /// Every blob id this device actually asked the server for. Lets a test
  /// assert that a filtered file cost no bandwidth, not merely that it was
  /// left off disk.
  final List<String> downloadedIds = [];

  /// How many download CALLS were made, as opposed to how many ids they
  /// carried. The wire contract takes a list, so these two numbers are the
  /// difference between one round trip and N — which on a latency-bound link
  /// is the whole cost of a pull.
  int downloadCalls = 0;

  /// Upload CALLS, as opposed to ids carried — the same distinction the
  /// download counter draws, on the other direction.
  int uploadCalls = 0;

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    RpcContext? context,
  }) async => {
    for (final id in blobIds)
      if (store.containsKey(id)) id,
  };

  /// Parks every upload from the Nth onwards, so a test can freeze a startup
  /// pass part-way and look at what has already been published.
  int? parkUploadsFrom;
  final Completer<void> uploadsParked = Completer<void>();
  Completer<void>? _uploadGate;

  @override
  Future<void> upload(
    List<(Uint8List, String)> blobs, {
    RpcContext? context,
  }) async {
    uploadCalls += 1;
    final from = parkUploadsFrom;
    if (from != null && uploadCalls >= from) {
      if (!uploadsParked.isCompleted) uploadsParked.complete();
      await (_uploadGate ??= Completer<void>()).future;
    }
    for (final (bytes, id) in blobs) {
      store[id] = bytes;
    }
  }

  void releaseUploads() {
    parkUploadsFrom = null;
    if (_uploadGate != null && !_uploadGate!.isCompleted) {
      _uploadGate!.complete();
    }
  }

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    downloadCalls += 1;
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
    // Derived from the CONTENT, because that is the property of a real
    // filesystem this fake has to have: writing a file moves its mtime.
    //
    // It used to return a constant, which was invisible while nothing trusted
    // the signature for binaries — and the moment the startup scan started
    // skipping them on mtime+size, an edit of the same length became
    // undetectable in tests and only in tests. Writes go straight into [files]
    // rather than through a method, so there is nowhere to stamp a clock.
    return FileStatInfo(
      mtimeMs: 1000 + (Object.hashAll(b) & 0xffffff),
      sizeBytes: b.length,
    );
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

void _repairPullsFirst() {
  group('repair', () {
    test('pulls before republishing, so a stale local copy cannot overwrite a '
        "peer's newer edit", () async {
      final remote = _MemRemote();

      // A publishes the note.
      final a = await _Harness.create(sharedRemote: remote);
      addTearDown(a.dispose);
      await a.engine.start();
      final pushedA = a.engine.events
          .firstWhere((e) => e is SyncFilePushed)
          .timeout(const Duration(seconds: 10));
      a.io.files['$_vaultPath/note.md'] = Uint8List.fromList(
        utf8.encode('---\ntitle: one\n---\n\nX\n'),
      );
      a.changes.emit(const FileCreatedEvent(relativePath: 'note.md'));
      await pushedA;
      final recordsA = _recordsFromPuts(a.state);

      // B adopts it, edits it, and publishes the newer version.
      final b = await _Harness.create(sharedRemote: remote);
      addTearDown(b.dispose);
      b.state.recordsFor = (since) => since == 0 ? recordsA : const [];
      b.state.getCursor = recordsA.last.serverSeq;
      await b.engine.start();
      final pushedB = b.engine.events
          .firstWhere((e) => e is SyncFilePushed)
          .timeout(const Duration(seconds: 10));
      b.io.files['$_vaultPath/note.md'] =
          // Deliberately a different LENGTH: _InMemoryIO reports a constant
          // mtime, so a same-length edit is invisible to the reconciler's stat
          // short-circuit and would never push.
          Uint8List.fromList(
            utf8.encode('---\ntitle: two\n---\n\nY the newer one\n'),
          );
      b.changes.emit(const FileModifiedEvent(relativePath: 'note.md'));
      await pushedB;
      final recordsB = _recordsFromPuts(b.state);
      expect(recordsB, isNotEmpty);

      // A never pulled: its disk still holds the old copy, and B's newer
      // record is sitting on the server unread.
      a.state.recordsFor = (since) => recordsB;
      a.state.getCursor = recordsB.last.serverSeq;
      expect(utf8.decode(a.io.files['$_vaultPath/note.md']!), contains('X'));

      // Repair reseeds from disk under a dominating HLC. Without a pull first
      // that republishes the stale copy over B's edit — not the resurrection
      // that discarding history inherently risks, just plain loss.
      await a.engine.triggerRepair();

      expect(
        utf8.decode(a.io.files['$_vaultPath/note.md']!),
        contains('Y'),
        reason: "repair must adopt the peer's newer version before rebuilding",
      );
    });
  });

  // -------------------------------------------------------------------------
  // Where a vault's blobs belong is a question with three answers, not two.
  //
  // "No BYO marker" used to mean both "the server said managed" and "we could
  // not ask", and the second was treated as the first. A user who had asked
  // for their own storage filled a gigabyte of ours because a config lookup
  // timed out and the engine guessed.
  // -------------------------------------------------------------------------
  group('storage backend resolution', () {
    test('a vault that has never been answered refuses to guess', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.engine.metaStorage = _UnreachableMeta();
      h.io.files['$_vaultPath/note.md'] = Uint8List.fromList(
        utf8.encode('hello\n'),
      );

      await h.engine.start();
      await pumpEventQueue();

      expect(
        h.events.whereType<SyncError>().map((e) => e.message).join(),
        contains('cannot determine where this vault stores its files'),
      );
      expect(
        h.remote.uploadCalls,
        0,
        reason: 'nothing may be uploaded until the destination is known',
      );
    });

    test('it asks more than once before concluding that', () async {
      // One timeout is not evidence. The retries are what make refusing
      // reasonable rather than brittle.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final meta = _UnreachableMeta();
      h.engine.metaStorage = meta;

      await h.engine.start();
      await pumpEventQueue();

      expect(meta.calls, greaterThan(1));
    });

    test(
      'a definite answer is remembered, and survives the outage after it',
      () async {
        // The server saying "no external storage" is a FACT, and recording it is
        // what lets a later outage fall back on something other than a guess.
        final h = await _Harness.create();
        addTearDown(h.dispose);
        h.engine.metaStorage = _EmptyMeta();
        await h.engine.start();
        await pumpEventQueue();
        expect(h.events.whereType<SyncError>(), isEmpty);

        // Now the account service goes away.
        await h.engine.stop();
        h.events.clear();
        h.engine.metaStorage = _UnreachableMeta();
        await h.engine.start();
        await pumpEventQueue();

        expect(
          h.events.whereType<SyncError>().map((e) => e.message).join(),
          isNot(contains('cannot determine')),
          reason: 'an answered vault keeps working through an outage',
        );
      },
    );

    test('a vault marked BYO still refuses, answered or not', () async {
      // The pre-existing guard, which only ever covered the case where the
      // marker had already been stored locally.
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.engine.config = h.engine.config.copyWith(externalStorageKind: 's3');
      h.engine.metaStorage = _UnreachableMeta();

      await h.engine.start();
      await pumpEventQueue();

      expect(
        h.events.whereType<SyncError>().map((e) => e.message).join(),
        contains('refusing to sync to the managed backend'),
      );
    });
  });
}

/// The account service is unreachable — every ask throws.
class _UnreachableMeta implements IVaultMetaStorage {
  int calls = 0;

  @override
  Future<String?> getEncryptedMeta(String vaultId) async {
    calls++;
    throw StateError('unreachable');
  }

  @override
  Future<void> setEncryptedMeta(String vaultId, String encryptedMeta) async {}
}

/// The account service answers, and the answer is "no external storage".
class _EmptyMeta implements IVaultMetaStorage {
  @override
  Future<String?> getEncryptedMeta(String vaultId) async => null;

  @override
  Future<void> setEncryptedMeta(String vaultId, String encryptedMeta) async {}
}
