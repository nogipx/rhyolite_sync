import 'dart:io';
import 'dart:math';

import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_text_sync.dart';
import 'package:test/test.dart';

const _notePath = 'test/fixtures/frontmatter_heavy_note.md';

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

/// Indices of unpaired surrogates — characters that cannot render.
List<int> loneSurrogates(String s) {
  final out = <int>[];
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final isHigh = c >= 0xD800 && c <= 0xDBFF;
    final isLow = c >= 0xDC00 && c <= 0xDFFF;
    if (isHigh) {
      if (i + 1 >= s.length) {
        out.add(i);
      } else {
        final n = s.codeUnitAt(i + 1);
        if (n < 0xDC00 || n > 0xDFFF) {
          out.add(i);
        } else {
          i++;
        }
      }
    } else if (isLow) {
      out.add(i);
    }
  }
  return out;
}

/// Every element the tree holds that is itself a lone surrogate.
int loneSurrogateElements(Fugue<String> t) {
  var n = 0;
  for (final v in t.values) {
    if (v.length == 1) {
      final c = v.codeUnitAt(0);
      if (c >= 0xD800 && c <= 0xDFFF) n++;
    }
  }
  return n;
}

void main() {
  final base = File(_notePath).readAsStringSync();

  test('a Fugue element must never be half a surrogate pair', () {
    final seeded = FugueTextSync.seedFromText(base);
    expect(loneSurrogateElements(seeded), 0,
        reason: 'seedFromText splits by runes, so this should hold');
  });

  test('edits adjacent to emoji keep the projection valid UTF-16', () async {
    final seeded = FugueTextSync.seedFromText(base);
    // Every emoji in the note, with an edit placed immediately around it.
    const emoji = ['🟦', '🇦', '✏️', '📅', '✅', '🗣️'];
    var failures = 0;
    for (final e in emoji) {
      final at = base.indexOf(e);
      if (at < 0) continue;
      for (final mutate in <String Function(String)>[
        (s) => s.replaceRange(at, at + e.length, 'X'),
        (s) => s.replaceRange(max(0, at - 3), at, 'YY'),
        (s) => s.replaceRange(at + e.length, at + e.length + 2, 'ZZZ'),
        (s) => s.replaceRange(max(0, at - 2), at + e.length + 2, 'Q'),
      ]) {
        final want = mutate(base);
        final tree = await edit(seeded, want, 'A');
        final got = tree.values.join();
        final lone = loneSurrogateElements(tree);
        if (got != want || lone > 0) {
          failures++;
          print('emoji $e: match=${got == want} loneElements=$lone');
        }
      }
    }
    expect(failures, 0);
  });

  test('fuzz: random code-unit-boundary edits, then a two-device join',
      () async {
    final seeded = FugueTextSync.seedFromText(base);
    final rnd = Random(20260821);
    var valid = 0;
    var badProjection = 0;
    var badJoin = 0;
    String? firstBad;
    for (var trial = 0; trial < 300; trial++) {
      // Cut at CODE UNIT offsets, not rune boundaries — this is what an
      // external tool (Templater, a linter) can hand us.
      final i = rnd.nextInt(base.length);
      final j = min(base.length, i + rnd.nextInt(12));
      final aText = base.replaceRange(i, j, 'A' * rnd.nextInt(4));
      final k = rnd.nextInt(base.length);
      final l = min(base.length, k + rnd.nextInt(12));
      final bText = base.replaceRange(k, l, 'B' * rnd.nextInt(4));

      // A real editor never hands us half a surrogate pair; only count the
      // cases where the INPUT is valid UTF-16, or we are testing the fuzzer.
      if (loneSurrogates(aText).isNotEmpty ||
          loneSurrogates(bText).isNotEmpty) continue;
      valid++;

      final ta = await edit(seeded, aText, 'device-A');
      final tb = await edit(seeded, bText, 'device-B');
      if (ta.values.join() != aText || tb.values.join() != bText) {
        badProjection++;
        continue;
      }
      final merged = ta.join(tb);
      final out = merged.values.join();
      final lone = loneSurrogates(out);
      if (lone.isNotEmpty) {
        badJoin++;
        firstBad ??= 'trial $trial: ${lone.length} lone surrogate(s)\n'
            '  around: ${out.substring(max(0, lone.first - 40), min(out.length, lone.first + 40))}';
      }
    }
    print('bad projections: $badProjection / $valid valid trials');
    print('joins producing lone surrogates: $badJoin / $valid valid trials');
    if (firstBad != null) print(firstBad);
    expect(badProjection, 0);
    expect(badJoin, 0);
  });
}
