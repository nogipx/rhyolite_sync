// Runs the frontmatter recogniser over real vaults and reports what it found.
//
// The corpus this needs cannot come from a developer's own vault — measured
// across three of them, 317 notes with frontmatter produced ZERO comments,
// nested mappings, multi-line scalars, anchors or non-mapping roots, so those
// paths are simply never exercised there. This exists to say so with numbers
// rather than to prove the parser correct.
//
//   fvm dart run tool/frontmatter_corpus_check.dart <vault> [vault...]
//
// Semantic stability is the property that must hold. Byte equality is a
// quality metric: it says how often a note is left formatted exactly as its
// author left it.

import 'dart:io';
import 'package:rhyolite_core/rhyolite_core.dart';

void main(List<String> roots) {
  var total = 0, withFm = 0, asMap = 0, asRaw = 0;
  var stable = 0, byteIdentical = 0;
  final unstable = <String>[];
  final rawPaths = <String>[];
  final opaqueKeys = <String>{};

  for (final root in roots) {
    for (final f in Directory(root).listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.md')) continue;
      if (f.path.contains('/.obsidian') || f.path.contains('/.trash')) continue;
      total++;
      final src = f.readAsStringSync();
      final s = splitFrontmatter(src);
      if (s.region == null) continue;
      withFm++;
      final fm = parseFrontmatterRegion(s.region!);
      if (fm is FmRaw) {
        asRaw++;
        rawPaths.add(f.path);
      } else {
        asMap++;
      }
      if (fm is FmMap) {
        for (final e in fm.entries) {
          if (e.value is FmOpaque) opaqueKeys.add(e.key);
        }
      }
      final projected = renderNote(fm, s.body);
      final s2 = splitFrontmatter(projected);
      final fm2 = s2.region == null
          ? const FmMap([])
          : parseFrontmatterRegion(s2.region!);
      if (fm2 == fm && s2.body == s.body) {
        stable++;
      } else {
        unstable.add(f.path);
      }
      if (projected == normalizeNewlines(src)) byteIdentical++;
    }
  }

  print('notes             $total');
  print('with frontmatter  $withFm');
  print('  parsed as map   $asMap');
  print('  parsed as raw   $asRaw');
  print('semantically stable $stable / $withFm');
  print('byte-identical      $byteIdentical / $withFm  (quality metric)');
  if (opaqueKeys.isNotEmpty)
    print('opaque keys: ${opaqueKeys.toList()..sort()}');
  for (final p in rawPaths.take(5)) print('  RAW: $p');
  for (final p in unstable.take(10)) print('  UNSTABLE: $p');
}
