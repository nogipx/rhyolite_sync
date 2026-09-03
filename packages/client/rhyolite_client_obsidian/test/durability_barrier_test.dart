import 'package:rhyolite_client_obsidian/src/engine/durability_barrier.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Which events drain the write queue is a rule that has been wrong twice, in
// the same shape both times, and neither time was visible until someone closed
// the app at the wrong moment. So it is a function with a test rather than a
// condition inside a listener.
//
// The rule is BANK-TIME: the moment local state was written. Not finish-time
// (an event that fires once at the end of a long pass leaves the whole pass
// undrained) and not acknowledgement (the server accepting is not us writing,
// and the push that carries it is best-effort).
// ---------------------------------------------------------------------------

void main() {
  group('events that mean local state was just banked', () {
    test('a pull batch is a barrier', () {
      // The pull's regression: hooked to SyncCursorAdvanced alone, a whole
      // vault's pull wrote for minutes with nothing draining it.
      expect(isDurabilityBarrier(SyncPullBatchApplied(cursor: 42)), isTrue);
    });

    test('startup upload progress is a barrier', () {
      // The upload's regression: its only barrier was the periodic push, which
      // is the SERVER acknowledging. That push swallows its failures, so a
      // refusing server left rows banking with nothing draining them — the
      // exact case (rate limit, 9119 files) the banking was written for.
      expect(
        isDurabilityBarrier(
          SyncStartupBlobUploadProgress(completed: 10, total: 900),
        ),
        isTrue,
      );
    });

    test('an accepted push is a barrier', () {
      expect(isDurabilityBarrier(SyncFilePushed('notes/a.md')), isTrue);
    });

    test('the end of a pull and the end of a startup upload are barriers', () {
      // Real, but neither is sufficient alone: both fire once, at the end.
      expect(isDurabilityBarrier(SyncCursorAdvanced(cursor: 7, recordCount: 3)),
          isTrue);
      expect(
        isDurabilityBarrier(
          SyncStartupBlobUploadDone(totalUploaded: 9, elapsed: Duration.zero),
        ),
        isTrue,
      );
    });
  });

  group('events that only say the network moved', () {
    test('a byte-progress report is not a barrier', () {
      // These say bytes crossed a wire, which is not a claim that anything was
      // written. They also fire per progress callback; the caller debounces,
      // but a barrier that means nothing is worse than a frequent one.
      expect(
        isDurabilityBarrier(
          SyncBlobTransfer(
            path: 'a.bin',
            upload: false,
            sentBytes: 1,
            totalBytes: 2,
            done: false,
          ),
        ),
        isFalse,
      );
      expect(
        isDurabilityBarrier(
          SyncBlobDownloadProgress(completed: 1, total: 2),
        ),
        isFalse,
      );
    });

    test('lifecycle and display events are not barriers', () {
      expect(isDurabilityBarrier(SyncConnected()), isFalse);
      expect(isDurabilityBarrier(SyncBusy(busy: true)), isFalse);
      expect(isDurabilityBarrier(SyncPulling()), isFalse);
    });
  });
}
