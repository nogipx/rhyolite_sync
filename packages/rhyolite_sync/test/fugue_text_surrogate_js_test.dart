@TestOn('vm || node')
library;

import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_text_sync.dart';
import 'package:test/test.dart';

/// The same round-trip the VM suite checks, run under dart2js.
///
/// The plugin ships compiled to JS, and this project has been bitten before by
/// a library that behaves one way on the VM and another on the web. Everything
/// here is about astral-plane characters — emoji are surrogate PAIRS in UTF-16,
/// JS strings are UTF-16, and `runes` has to bridge the two. A note whose
/// frontmatter breaks precisely at an emoji is exactly the shape that would
/// have.
///
/// No dart:io: the fixture is inline so this can run on a JS platform at all.
const _note = '''
---
tags:
  - status/wip
  - project/single
aliases: []
addition:
  - "[[Widget rollout - meetings|🗣️]]"
status: 🟦
priority: 🇦
category:
  - "[[work]]"
icon: ✏️
stage: 0. Черновик
tasks:
  - "- [x] #task/inbox собрать требования 📅 2026-07-07 ✅ 2026-07-07"
---

body 🟦 with emoji 🇦 in it
''';

/// Unpaired surrogates — characters that cannot render, and the visible symptom
/// in the report that prompted this.
List<int> loneSurrogates(String s) {
  final out = <int>[];
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final isHigh = c >= 0xD800 && c <= 0xDBFF;
    final isLow = c >= 0xDC00 && c <= 0xDFFF;
    if (isHigh) {
      if (i + 1 >= s.length ||
          s.codeUnitAt(i + 1) < 0xDC00 ||
          s.codeUnitAt(i + 1) > 0xDFFF) {
        out.add(i);
      } else {
        i++;
      }
    } else if (isLow) {
      out.add(i);
    }
  }
  return out;
}

Future<Fugue<String>> edit(Fugue<String> base, String text, String dev) async {
  final clock = LamportClock(dev);
  final tree = base.clone();
  clock.observeAll(tree.dots);
  return FugueTextSync.applyTextSnapshot(
    oldFugue: tree,
    newText: text,
    clock: clock,
  );
}

void main() {
  test('the note itself holds no unpaired surrogates', () {
    expect(loneSurrogates(_note), isEmpty);
  });

  test('seeding splits by rune, so no element is half a pair', () {
    final tree = FugueTextSync.seedFromText(_note);
    expect(tree.values.join(), _note);
    for (final v in tree.values) {
      expect(v.length <= 2, isTrue, reason: 'element "$v" is not one rune');
      if (v.length == 2) {
        // A two-unit element must be a COMPLETE pair.
        expect(loneSurrogates(v), isEmpty, reason: 'element "$v" is split');
      }
    }
  });

  test('an edit right after the emoji round-trips', () async {
    // `priority: 🇦` followed by `category:` is where the report says it breaks:
    // the newline between them vanished and a stray glyph appeared.
    final seeded = FugueTextSync.seedFromText(_note);
    final edited = _note.replaceFirst('priority: 🇦', 'priority: 🇧');
    final got = (await edit(seeded, edited, 'A')).values.join();
    expect(loneSurrogates(got), isEmpty);
    expect(got, edited);
  });

  test('an edit on the line after the emoji round-trips', () async {
    final seeded = FugueTextSync.seedFromText(_note);
    final edited = _note.replaceFirst('category:', 'categories:');
    final got = (await edit(seeded, edited, 'A')).values.join();
    expect(loneSurrogates(got), isEmpty);
    expect(got, edited);
  });

  test(
    'two devices editing around the emoji join without splitting it',
    () async {
      final seeded = FugueTextSync.seedFromText(_note);
      final a = await edit(
        seeded,
        _note.replaceFirst('status: 🟦', 'status: 🟩'),
        'A',
      );
      final b = await edit(
        seeded,
        _note.replaceFirst('stage: 0. Черновик', 'stage: 1. Согласование'),
        'B',
      );
      final merged = a.join(b).values.join();
      expect(
        loneSurrogates(merged),
        isEmpty,
        reason: 'a merge must never produce half a surrogate pair',
      );
      expect(merged.contains('status: 🟩'), isTrue);
      expect(merged.contains('stage: 1. Согласование'), isTrue);
      // And the line structure around the emoji must survive.
      expect(merged.contains('priority: 🇦\ncategory:'), isTrue);
    },
  );

  test('deleting the emoji removes exactly it', () async {
    final seeded = FugueTextSync.seedFromText(_note);
    final edited = _note.replaceFirst('priority: 🇦\n', 'priority:\n');
    final got = (await edit(seeded, edited, 'A')).values.join();
    expect(loneSurrogates(got), isEmpty);
    expect(got, edited);
  });
}
