import 'dart:async';

import 'package:rhyolite_client_obsidian/src/engine/server_rejections.dart';
import 'package:rhyolite_client_obsidian/src/engine/sync_status.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The one status both the panel and the status dot show.
//
// They folded the same four connection events and still disagreed, because
// they combined them differently: the panel kept connection as a flag and
// applied precedence when it rendered, while the dot was a state machine in
// which the last event won. With no network the panel said "not connected"
// and the dot a few centimetres below it was green.
//
// Testing the rule, not the two renderings of it — for the reason the
// SyncActivity tests give: comparing two implementations asserts vocabulary
// and can pass while both are wrong.
// ---------------------------------------------------------------------------

SyncStatusModel _connected() {
  final m = SyncStatusModel();
  m.observeForTest(SyncStarted());
  m.observeForTest(SyncConnected());
  return m;
}

void main() {
  _palette();
  _oneFold();
  group('connection outranks work', () {
    test('local work after a drop cannot repaint the vault as ready', () {
      // The reported bug, at the level that caused it. Losing the network does
      // not stop the engine: reconciles, sweeps and settings work carry on and
      // keep reporting. Every one of those reports used to resolve the dot to
      // its resting state, which is green.
      final m = _connected();
      m.observeForTest(SyncDisconnected());
      expect(m.kind, SyncStatusKind.offline);

      m.observeForTest(SyncBusy(busy: true));
      expect(
        m.kind,
        SyncStatusKind.offline,
        reason: 'busy with no server is still no server',
      );

      m.observeForTest(SyncBusy(busy: false));
      expect(
        m.kind,
        SyncStatusKind.offline,
        reason: 'and going quiet again does not connect anything',
      );
    });

    test('a finished transfer cannot repaint it either', () {
      // The other arms that resolved to the resting state. Same fault, five
      // more doors into it.
      for (final done in <SyncEngineEvent>[
        SyncFilePushed('a.md'),
        SyncFilePulled(fileId: 'f', nodeCount: 0, path: 'a.md'),
        SyncBlobDownloadDone(totalDownloaded: 1, elapsed: Duration.zero),
        SyncStartupBlobUploadDone(totalUploaded: 1, elapsed: Duration.zero),
        SyncRepairDone(repaired: 1, failed: 0, elapsed: Duration.zero),
      ]) {
        final m = _connected();
        m.observeForTest(SyncDisconnected());
        m.observeForTest(done);
        expect(
          m.kind,
          SyncStatusKind.offline,
          reason: '${done.runtimeType} must not imply a connection',
        );
      }
    });

    test('a phase never survives losing the connection', () {
      // Presentation must not be able to contradict the claim. A spinner over
      // an unreachable vault is the same lie in a different pixel.
      //
      // Busy first, because that is the order the engine sends: the whole pull
      // runs inside `_whileBusy`, so a phase only ever arrives inside a busy
      // scope. Asserting a phase without one tests a sequence that cannot
      // happen — which this test did, and it failed for that reason before
      // failing for a real one.
      final m = _connected();
      m.observeForTest(SyncBusy(busy: true));
      m.observeForTest(SyncPulling());
      expect(m.phase, SyncPhase.pulling);
      m.observeForTest(SyncDisconnected());
      expect(m.kind, SyncStatusKind.offline);
      expect(m.phase, SyncPhase.none);
    });

    test('a phase is shown for as long as the engine says it is working', () {
      // No grace period here, and none needed: every path that does work now
      // holds SyncBusy, including the push, which was the one that did not.
      // A timer in the UI guessing at how long work lasts is a guess standing
      // in for a fact the engine is supposed to state.
      final m = _connected();
      m.observeForTest(SyncBusy(busy: true));
      m.observeForTest(SyncFilePulled(fileId: 'f', nodeCount: 0, path: 'a.md'));
      expect(m.kind, SyncStatusKind.syncing);
      expect(m.phase, SyncPhase.pulling);

      m.observeForTest(SyncBusy(busy: false));
      expect(m.kind, SyncStatusKind.ready);
    });

    test('a phase cannot outlive the connection', () {
      final m = _connected();
      m.observeForTest(SyncBusy(busy: true));
      m.observeForTest(SyncPulling());
      m.observeForTest(SyncDisconnected());
      expect(m.kind, SyncStatusKind.offline);
      expect(m.phase, SyncPhase.none);
    });

    test('reconnecting restores the ordinary answers', () {
      final m = _connected();
      m.observeForTest(SyncDisconnected());
      m.observeForTest(SyncConnected());
      expect(m.kind, SyncStatusKind.ready);
      m.observeForTest(SyncBusy(busy: true));
      expect(m.kind, SyncStatusKind.syncing);
    });
  });

  group('the ordinary ladder', () {
    test('nothing has started', () {
      expect(SyncStatusModel().kind, SyncStatusKind.stopped);
    });

    test('started but not yet up', () {
      final m = SyncStatusModel();
      m.observeForTest(SyncStarted());
      expect(m.kind, SyncStatusKind.connecting);
    });

    test('connected and idle is the only green', () {
      expect(_connected().kind, SyncStatusKind.ready);
    });

    test('unsent local changes are not "up to date"', () {
      final m = _connected();
      m.observeForTest(SyncPending(hasPending: true));
      expect(m.kind, SyncStatusKind.pending);
      m.observeForTest(SyncPending(hasPending: false));
      expect(m.kind, SyncStatusKind.ready);
    });

    test('stopping is distinct from losing the connection', () {
      final m = _connected();
      m.observeForTest(SyncStopped());
      expect(m.kind, SyncStatusKind.stopped);
    });
  });

  group('what outranks the connection', () {
    test('paused is the user\'s decision and wins', () {
      var paused = false;
      final m = SyncStatusModel(paused: () => paused);
      m.observeForTest(SyncStarted());
      m.observeForTest(SyncConnected());
      expect(m.kind, SyncStatusKind.ready);
      paused = true;
      expect(m.kind, SyncStatusKind.paused);
    });

    test('a missing precondition outranks being offline', () {
      // Not merely disconnected: it was never able to run, and reconnecting
      // will not change that. Reported as the thing the user can act on.
      var blocked = true;
      final m = SyncStatusModel(blocked: () => blocked);
      m.observeForTest(SyncStarted());
      m.observeForTest(SyncDisconnected());
      expect(m.kind, SyncStatusKind.blocked);
      blocked = false;
      expect(m.kind, SyncStatusKind.offline);
    });

    test('host state is read live, not folded at construction', () {
      // The surfaces are built and rebuilt at arbitrary moments; one that
      // captured a flag would keep whatever it was born with.
      var paused = true;
      final m = SyncStatusModel(paused: () => paused);
      expect(m.kind, SyncStatusKind.paused);
      paused = false;
      expect(m.kind, SyncStatusKind.stopped);
    });

    test('an expired session outlives a reconnect', () {
      final m = _connected();
      m.observeForTest(SessionExpired('session ended'));
      expect(m.kind, SyncStatusKind.authExpired);
      m.observeForTest(SyncConnected());
      expect(
        m.kind,
        SyncStatusKind.authExpired,
        reason: 'a socket coming back does not renew a session',
      );
    });

    test('a transient error IS cleared by a live connection', () {
      final m = _connected();
      m.observeForTest(SyncError('timed out'));
      expect(m.kind, SyncStatusKind.error);
      m.observeForTest(SyncConnected());
      expect(m.kind, SyncStatusKind.ready);
    });

    test('and expires on its own if nothing else happens', () {
      // The engine stays connected and keeps retrying, so red must not sit
      // there forever. Both surfaces used to run their own timer for this —
      // six seconds in the panel, five in the dot — two answers to one
      // question, on the same screen, a second apart.
      var now = DateTime(2026);
      final m = SyncStatusModel(now: () => now);
      m.observeForTest(SyncStarted());
      m.observeForTest(SyncConnected());
      m.observeForTest(SyncError('timed out'));
      expect(m.kind, SyncStatusKind.error);

      now = now.add(SyncStatusModel.errorLinger - const Duration(seconds: 1));
      expect(m.kind, SyncStatusKind.error, reason: 'not yet');

      now = now.add(const Duration(seconds: 2));
      expect(m.kind, SyncStatusKind.ready);
    });

    test('an expiring error does not outrank a real one', () {
      // Auth arriving during the linger window must win, and keep winning
      // after it — the expiry belongs to the transient, not to the slot.
      var now = DateTime(2026);
      final m = SyncStatusModel(now: () => now);
      m.observeForTest(SyncStarted());
      m.observeForTest(SyncConnected());
      m.observeForTest(SyncError('timed out'));
      m.observeForTest(SessionExpired('session ended'));
      now = now.add(SyncStatusModel.errorLinger * 2);
      expect(m.kind, SyncStatusKind.authExpired);
    });
  });

  group('repaint economy', () {
    test('observe reports whether the answer moved', () {
      final m = _connected();
      expect(m.observeForTest(SyncPending(hasPending: true)), isTrue);
      expect(
        m.observeForTest(SyncPending(hasPending: true)),
        isFalse,
        reason: 'same answer, no repaint',
      );
    });

    test('progress changes repaint even when the status does not', () {
      final m = _connected();
      m.observeForTest(SyncBusy(busy: true));
      expect(
        m.observeForTest(
          SyncBlobDownloadProgress(completed: 1, total: 10),
        ),
        isTrue,
      );
      expect(
        m.observeForTest(
          SyncBlobDownloadProgress(completed: 2, total: 10),
        ),
        isTrue,
        reason: 'the bar has to move',
      );
    });
  });
}

