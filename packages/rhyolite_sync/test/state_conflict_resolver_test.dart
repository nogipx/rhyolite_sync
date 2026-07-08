import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/src/local/local_blob_store.dart';
import 'package:rhyolite_sync/src/sync_v3/file_state.dart';
import 'package:rhyolite_sync/src/sync_v3/file_state_store.dart';
import 'package:rhyolite_sync/src/sync_v3/state_conflict_resolver.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

const _v = 'vault-1';

Future<String> _writeBlob(LocalBlobStore blobs, String text) async {
  final bytes = Uint8List.fromList(utf8.encode(text));
  final ref = sha256.convert(bytes).toString();
  await blobs.write(bytes, ref, vaultId: _v);
  return ref;
}

FileState _state(
  String fileId, {
  String path = 'note.md',
  required String blobRef,
  required Hlc hlc,
  int size = 0,
  bool tombstone = false,
}) =>
    FileState(
      fileId: fileId,
      path: path,
      blobRef: blobRef,
      sizeBytes: size,
      hlc: hlc,
      tombstone: tombstone,
    );

void main() {
  late FileStateStore store;
  late LocalBlobStore blobStore;
  late StateConflictResolver resolver;

  setUp(() async {
    final env = await DataServiceFactory.inMemory();
    addTearDown(env.dispose);
    store = FileStateStore(client: env.client, vaultId: _v);
    await store.load();
    blobStore = LocalBlobStore(InMemoryBlobRepository());
    resolver = StateConflictResolver(
      store: store,
      blobStore: blobStore,
      vaultId: _v,
      nodeId: 'A',
    );
  });

  group('StateConflictResolver — trivial', () {
    test('single value returns it unchanged', () async {
      final ref = await _writeBlob(blobStore, 'hello');
      final v = _state('f1', blobRef: ref, hlc: Hlc(100, 0, 'A'));
      final outcome = await resolver.resolve([v]);
      expect(outcome, isA<StateMergeMerged>());
      expect((outcome as StateMergeMerged).merged.blobRef, ref);
    });

    test('identical blobRefs collapse to max-HLC', () async {
      final ref = await _writeBlob(blobStore, 'hello');
      final a = _state('f1', blobRef: ref, hlc: Hlc(100, 0, 'A'));
      final b = _state('f1', blobRef: ref, hlc: Hlc(200, 0, 'B'));

      final outcome = await resolver.resolve([a, b]);
      expect(outcome, isA<StateMergeMerged>());
      final merged = (outcome as StateMergeMerged).merged;
      expect(merged.blobRef, ref);
      expect(merged.hlc, Hlc(200, 0, 'B'));
    });

    test('tombstone vs edit → edit wins, tombstone becomes conflict-copy',
        () async {
      final ref = await _writeBlob(blobStore, 'still here');
      final edit = _state('f1', blobRef: ref, hlc: Hlc(100, 0, 'A'));
      final tomb = _state(
        'f1',
        blobRef: '',
        hlc: Hlc(200, 0, 'B'),
        tombstone: true,
      );

      final outcome = await resolver.resolve([edit, tomb]);
      expect(outcome, isA<StateMergeConflictCopy>());
      final c = outcome as StateMergeConflictCopy;
      expect(c.winner.tombstone, isFalse);
      expect(c.loser.tombstone, isTrue);
    });
  });

  group('StateConflictResolver — N>2 preserves every value (L1-5)', () {
    test('three concurrent divergent values -> all preserved, none dropped',
        () async {
      final refA = await _writeBlob(blobStore, 'content A');
      final refB = await _writeBlob(blobStore, 'content B');
      final refC = await _writeBlob(blobStore, 'content C');
      final a = _state('f1', blobRef: refA, hlc: Hlc(100, 0, 'A'));
      final b = _state('f1', blobRef: refB, hlc: Hlc(200, 0, 'B'));
      final c = _state('f1', blobRef: refC, hlc: Hlc(300, 0, 'C'));

      // No baseRef -> no 3-way merge; every pair is a genuine conflict.
      final outcome = await resolver.resolve([a, b, c]);

      expect(outcome, isA<StateMergeMultiConflict>(),
          reason: 'N>2 conflict must not collapse to one copy and drop the '
              'rest of the divergent versions');
      final m = outcome as StateMergeMultiConflict;
      expect(m.winner.blobRef, refC, reason: 'canonical winner is max-HLC');
      final preserved = m.parts
          .whereType<StateMergeConflictCopy>()
          .map((p) => p.loser.blobRef)
          .toSet();
      expect(preserved, containsAll(<String>{refA, refB}),
          reason: 'both non-winning versions must be retained as conflict '
              'copies, not silently dropped');
    });
  });

  group('StateConflictResolver — 3-way text merge', () {
    test('non-overlapping edits merge cleanly', () async {
      final baseRef = await _writeBlob(blobStore, 'line A\nline B\nline C\n');
      final localRef =
          await _writeBlob(blobStore, 'line A modified\nline B\nline C\n');
      final remoteRef =
          await _writeBlob(blobStore, 'line A\nline B\nline C modified\n');

      final local = _state('f1', blobRef: localRef, hlc: Hlc(100, 0, 'A'));
      final remote = _state('f1', blobRef: remoteRef, hlc: Hlc(150, 0, 'B'));

      final outcome = await resolver.resolve([local, remote], baseRef: baseRef);
      expect(outcome, isA<StateMergeMerged>());
      final m = outcome as StateMergeMerged;
      expect(m.newBlobBytes, isNotNull);
      final text = utf8.decode(m.newBlobBytes!);
      expect(text.contains('line A modified'), isTrue);
      expect(text.contains('line C modified'), isTrue);
    });

    test('falls back to conflict-copy when base blob missing', () async {
      final localRef = await _writeBlob(blobStore, 'local content');
      final remoteRef = await _writeBlob(blobStore, 'remote content');

      final local = _state('f1', blobRef: localRef, hlc: Hlc(100, 0, 'A'));
      final remote = _state('f1', blobRef: remoteRef, hlc: Hlc(200, 0, 'B'));

      final outcome = await resolver.resolve([local, remote]);
      expect(outcome, isA<StateMergeConflictCopy>());
      final c = outcome as StateMergeConflictCopy;
      expect(c.winner.blobRef, remoteRef);
      expect(c.loser.blobRef, localRef);
    });

    test('binary content falls back to conflict-copy not 3-way merge',
        () async {
      final baseBytes = Uint8List.fromList([1, 2, 0, 3]);
      final baseRef = sha256.convert(baseBytes).toString();
      await blobStore.write(baseBytes, baseRef, vaultId: _v);

      final localBytes = Uint8List.fromList([1, 2, 0, 9]);
      final localRef = sha256.convert(localBytes).toString();
      await blobStore.write(localBytes, localRef, vaultId: _v);

      final remoteBytes = Uint8List.fromList([1, 2, 0, 5]);
      final remoteRef = sha256.convert(remoteBytes).toString();
      await blobStore.write(remoteBytes, remoteRef, vaultId: _v);

      final local = _state('f1', blobRef: localRef, hlc: Hlc(100, 0, 'A'));
      final remote = _state('f1', blobRef: remoteRef, hlc: Hlc(200, 0, 'B'));

      final outcome = await resolver.resolve([local, remote], baseRef: baseRef);
      expect(outcome, isA<StateMergeConflictCopy>());
    });
  });

  group('StateConflictResolver — history fallback for base', () {
    test('uses history-provided ancestor when no baseRef passed', () async {
      final baseRef = await _writeBlob(blobStore, 'line A\nline B\n');
      final localRef =
          await _writeBlob(blobStore, 'line A modified\nline B\n');
      final remoteRef =
          await _writeBlob(blobStore, 'line A\nline B modified\n');

      final r = StateConflictResolver(
        store: store,
        blobStore: blobStore,
        vaultId: _v,
        nodeId: 'A',
        findHistoryBaseRef: (fileId, beforeHlc) async {
          expect(fileId, 'f1');
          return baseRef;
        },
      );

      final local = _state('f1', blobRef: localRef, hlc: Hlc(100, 0, 'A'));
      final remote = _state('f1', blobRef: remoteRef, hlc: Hlc(150, 0, 'B'));

      final outcome = await r.resolve([local, remote]);
      expect(outcome, isA<StateMergeMerged>());
      final merged = (outcome as StateMergeMerged).newBlobBytes!;
      final text = utf8.decode(merged);
      expect(text.contains('line A modified'), isTrue);
      expect(text.contains('line B modified'), isTrue);
    });

    test('falls back to conflict-copy when history has no ancestor', () async {
      final localRef = await _writeBlob(blobStore, 'local only');
      final remoteRef = await _writeBlob(blobStore, 'remote only');
      final r = StateConflictResolver(
        store: store,
        blobStore: blobStore,
        vaultId: _v,
        nodeId: 'A',
        findHistoryBaseRef: (_, __) async => null,
      );
      final local = _state('f1', blobRef: localRef, hlc: Hlc(100, 0, 'A'));
      final remote = _state('f1', blobRef: remoteRef, hlc: Hlc(200, 0, 'B'));
      final outcome = await r.resolve([local, remote]);
      expect(outcome, isA<StateMergeConflictCopy>());
    });

    test('lastSyncedBlobRef takes precedence over history hook', () async {
      final localBaseRef = await _writeBlob(blobStore, 'local-known base\n');
      final localRef =
          await _writeBlob(blobStore, 'local-known base\nlocal addition\n');
      final remoteRef =
          await _writeBlob(blobStore, 'local-known base\nremote addition\n');
      store.recordSyncedBlobRef('f1', localBaseRef);

      var historyCalled = false;
      final r = StateConflictResolver(
        store: store,
        blobStore: blobStore,
        vaultId: _v,
        nodeId: 'A',
        findHistoryBaseRef: (_, __) async {
          historyCalled = true;
          return 'should-not-be-used';
        },
      );

      final local = _state('f1', blobRef: localRef, hlc: Hlc(100, 0, 'A'));
      final remote = _state('f1', blobRef: remoteRef, hlc: Hlc(150, 0, 'B'));
      final outcome = await r.resolve([local, remote]);
      expect(outcome, isA<StateMergeMerged>());
      expect(historyCalled, isFalse,
          reason: 'fast path must skip history when local base is present');
    });
  });

  group('StateConflictResolver — conflict-copy paths', () {
    test('appends "(conflict <stamp> from <node>)" before extension',
        () async {
      final localRef = await _writeBlob(blobStore, 'L');
      final remoteRef = await _writeBlob(blobStore, 'R');
      final local = _state(
        'f1',
        path: 'sub/note.md',
        blobRef: localRef,
        hlc: Hlc(200, 0, 'A'),
      );
      final remote = _state(
        'f1',
        path: 'sub/note.md',
        blobRef: remoteRef,
        hlc: Hlc(100, 0, 'B'),
      );
      final outcome = await resolver.resolve([local, remote]);
      final c = outcome as StateMergeConflictCopy;
      expect(c.suggestedCopyPath.startsWith('sub/note ('), isTrue);
      expect(c.suggestedCopyPath.endsWith('.md'), isTrue);
      expect(c.suggestedCopyPath.contains('from B'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Data-safety invariant tests (see memory:
  // sync_bugs_2026_06_conflict_copy_silent_loss)
  // ---------------------------------------------------------------------------
  //
  // When the resolver returns StateMergeConflictCopy, the engine writes the
  // loser's content to a `.conflict-...md` file IF and only if
  // `blobStore.read(loser.blobRef)` returns bytes. If the loser blob is not
  // in the local cache and no remote fetched it earlier in the pipeline,
  // the engine silently skips the write — and the loser's content is gone
  // forever.
  //
  // The resolver's ConflictCopy outcome is therefore a PROMISE: "the engine
  // can recover the loser's content from the configured blob storage right
  // now". The invariant tests below assert that promise.
  group('StateConflictResolver — data-safety invariants', () {
    test(
      'unreachable loser blob → WinnerOnlyLossy (not ConflictCopy)',
      () async {
        // Alice has the higher HLC → wins LWW. Bob is the loser and
        // his bytes are unreachable: not in cache, no remote configured.
        final localRef = await _writeBlob(
          blobStore,
          'alice line one\nalice line two\n',
        );
        final bobBlobRef = sha256
            .convert(utf8.encode('bob line one\nbob line two\n'))
            .toString();
        // Note: NOT writing Bob's bytes to blobStore.

        // Base exists locally → resolver attempts 3-way merge, fails on
        // Bob's missing blob, falls through to LWW.
        final baseRef = await _writeBlob(blobStore, 'shared base\n');
        store.recordSyncedBlobRef('f1', baseRef);

        final local = _state(
          'f1',
          blobRef: localRef,
          hlc: Hlc(200, 0, 'A'),
          size: 30,
        );
        final remote = _state(
          'f1',
          blobRef: bobBlobRef,
          hlc: Hlc(100, 0, 'B'),
          size: 30,
        );

        final outcome = await resolver.resolve([local, remote]);

        // The resolver must NOT lie via ConflictCopy: there is no way
        // for the engine to write Bob's content as a conflict-copy
        // file. Surface the loss explicitly instead.
        expect(outcome, isA<StateMergeWinnerOnlyLossy>());
        final l = outcome as StateMergeWinnerOnlyLossy;
        expect(l.winner.blobRef, localRef);
        expect(l.lostBlobRef, bobBlobRef);
        expect(l.lostNodeId, 'B');
      },
    );

    test(
      'unreachable loser blob, no base path → WinnerOnlyLossy',
      () async {
        // No lastSyncedBlobRef → resolver skips 3-way merge entirely
        // and goes straight to LWW; the recoverability check still
        // fires.
        final localRef = await _writeBlob(blobStore, 'alice content');
        final bobBlobRef =
            sha256.convert(utf8.encode('bob content')).toString();

        final local = _state(
          'f2',
          blobRef: localRef,
          hlc: Hlc(200, 0, 'A'),
        );
        final remote = _state(
          'f2',
          blobRef: bobBlobRef,
          hlc: Hlc(100, 0, 'B'),
        );

        final outcome = await resolver.resolve([local, remote]);
        expect(outcome, isA<StateMergeWinnerOnlyLossy>());
        final l = outcome as StateMergeWinnerOnlyLossy;
        expect(l.lostBlobRef, bobBlobRef);
      },
    );

    test(
      'ConflictCopy is returned when loser bytes ARE cached',
      () async {
        // Positive case: when the loser's blob is in the local cache,
        // ConflictCopy is correct and its recoverability promise holds.
        final aliceRef = await _writeBlob(blobStore, 'alice content');
        final bobRef = await _writeBlob(blobStore, 'bob content');

        final local = _state(
          'f3',
          blobRef: aliceRef,
          hlc: Hlc(200, 0, 'A'),
        );
        final remote = _state(
          'f3',
          blobRef: bobRef,
          hlc: Hlc(100, 0, 'B'),
        );

        final outcome = await resolver.resolve([local, remote]);
        expect(outcome, isA<StateMergeConflictCopy>());
        final c = outcome as StateMergeConflictCopy;

        final loserBytes = await blobStore.read(
          c.loser.blobRef,
          vaultId: _v,
        );
        expect(loserBytes, isNotNull);
      },
    );

    test(
      'tombstone-vs-edit ConflictCopy: loser is the tombstone, '
      'no recoverability promise needed',
      () async {
        // This is the "expected silent" case: tombstone has no content,
        // so there is genuinely nothing to write.
        final localRef = await _writeBlob(blobStore, 'alice edits');
        final local = _state(
          'f3',
          blobRef: localRef,
          hlc: Hlc(200, 0, 'A'),
        );
        final tombstoned = _state(
          'f3',
          blobRef: '',
          hlc: Hlc(100, 0, 'B'),
          tombstone: true,
        );

        final outcome = await resolver.resolve([local, tombstoned]);
        expect(outcome, isA<StateMergeConflictCopy>());
        final c = outcome as StateMergeConflictCopy;

        // The loser here MUST be the tombstone — that is the
        // documented add-wins semantics.
        expect(c.loser.tombstone, isTrue);
        expect(c.loser.blobRef, isEmpty);
        // We do NOT require recoverability in this case — the
        // tombstone genuinely has no content to write.
      },
    );
  });
}
