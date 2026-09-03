import 'package:rhyolite_sync/src/sync_v3/state_startup_diff.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// How long one upload waits on another.
//
// A group is uploaded as a unit and costs whatever its largest member costs.
// Bounding it by COUNT alone put a 54 MB video in with seven photos of 400 KB:
// the photos were up in seconds and then sat at 100% for minutes, and the
// progress panel showed twenty rows finished and three moving. The parallelism
// was real; the grouping was what made most of it look stuck.
// ---------------------------------------------------------------------------

const _kb = 1024;
const _mb = 1024 * 1024;

List<List<int>> _group(
  List<int> sizes, {
  int maxCount = 8,
  int maxBytes = 8 * _mb,
}) => groupUploadsBySize<int>(
  sizes,
  sizeOf: (s) => s,
  maxCount: maxCount,
  maxBytes: maxBytes,
);

void main() {
  test('a large file is never bundled with small ones', () {
    final groups = _group([54 * _mb, ...List.filled(7, 400 * _kb)]);

    final withLarge = groups.firstWhere((g) => g.any((s) => s >= 8 * _mb));
    expect(
      withLarge,
      hasLength(1),
      reason: 'the seven photos must not wait on the video',
    );
  });

  test('small files still share a group, which is what grouping is for', () {
    // Eight 100 KB files fit both bounds, so they cost one request-pair
    // instead of eight.
    final groups = _group(List.filled(8, 100 * _kb));
    expect(groups, hasLength(1));
  });

  test('the count bound still holds when the bytes are trivial', () {
    final groups = _group(List.filled(20, 1 * _kb));
    expect(groups.map((g) => g.length), everyElement(lessThanOrEqualTo(8)));
    expect(groups, hasLength(3)); // 8 + 8 + 4
  });

  test('the byte bound closes a group before the count does', () {
    // Four files of 3 MB: two fit in 8 MB, the third opens a new group.
    final groups = _group(List.filled(4, 3 * _mb));
    expect(groups.map((g) => g.length), [2, 2]);
    for (final g in groups) {
      expect(g.fold<int>(0, (a, b) => a + b), lessThanOrEqualTo(8 * _mb));
    }
  });

  test('smallest first, so the file count moves early', () {
    final groups = _group([9 * _mb, 300 * _kb, 20 * _mb, 200 * _kb]);
    expect(groups.first, [200 * _kb, 300 * _kb]);
    expect(groups.last, [20 * _mb]);
  });

  test('every file lands in exactly one group', () {
    final sizes = [
      54 * _mb,
      ...List.filled(7, 400 * _kb),
      9 * _mb,
      ...List.filled(11, 30 * _kb),
    ];
    final groups = _group(sizes);
    final flat = groups.expand((g) => g).toList()..sort();
    expect(flat, (List<int>.of(sizes)..sort()));
  });

  test('nothing in, nothing out', () {
    expect(_group(const []), isEmpty);
  });
}
