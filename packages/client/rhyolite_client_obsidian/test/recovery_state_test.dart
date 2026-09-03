@TestOn('vm')
library;

import 'package:rhyolite_client_obsidian/src/engine/recovery_state.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The ladder's memory, driven by event sequences.
//
// These rules are all about ORDER — refused then pushed, ten failures then one
// that moved, a burst of rejections inside one cooldown. As seven assignments
// scattered through an event listener they could only be checked by reading
// them, which is how the "an attempt that moved is not a wasted attempt" rule
// came to be written twice and the storage-refused clear to be missing once.
// ---------------------------------------------------------------------------

final _t0 = DateTime.utc(2026, 9, 1, 12);

void main() {
  group('storage refusal', () {
    test('is sticky until something actually reaches the server', () {
      final r = RecoveryState();
      expect(r.storageRefused, isFalse);

      r.observe(SyncStorageRefused('nope'), _t0);
      expect(r.storageRefused, isTrue);

      // Every kind of activity except a successful push leaves it set. A 401 is
      // not a passing condition, and the engine goes on pulling and looking
      // healthy while every edit is dropped the same way.
      r.observe(SyncBusy(busy: true), _t0);
      r.observe(SyncConnected(), _t0);
      expect(
        r.storageRefused,
        isTrue,
        reason: 'reconnecting is not evidence the storage takes our writes',
      );

      r.observe(SyncFilePushed('note.md'), _t0);
      expect(
        r.storageRefused,
        isFalse,
        reason:
            'a file that reached the server is proof — including when the fix '
            'happened on the storage side and nothing here was touched',
      );
    });
  });

  group('self-heal budget', () {
    test('backs off, caps, and gives up after ten fruitless attempts', () {
      final r = RecoveryState();
      final delays = <int>[];
      while (!r.selfHealExhausted) {
        delays.add(r.selfHealDelay.inSeconds);
        r.beginSelfHealAttempt();
      }

      expect(delays.take(5), [5, 10, 20, 40, 60]);
      expect(delays.skip(5), everyElement(60), reason: 'the cap is a cap');
      expect(delays.length, RecoveryState.maxSelfHealAttempts);
    });

    test('an attempt that moved is not a wasted attempt', () {
      final r = RecoveryState();
      for (var i = 0; i < 9; i++) {
        r.beginSelfHealAttempt();
      }
      expect(r.selfHealExhausted, isFalse);

      // A pass that uploaded nothing does not buy anything back: the cap is
      // there for a server that is down, where ten identical failures are
      // enough to conclude.
      r.observe(SyncStartupBlobUploadProgress(completed: 0, total: 500), _t0);
      r.beginSelfHealAttempt();
      expect(r.selfHealExhausted, isTrue);

      // One that did banks the budget. A large first sync can legitimately
      // need more than ten passes, each leaving the next with less to do.
      r.observe(SyncStartupBlobUploadProgress(completed: 12, total: 500), _t0);
      expect(r.selfHealExhausted, isFalse);
      expect(r.selfHealAttempt, 0);
    });

    test('reconnecting resets the ladder and the rebind budget together', () {
      final r = RecoveryState()..beginSelfHealAttempt();
      r.claimRebind();

      expect(r.observe(SyncConnected(), _t0), RecoveryStep.connected);
      expect(r.online, isTrue);
      expect(r.selfHealAttempt, 0);
      expect(
        r.authRebindAttempts,
        0,
        reason:
            'authenticated traffic is flowing again, so the next auth incident '
            'gets a full budget',
      );

      expect(r.observe(SyncDisconnected(), _t0), RecoveryStep.disconnected);
      expect(r.online, isFalse);
    });
  });

  group('liveness', () {
    test('silence is measured from the last event of any kind', () {
      final r = RecoveryState();
      expect(
        r.quietFor(_t0),
        RecoveryState.neverSpoke,
        reason:
            'an engine that has never spoken must not read as one that just '
            'did — this is the input to "wait, it is alive"',
      );

      r.observe(SyncBusy(busy: true), _t0);
      expect(r.engineBusy, isTrue);
      expect(r.quietFor(_t0.add(const Duration(seconds: 30))).inSeconds, 30);

      r.observe(SyncBusy(busy: false), _t0.add(const Duration(seconds: 25)));
      expect(r.engineBusy, isFalse);
      expect(r.quietFor(_t0.add(const Duration(seconds: 30))).inSeconds, 5);
    });
  });

  group('auth debounce', () {
    test('one refresh per cooldown, one in flight', () {
      final r = RecoveryState();
      expect(r.claimAuthRefresh(_t0), isTrue);

      // The burst: every pending RPC failing at once.
      expect(r.claimAuthRefresh(_t0.add(const Duration(seconds: 1))), isFalse);
      expect(r.claimAuthRefresh(_t0.add(const Duration(seconds: 7))), isFalse);
      expect(r.claimAuthRefresh(_t0.add(const Duration(seconds: 9))), isTrue);

      r.authRefreshInFlight = true;
      expect(
        r.claimAuthRefresh(_t0.add(const Duration(minutes: 5))),
        isFalse,
        reason: 'a second refresh against a single-use token revokes the first',
      );
    });

    test('rebinds are bounded', () {
      final r = RecoveryState();
      for (var i = 0; i < RecoveryState.maxAuthRebinds; i++) {
        expect(r.rebindBudgetLeft, isTrue);
        expect(r.claimRebind(), isTrue);
      }
      expect(r.rebindBudgetLeft, isFalse);
      expect(
        r.claimRebind(),
        isFalse,
        reason:
            'a rebind that does not fix the rejection would otherwise restart '
            'the engine on every cooldown, forever',
      );
    });
  });
}
