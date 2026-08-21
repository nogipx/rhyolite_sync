/// Offline half of the frontmatter audit: our recogniser against a real vault.
///
/// The in-plugin audit compares us with Obsidian's own parser and needs
/// Obsidian running. This runs the part that does not: does every note in a
/// real vault survive model -> render byte-identically, and — the question this
/// release actually raises — does it survive the LIFT, which now runs on every
/// text conflict instead of only when a peer stayed quiet.
///
/// Aggregates only. Paths are printed for failures so they can be looked at;
/// note contents are not, beyond a short window around a divergence.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_state.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_document.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_parser.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_render.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_split.dart';

String window(String a, String b) {
  final n = min(a.length, b.length);
  var i = 0;
  while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  String cut(String s) => s
      .substring(max(0, i - 25), min(s.length, i + 35))
      .replaceAll('\n', '\\n');
  return 'at $i\n      want: ${cut(a)}\n      got:  ${cut(b)}';
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/fm_audit.dart <vault-path>');
    exit(2);
  }
  final root = args.first;

  var notes = 0;
  var withFm = 0;
  var asRaw = 0;
  var withOpaque = 0;
  var withComments = 0;
  var emptyRegion = 0;
  var renderFail = 0;
  var liftFail = 0;
  var unreadable = 0;
  final failByExt = <String, int>{};
  final rawPaths = <String>[];
  final opaquePaths = <String>[];
  final renderFails = <String>[];
  final liftFails = <String>[];
  final keyCount = <String, int>{};

  for (final e in Directory(root).listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.md')) continue;
    if (e.path.contains('/.obsidian/') ||
        e.path.contains('/.git/') ||
        e.path.contains('/node_modules/')) {
      continue;
    }
    notes++;
    String text;
    try {
      text = normalizeNewlines(utf8.decode(e.readAsBytesSync()));
    } catch (_) {
      unreadable++;
      continue;
    }
    final rel = e.path.substring(root.length + 1);
    final parts = splitFrontmatter(text);
    if (parts.region == null) continue;
    withFm++;
    if (parts.region!.trim().isEmpty) emptyRegion++;

    final doc = parseFrontmatterRegion(parts.region!);
    if (doc is FmRaw) {
      asRaw++;
      if (rawPaths.length < 12) rawPaths.add(rel);
    } else {
      final map = doc as FmMap;
      for (final entry in map.entries) {
        keyCount[entry.key] = (keyCount[entry.key] ?? 0) + 1;
      }
      if (map.entries.any((x) => x.value is FmOpaque)) {
        withOpaque++;
        if (opaquePaths.length < 12) opaquePaths.add(rel);
      }
      if (map.entries.any((x) => x.lead.isNotEmpty) || map.trail.isNotEmpty) {
        withComments++;
      }
    }

    // (1) model -> render, the property the shipped format already relies on.
    final rendered = renderNote(doc, parts.body);
    if (rendered != text) {
      renderFail++;
      final ext = rel.endsWith('.excalidraw.md')
          ? '.excalidraw.md'
          : rel.endsWith('.canvas.md')
              ? '.canvas.md'
              : '.md';
      failByExt[ext] = (failByExt[ext] ?? 0) + 1;
      if (renderFails.length < 6) {
        renderFails.add('$rel\n    ${window(text, rendered)}');
      }
      continue;
    }

    // (2) the NEW path: lift -> materialize -> render. This is what a merge
    // now does to a side that arrived without a tail, on every text conflict.
    final lifted = renderNote(
      materializeFm(liftFm(doc, Hlc(1000, 0, 'audit'))),
      parts.body,
    );
    if (lifted != text) {
      liftFail++;
      if (liftFails.length < 6) {
        liftFails.add('$rel\n    ${window(text, lifted)}');
      }
    }
  }

  final sortedKeys = keyCount.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  print('vault              $root');
  print('notes scanned      $notes  (unreadable: $unreadable)');
  print('with frontmatter   $withFm');
  print('  empty region     $emptyRegion');
  print('  parsed as RAW    $asRaw');
  print('  with OPAQUE      $withOpaque');
  print('  with comments    $withComments');
  print('distinct keys      ${keyCount.length}');
  print('');
  print('model -> render mismatches   $renderFail');
  print('lift  -> render mismatches   $liftFail');

  void dump(String label, List<String> xs) {
    if (xs.isEmpty) return;
    print('\n$label:');
    for (final x in xs) {
      print('  $x');
    }
  }

  dump('RAW fallbacks (first 12)', rawPaths);
  dump('OPAQUE values (first 12)', opaquePaths);
  dump('RENDER MISMATCHES', renderFails);
  dump('LIFT MISMATCHES', liftFails);
  print('\ntop keys: ${sortedKeys.take(12).map((e) => '${e.key}(${e.value})').join(', ')}');
}
