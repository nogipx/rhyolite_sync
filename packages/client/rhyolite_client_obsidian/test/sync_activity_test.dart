import 'package:rhyolite_client_obsidian/src/engine/sync_activity.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The one answer both the status dot and the panel show.
//
// They used to derive it separately from overlapping but different facts — the
// panel counted open transfers, the dot did not — and disagreed on the same
// screen under the same moving file. The first fix compared the two rules with
// a regular expression over the source, which asserted vocabulary rather than
// behaviour and broke on the first rename. This is the rule itself, so there
// is nothing left for two components to disagree about.
// ---------------------------------------------------------------------------

SyncEngineEvent _transfer(String path, {required bool done}) =>
    SyncBlobTransfer(
      path: path,
      upload: true,
      sentBytes: done ? 1 : 0,
      totalBytes: 1,
      done: done,
    );

void main() {
  _transfersMustClose();
  test('nothing is happening until something says so', () {
    expect(SyncActivity().isWorking, isFalse);
  });

  test('the engine reporting busy is enough', () {
    final a = SyncActivity();
    expect(a.observe(SyncBusy(busy: true)), isTrue, reason: 'answer changed');
    expect(a.isWorking, isTrue);
    expect(a.observe(SyncBusy(busy: true)), isFalse, reason: 'no change');
    a.observe(SyncBusy(busy: false));
    expect(a.isWorking, isFalse);
  });

  test('an open transfer is enough on its own', () {
    // The reason this fact exists: `busy` goes quiet between phases while a
    // large file keeps moving, and a status derived from the gaps between
    // reports flickers.
    final a = SyncActivity();
    a.observe(_transfer('a.bin', done: false));
    expect(a.isWorking, isTrue);
    a.observe(SyncBusy(busy: false));
    expect(a.isWorking, isTrue, reason: 'the file is still moving');
    a.observe(_transfer('a.bin', done: true));
    expect(a.isWorking, isFalse);
  });

  test('transfers are counted, not flagged', () {
    final a = SyncActivity();
    a.observe(_transfer('a.bin', done: false));
    a.observe(_transfer('b.bin', done: false));
    a.observe(_transfer('a.bin', done: true));
    expect(a.isWorking, isTrue, reason: 'b.bin is still going');
    a.observe(_transfer('b.bin', done: true));
    expect(a.isWorking, isFalse);
  });

  test('settings sync counts, and is read rather than remembered', () {
    // Read, so a surface built after the transition still gets the truth. A
    // pushed flag left the panel saying "up to date" beside a dot that was
    // still showing settings work.
    var busy = false;
    final a = SyncActivity(settingsBusy: () => busy);
    expect(a.isWorking, isFalse);
    busy = true;
    expect(a.isWorking, isTrue, reason: 'no event was needed to learn this');
  });

  test('stopping drops what was in flight', () {
    // The entries would never be retired otherwise: the run that would have
    // retired them is the one that ended.
    final a = SyncActivity();
    a.observe(SyncBusy(busy: true));
    a.observe(_transfer('a.bin', done: false));
    a.observe(SyncStopped());
    expect(a.isWorking, isFalse);
    expect(a.hasOpenTransfers, isFalse);
  });

  test('losing the connection drops them too', () {
    final a = SyncActivity();
    a.observe(_transfer('a.bin', done: false));
    a.observe(SyncDisconnected());
    expect(a.isWorking, isFalse);
  });

  test('observe reports only real changes, so callers can repaint on true', () {
    final a = SyncActivity();
    expect(a.observe(_transfer('a.bin', done: false)), isTrue);
    expect(
      a.observe(_transfer('b.bin', done: false)),
      isFalse,
      reason: 'already working; a second file changes nothing to show',
    );
    expect(a.observe(_transfer('a.bin', done: true)), isFalse);
    expect(a.observe(_transfer('b.bin', done: true)), isTrue);
  });
}

// ---------------------------------------------------------------------------
// A transfer that opened must close, or the plugin never stops "syncing".
//
// The pull's prefetch reported every file with `done: false` and never sent a
// closing report, so each file above the narration threshold left an entry
// behind. isWorking is engineBusy || hasOpenTransfers || settingsBusy, so one
// leftover entry holds the status at "syncing" for a vault that finished
// minutes ago — seen after a pull that had logged `applied 966 record(s)`.
// ---------------------------------------------------------------------------
void _transfersMustClose() {
  group('a transfer that opened must close', () {
    test('an unclosed transfer holds the whole status at working', () {
      final a = SyncActivity();
      a.observe(
        SyncBlobTransfer(
          path: 'big.bin',
          upload: false,
          sentBytes: 1,
          totalBytes: 100,
          done: false,
        ),
      );
      expect(a.isWorking, isTrue);

      // The engine going quiet is not enough: the entry is what holds it.
      a.observe(SyncBusy(busy: false));
      expect(
        a.isWorking,
        isTrue,
        reason: 'this is the stuck state — nothing else can clear it',
      );

      a.observe(
        SyncBlobTransfer(
          path: 'big.bin',
          upload: false,
          sentBytes: 100,
          totalBytes: 100,
          done: true,
        ),
      );
      expect(a.isWorking, isFalse);
    });

    test('a closing report for a path never opened is harmless', () {
      // The batch-end sweep closes every path it named, including ones whose
      // transfer already reported done. Closing twice must not go negative or
      // resurrect anything.
      final a = SyncActivity();
      final close = SyncBlobTransfer(
        path: 'x.bin',
        upload: false,
        sentBytes: 0,
        totalBytes: 0,
        done: true,
      );
      a.observe(close);
      a.observe(close);
      expect(a.isWorking, isFalse);
    });
  });
}
