@TestOn('vm || node')
library;

import 'dart:math';

import 'package:convergent/fugue.dart';
import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_text_sync.dart';
import 'package:test/test.dart';

/// `diff_match_patch` cuts on UTF-16 code units; the Fugue tree indexes runes.
/// Where those disagree, an edit lands one position off and half a surrogate
/// pair ends up stored. This is the guard on the two systems agreeing.

bool _isHigh(int u) => u >= 0xD800 && u <= 0xDBFF;
bool _isLow(int u) => u >= 0xDC00 && u <= 0xDFFF;

/// True when every boundary of every chunk falls on a rune boundary.
bool runeAligned(List<Diff> diffs) => diffs.every(
  (d) =>
      d.text.isEmpty ||
      (!_isHigh(d.text.codeUnitAt(d.text.length - 1)) &&
          !_isLow(d.text.codeUnitAt(0))),
);

String rebuild(List<Diff> diffs, int op) => diffs
    .where((d) => d.operation == DIFF_EQUAL || d.operation == op)
    .map((d) => d.text)
    .join();

List<int> loneSurrogates(String s) {
  final out = <int>[];
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (_isHigh(c)) {
      if (i + 1 >= s.length || !_isLow(s.codeUnitAt(i + 1))) {
        out.add(i);
      } else {
        i++;
      }
    } else if (_isLow(c)) {
      out.add(i);
    }
  }
  return out;
}

List<Diff> diffOf(String a, String b) {
  final d = diff(a, b, checklines: true, timeout: 1);
  cleanupSemantic(d);
  return d;
}

Future<String> applied(String from, String to) async {
  final tree = FugueTextSync.seedFromText(from);
  final clock = LamportClock('t');
  clock.observeAll(tree.dots);
  final next = await FugueTextSync.applyTextSnapshot(
    oldFugue: tree,
    newText: to,
    clock: clock,
  );
  return next.values.join();
}

void main() {
  // Two emoji from one 1024-point block share a high surrogate, which is what
  // makes their common prefix end mid-character. This is not exotic: 🟦/🟩 and
  // 🇦/🇧 are ordinary property values.
  const pairs = [
    ('priority: 🇦', 'priority: 🇧'),
    ('status: 🟦', 'status: 🟩'),
    ('a🟦b', 'a🟩b'),
    ('🇦', '🇧'),
    ('x 📅 y', 'x 📆 y'),
  ];

  group('the raw diff really does split pairs', () {
    for (final (a, b) in pairs) {
      test('$a -> $b', () {
        // Not an assertion about our code — a statement about the library we
        // build on. If this ever starts passing, the alignment pass is
        // redundant rather than wrong.
        expect(runeAligned(diffOf(a, b)), isFalse);
      });
    }
  });

  group('alignment repairs it without changing what the diff means', () {
    for (final (a, b) in pairs) {
      test('$a -> $b', () {
        final d = diffOf(a, b);
        alignDiffsToRunes(d);
        expect(runeAligned(d), isTrue, reason: 'boundaries still split a pair');
        expect(rebuild(d, DIFF_DELETE), a, reason: 'old text must reconstruct');
        expect(rebuild(d, DIFF_INSERT), b, reason: 'new text must reconstruct');
      });
    }
  });

  group('applied to the tree', () {
    for (final (a, b) in pairs) {
      test('$a -> $b projects to exactly the new text', () async {
        final got = await applied(a, b);
        expect(loneSurrogates(got), isEmpty);
        expect(got, b);
      });
    }
  });

  test('the emoji-adjacent newline survives — the reported symptom', () async {
    // `priority: <emoji>` then another key. The bug deleted the newline, so the
    // next line glued on and a broken glyph appeared where the emoji was.
    const before = 'priority: 🇦\ncategory:\n  - work\n';
    const after = 'priority: 🇧\ncategory:\n  - work\n';
    expect(await applied(before, after), after);
  });

  test(
    'fuzz: random edits over emoji-dense text keep both properties',
    () async {
      const alphabet = [
        '🟦',
        '🟩',
        '🇦',
        '🇧',
        '📅',
        '✅',
        '✏️',
        'a',
        'б',
        ' ',
        '\n',
      ];
      final rnd = Random(4242);
      var checked = 0;
      for (var trial = 0; trial < 250; trial++) {
        String make(int n) => List.generate(
          n,
          (_) => alphabet[rnd.nextInt(alphabet.length)],
        ).join();
        final a = make(20 + rnd.nextInt(40));
        final b = make(20 + rnd.nextInt(40));

        final d = diffOf(a, b);
        alignDiffsToRunes(d);
        expect(runeAligned(d), isTrue, reason: 'trial $trial');
        expect(rebuild(d, DIFF_DELETE), a, reason: 'trial $trial old');
        expect(rebuild(d, DIFF_INSERT), b, reason: 'trial $trial new');
        checked++;
      }
      expect(checked, 250);
    },
  );

  test('fuzz: the tree projects to the new text every time', () async {
    const alphabet = ['🟦', '🟩', '🇦', '🇧', '📅', 'a', ' ', '\n'];
    final rnd = Random(99);
    for (var trial = 0; trial < 60; trial++) {
      String make(int n) => List.generate(
        n,
        (_) => alphabet[rnd.nextInt(alphabet.length)],
      ).join();
      final a = make(15 + rnd.nextInt(20));
      final b = make(15 + rnd.nextInt(20));
      final got = await applied(a, b);
      expect(loneSurrogates(got), isEmpty, reason: 'trial $trial split a pair');
      expect(got, b, reason: 'trial $trial');
    }
  });
}
