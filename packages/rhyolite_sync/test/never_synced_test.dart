import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

void main() {
  test('a diagnostic report is never synced', () {
    expect(isNeverSynced('rhyolite-report-20260830-195822.rhyolite-log.gz'),
        isTrue);
  });

  test('the format may change without the rule lapsing behind it', () {
    // The previous rule listed whole suffixes and was tied to markdown. When a
    // compressed report was tried and dropped, the .gz form silently stopped
    // being covered — the leak this test exists to prevent.
    for (final name in [
      'r.rhyolite-log.gz',
      'r.rhyolite-log.md.gz',
      'r.rhyolite-log.zip',
      'r.rhyolite-log.txt',
      'r.rhyolite-log',
    ]) {
      expect(isNeverSynced(name), isTrue, reason: name);
    }
  });

  test('the rule survives capitalisation', () {
    // Obsidian will create `.MD` happily on a case-insensitive filesystem, and
    // a file that escaped the rule that way would upload silently.
    expect(isNeverSynced('Report.Rhyolite-Log.MD'), isTrue);
  });

  test('it applies wherever the file sits', () {
    expect(isNeverSynced('Archive/2026/x.rhyolite-log.md'), isTrue);
  });

  test('an ordinary note is untouched', () {
    expect(isNeverSynced('Notes/Daily.md'), isFalse);
    expect(isNeverSynced('rhyolite-report.md'), isFalse);
  });

  test('the suffix must be the ending, not merely present', () {
    // Otherwise a note *about* a report would stop syncing.
    expect(isNeverSynced('Notes/about .rhyolite-log.md files.md'), isFalse);
  });

  test('an empty path is not a match', () {
    expect(isNeverSynced(''), isFalse);
  });
}