// ---------------------------------------------------------------------------
// One palette.
//
// The colours used to be decided twice: a switch in the status dot and a block
// of CSS in the panel. They had drifted three ways — connecting was
// rgb(200,180,90) in one and rgb(180,180,180) in the other, paused was 150
// grey against 128, and a repair was purple in the dot and ordinary sync blue
// in the panel. Nobody did that on purpose.
//
// These assert the shape that makes it impossible, not the specific values: a
// test that restates the palette would go green while both surfaces were wrong
// together, which is the failure mode the SyncActivity tests already warn
// about.
// ---------------------------------------------------------------------------
void _palette() {
  group('one palette for both surfaces', () {
    test('every tone has a colour', () {
      for (final tone in SyncTone.values) {
        expect(
          syncToneColor[tone],
          isNotNull,
          reason: '$tone would paint the dot with a null and the panel with '
              'the default grey — two different wrongs',
        );
      }
    });

    test('every status maps to a tone that has one', () {
      for (final kind in SyncStatusKind.values) {
        for (final phase in SyncPhase.values) {
          for (final pending in [true, false]) {
            final tone = toneFor(kind, phase, hasPending: pending);
            expect(syncToneColor[tone], isNotNull, reason: '$kind/$phase');
          }
        }
      }
    });

    test('the panel stylesheet is generated from that same table', () {
      // The check that matters: the CSS the panel ships cannot name a colour
      // the dot does not paint, because it is not written by hand any more.
      final css = syncToneCss('.rh-panel');
      for (final e in syncToneColor.entries) {
        expect(css, contains(syncToneClass(e.key)));
        expect(css, contains(e.value));
      }
    });

    test('a repair is distinct from ordinary sync on BOTH surfaces', () {
      // It was purple on one and blue on the other. A repair rewrites files;
      // mistaking it for a pull is the one confusion here with consequences.
      final repairing = toneFor(
        SyncStatusKind.syncing,
        SyncPhase.repairing,
        hasPending: false,
      );
      final syncing = toneFor(
        SyncStatusKind.syncing,
        SyncPhase.pulling,
        hasPending: false,
      );
      expect(repairing, isNot(syncing));
      expect(syncToneColor[repairing], isNot(syncToneColor[syncing]));
      expect(syncToneCss('.rh-panel'), contains(syncToneClass(repairing)));
    });

    test('a phase cannot tint a status that is not syncing', () {
      // The same guarantee as the model's, at the paint layer: an offline dot
      // must not be able to come out repair-purple.
      for (final kind in SyncStatusKind.values) {
        if (kind == SyncStatusKind.syncing) continue;
        expect(
          toneFor(kind, SyncPhase.repairing, hasPending: false),
          isNot(SyncTone.repairing),
          reason: '$kind must not borrow a phase colour',
        );
      }
    });
  });
}

