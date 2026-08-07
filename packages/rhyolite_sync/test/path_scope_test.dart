import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

void main() {
  group('PathScope.allows', () {
    test('an empty scope admits everything', () {
      final scope = PathScope();
      expect(scope.isUnrestricted, isTrue);
      expect(scope.allows('anything.md'), isTrue);
      expect(scope.allows('deep/nested/file.png'), isTrue);
    });

    test('include admits the folder itself and its descendants', () {
      final scope = PathScope(include: ['Work']);
      expect(scope.allows('Work'), isTrue);
      expect(scope.allows('Work/note.md'), isTrue);
      expect(scope.allows('Work/sub/deep/note.md'), isTrue);
    });

    test('include rejects everything outside it', () {
      final scope = PathScope(include: ['Work']);
      expect(scope.allows('Personal/note.md'), isFalse);
      expect(scope.allows('note.md'), isFalse);
    });

    test('a prefix that is not a whole segment does not match', () {
      final scope = PathScope(include: ['Work']);
      expect(scope.allows('Workbench/note.md'), isFalse);
      expect(scope.allows('Workbench'), isFalse);
    });

    test('a single file can be included', () {
      final scope = PathScope(include: ['Inbox/todo.md']);
      expect(scope.allows('Inbox/todo.md'), isTrue);
      expect(scope.allows('Inbox/other.md'), isFalse);
    });

    test('several include entries are a union', () {
      final scope = PathScope(include: ['Work', 'Personal/Journal']);
      expect(scope.allows('Work/a.md'), isTrue);
      expect(scope.allows('Personal/Journal/b.md'), isTrue);
      expect(scope.allows('Personal/Taxes/c.md'), isFalse);
    });

    test('exclude alone denies only its subtree', () {
      final scope = PathScope(exclude: ['Archive']);
      expect(scope.allows('Archive/old.md'), isFalse);
      expect(scope.allows('Notes/new.md'), isTrue);
    });

    test('exclude is applied after include', () {
      final scope = PathScope(include: ['Work'], exclude: ['Work/scratch']);
      expect(scope.allows('Work/plan.md'), isTrue);
      expect(scope.allows('Work/scratch/tmp.md'), isFalse);
      expect(scope.allows('Personal/x.md'), isFalse);
    });

    test('matching is case-insensitive', () {
      final scope = PathScope(include: ['work']);
      expect(scope.allows('Work/note.md'), isTrue);
      expect(scope.allows('WORK/note.md'), isTrue);
    });

    test('an NFD entry matches the NFC path the engine stores', () {
      // The same folder name typed two ways: composed U+0439 (what
      // normalizeVaultPath produces for every stored path) and decomposed
      // U+0438 U+0306 (what macOS hands back from the filesystem).
      const nfc = '\u0417\u0430\u043c\u0435\u0442\u043a\u0439';
      const nfd = '\u0417\u0430\u043c\u0435\u0442\u043a\u0438\u0306';
      expect(nfd == nfc, isFalse, reason: 'the fixture must really differ');
      final scope = PathScope(include: [nfd]);
      expect(scope.allows('$nfc/a.md'), isTrue);
    });
  });

  group('PathScope.normalizeEntry', () {
    test('strips surrounding and duplicate slashes', () {
      expect(PathScope.normalizeEntry('/Work/'), 'Work');
      expect(PathScope.normalizeEntry('Work//sub/'), 'Work/sub');
      expect(PathScope.normalizeEntry('  Work/sub  '), 'Work/sub');
    });

    test('folds backslashes to forward slashes', () {
      expect(PathScope.normalizeEntry(r'Work\sub'), 'Work/sub');
    });

    test('drops entries that carry no location', () {
      expect(PathScope.normalizeEntry(''), isNull);
      expect(PathScope.normalizeEntry('   '), isNull);
      expect(PathScope.normalizeEntry('/'), isNull);
      expect(PathScope.normalizeEntry('///'), isNull);
    });
  });

  group('PathScope.parse', () {
    test('splits on commas and newlines, dropping blanks', () {
      expect(
        PathScope.parse('Work, Personal/Journal\n\n /Inbox/ ,'),
        {'Work', 'Personal/Journal', 'Inbox'},
      );
    });

    test('a root-only entry does not silently defeat the allowlist', () {
      expect(PathScope.parse('/').isEmpty, isTrue);
    });
  });

  group('PathScope json', () {
    test('round-trips', () {
      final scope = PathScope(include: ['Work'], exclude: ['Work/scratch']);
      expect(PathScope.fromJson(scope.toJson()), scope);
    });

    test('a missing or malformed payload reads as the whole vault', () {
      expect(PathScope.fromJson(null).isUnrestricted, isTrue);
      expect(PathScope.fromJson('nonsense').isUnrestricted, isTrue);
      expect(
        PathScope.fromJson({'includePaths': 42}).isUnrestricted,
        isTrue,
      );
    });
  });
}
