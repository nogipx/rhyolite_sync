import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The pull's transit area, and the ceiling that lives in it.
//
// The ceiling is here rather than in the batch planner because here is the
// first place the real sizes are known. A record carries a chunk list but not
// a size, so a batch can only be ESTIMATED in advance — and estimating a
// note's single chunk at the chunker's four-megabyte maximum made batches six
// files long and the pull five times slower, for no memory saved. It was
// visible from outside as files arriving one at a time.
// ---------------------------------------------------------------------------

Uint8List _bytes(int n) => Uint8List(n);

void main() {
  test('holds what it is given and reports it back', () {
    final s = BlobStaging(budgetBytes: 1024);
    expect(s.read('a'), isNull);
    s.write('a', _bytes(10));
    expect(s.read('a')!.length, 10);
    expect(s.bytes, 10);
    expect(s.count, 1);
  });

  test('rewriting a hash does not double-count it', () {
    // Content-addressed, so the same id is the same bytes — but a re-fetch is
    // ordinary, and a counter that grew each time would report a ceiling
    // reached that was never approached.
    final s = BlobStaging(budgetBytes: 1024);
    s.write('a', _bytes(100));
    s.write('a', _bytes(100));
    expect(s.bytes, 100);
    expect(s.count, 1);
  });

  test('is full at the budget, and says so before it is exceeded', () {
    final s = BlobStaging(budgetBytes: 100);
    s.write('a', _bytes(99));
    expect(s.isFull, isFalse);
    s.write('b', _bytes(1));
    expect(
      s.isFull,
      isTrue,
      reason: 'the prefetch checks this to decide whether to keep warming; a '
          'ceiling reported late is a ceiling already crossed',
    );
  });

  test('clearing releases everything', () {
    // Called once a batch is applied. Anything still held after that is a copy
    // of bytes already on disk, which is what this class exists to not have.
    final s = BlobStaging(budgetBytes: 1024);
    s.write('a', _bytes(500));
    s.clear();
    expect(s.bytes, 0);
    expect(s.count, 0);
    expect(s.isFull, isFalse);
    expect(s.read('a'), isNull);
  });
}