// ---------------------------------------------------------------------------
// One fold, everybody repaints.
//
// The first attempt at sharing had both surfaces holding their own
// subscription and both calling observe() on the one model. The panel
// subscribed first, so it folded first; the dot then folded the same event
// into a model that had already moved, was told nothing had changed, and did
// not repaint. It stopped updating altogether — a worse disagreement than the
// one being fixed, introduced while fixing it.
// ---------------------------------------------------------------------------
void _oneFold() {
  group('one fold, every listener repaints', () {
    test('both listeners hear a single event', () async {
      final events = StreamController<SyncEngineEvent>.broadcast();
      final m = SyncStatusModel()..bind(events.stream);
      addTearDown(m.dispose);
      var panel = 0;
      var dot = 0;
      m.addListener(() => panel++);
      m.addListener(() => dot++);

      events.add(SyncStarted());
      await Future<void>.delayed(Duration.zero);
      expect(m.kind, SyncStatusKind.connecting);
      expect(panel, 1);
      expect(
        dot,
        1,
        reason: 'the second surface is not allowed to be the stale one',
      );
    });

    test('a second owner is refused, not silently accepted', () {
      // The mistake that already happened, made loud. Two surfaces each
      // feeding the model produced no error at all — the loser was told
      // nothing had changed and stopped repainting.
      final a = StreamController<SyncEngineEvent>.broadcast();
      final b = StreamController<SyncEngineEvent>.broadcast();
      final m = SyncStatusModel()..bind(a.stream);
      addTearDown(m.dispose);
      expect(() => m.bind(b.stream), throwsStateError);
    });

    test('a listener that removes itself does not silence the rest', () {
      // A surface being disposed mid-notification is ordinary, not an error.
      final m = SyncStatusModel();
      addTearDown(m.dispose);
      var other = 0;
      late void Function() remove;
      remove = m.addListener(() => remove());
      m.addListener(() => other++);
      m.notifyListeners();
      expect(other, 1);
    });

    test('host state with no event behind it still reaches everyone', () {
      // Pausing, a resolved start block, settings work: read live by the
      // model, so nothing in the event stream announces them.
      var paused = false;
      final m = SyncStatusModel(paused: () => paused);
      addTearDown(m.dispose);
      var repaints = 0;
      m.addListener(() => repaints++);
      paused = true;
      m.notifyListeners();
      expect(m.kind, SyncStatusKind.paused);
      expect(repaints, 1);
    });
  });
}
