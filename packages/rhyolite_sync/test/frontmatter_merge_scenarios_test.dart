import 'dart:io';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_codec.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_state.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_document.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_parser.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_render.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_split.dart';
import 'package:test/test.dart';

const _notePath = 'test/fixtures/frontmatter_heavy_note.md';

int _wall = 1000;
Hlc tickOn(String node) => Hlc(++_wall, 0, node);

Set<String> priorListKeys(FmState s) {
  if (s is! FmMapState) return const {};
  return {
    for (final e in s.entries.entries)
      if (e.value.value is FmListValue) e.key,
  };
}

Map<String, ScalarKind> priorKinds(FmState s) {
  if (s is! FmMapState) return const {};
  return {
    for (final e in s.entries.entries)
      if (e.value.value case final FmScalarValue v) e.key: v.kind,
  };
}

/// One ingest, exactly as DiskReconciler does it.
FmState ingest(FmState base, String note, String node) {
  final parts = splitFrontmatter(note);
  final doc = parts.region == null
      ? const FmMap([])
      : parseFrontmatterRegion(
          parts.region!,
          priorKinds: priorKinds(base),
          priorListKeys: priorListKeys(base),
        );
  return applyDiskFrontmatter(base, doc, tickOn(node));
}

String renderWith(FmState s, String body) => renderNote(materializeFm(s), body);

FmState fresh(String node) {
  final at = tickOn(node);
  return FmMapState(entries: const {}, fmHlc: at, trailHlc: at);
}

List<String> keysOf(FmState s) =>
    (materializeFm(s) as FmMap).entries.map((e) => e.key).toList();

List<String> listOf(FmState s, String key) {
  final e = (materializeFm(s) as FmMap).entries.firstWhere((e) => e.key == key);
  return (e.value as FmList).items;
}

void main() {
  final raw = normalizeNewlines(File(_notePath).readAsStringSync());
  final body = splitFrontmatter(raw).body;
  final region = splitFrontmatter(raw).region!;
  final fileKeys = (parseFrontmatterRegion(region) as FmMap).entries
      .map((e) => e.key)
      .toList();

  test('CBOR tail round-trips the state byte-identically', () {
    final s = ingest(fresh('A'), raw, 'A');
    final bytes = encodeFmState(s);
    final back = decodeFmState(bytes);
    expect(
      encodeFmState(back),
      bytes,
      reason: 'canonical encoding must be stable',
    );
    expect(renderWith(back, body), renderWith(s, body));
    print('fm tail size = ${bytes.length} bytes for a ${raw.length}-char note');
  });

  test('two devices, disjoint property edits, converge without damage', () {
    // Shared base: device A ingests, ships the state, B starts from it.
    final base = ingest(fresh('A'), raw, 'A');

    final aNote = raw.replaceFirst('status: 🟦', 'status: 🟩');
    final bNote = raw.replaceFirst(
      'stage: 0. Черновик',
      'stage: 1. Согласование',
    );

    final a = ingest(base, aNote, 'A');
    final b = ingest(base, bNote, 'B');

    final ab = joinFm(a, b);
    final ba = joinFm(b, a);
    expect(renderWith(ab, body), renderWith(ba, body), reason: 'commutative');

    final out = renderWith(ab, body);
    expect(keysOf(ab), fileKeys, reason: 'key order preserved');
    expect(out.contains('status: 🟩'), isTrue);
    expect(out.contains('stage: 1. Согласование'), isTrue);
    expect('---\n'.allMatches(out).length, 2, reason: 'exactly one fence pair');
  });

  test('two devices add different tags — both survive, no duplicate key', () {
    final base = ingest(fresh('A'), raw, 'A');
    final aNote = raw.replaceFirst(
      '  - category/work\n',
      '  - category/work\n  - context/office\n',
    );
    final bNote = raw.replaceFirst(
      '  - category/work\n',
      '  - category/work\n  - context/home\n',
    );
    final merged = joinFm(ingest(base, aNote, 'A'), ingest(base, bNote, 'B'));
    print('tags after merge: ${listOf(merged, 'tags')}');
    expect(listOf(merged, 'tags'), [
      'status/wip',
      'project/single',
      'priority/a',
      'category/work',
      'context/home',
      'context/office',
    ]);
  });

  test('a property inserted mid-region keeps its position', () {
    final base = ingest(fresh('A'), raw, 'A');
    // Obsidian inserts a new property wherever the user drops it.
    final edited = raw.replaceFirst('status: 🟦', 'owner: alex\nstatus: 🟦');
    final next = ingest(base, edited, 'A');
    final expected = [...fileKeys]..insert(fileKeys.indexOf('status'), 'owner');
    print('expected: $expected');
    print('actual:   ${keysOf(next)}');
    expect(keysOf(next), expected);
  });

  test('a list item inserted mid-list keeps its position', () {
    final base = ingest(fresh('A'), raw, 'A');
    final edited = raw.replaceFirst(
      '  - project/single\n',
      '  - project/single\n  - area/sales\n',
    );
    final next = ingest(base, edited, 'A');
    print('tags: ${listOf(next, 'tags')}');
    expect(listOf(next, 'tags'), [
      'status/wip',
      'project/single',
      'area/sales',
      'priority/a',
      'category/work',
    ]);
  });

  test('the same task checked off on two devices keeps both edits', () {
    final base = ingest(fresh('A'), raw, 'A');
    const open =
        '- [ ] #task/next_action #category/work уточнить сроки 📅 2026-09-08';
    final aNote = raw.replaceFirst(
      open,
      '$open ✅ 2026-08-21'.replaceFirst('- [ ]', '- [x]'),
    );
    final bNote = raw.replaceFirst(
      open,
      '$open ✅ 2026-08-22'.replaceFirst('- [ ]', '- [x]'),
    );
    final a = ingest(base, aNote, 'A');
    final b = ingest(base, bNote, 'B');
    final items = listOf(joinFm(a, b), 'tasks');

    // The contract this pins is NO LOSS, not de-duplication.
    //
    // A list item is identified by its own text. That is what makes two
    // devices adding `work` to `tags` converge on ONE entry instead of two —
    // the case that motivated the whole typed merge. The same rule makes
    // EDITING an item a delete plus an add, so when two devices edit the same
    // item concurrently there is no shared identity left to pick a winner by,
    // and both results are kept.
    //
    // Keeping both is the correct end of that trade: the alternative is
    // discarding one device's edit with nothing to recover it from. Collapsing
    // them would need stable per-item ids — a wire-format change that re-opens
    // the duplicate-tag bug. If that is ever taken on, this test is the one to
    // rewrite, deliberately.
    expect(
      items,
      containsAll([
        '- [x] #task/next_action #category/work уточнить сроки 📅 2026-09-08 ✅ 2026-08-21',
        '- [x] #task/next_action #category/work уточнить сроки 📅 2026-09-08 ✅ 2026-08-22',
      ]),
      reason: 'neither device may lose its edit',
    );
    expect(
      items.contains(open),
      isFalse,
      reason: 'the unedited original is superseded on both sides',
    );
    expect(items.length, 5, reason: 'the other three tasks are untouched');

    // And it is a join: order-independent, so both devices show the same list.
    expect(listOf(joinFm(b, a), 'tasks'), items, reason: 'commutative');
  });

  test(
    'Obsidian rewrites `aliases: []` as `aliases:` — does the kind hold?',
    () {
      final base = ingest(fresh('A'), raw, 'A');
      // What Obsidian's Properties UI emits for an empty list.
      final obsidianForm = raw.replaceFirst('aliases: []', 'aliases:');
      final next = ingest(base, obsidianForm, 'A');
      final entry = (materializeFm(next) as FmMap).entries.firstWhere(
        (e) => e.key == 'aliases',
      );
      print('after Obsidian rewrite, aliases is: ${entry.value}');
      print('rendered: ${renderEntry(entry).trim()}');
      expect(
        entry.value,
        const FmList([]),
        reason: 'an emptied list must not silently become a text property',
      );
    },
  );

  test('idempotent re-ingest of an unchanged file does not re-clock', () {
    final one = ingest(fresh('A'), raw, 'A');
    final two = ingest(one, raw, 'A');
    expect(
      encodeFmState(two),
      encodeFmState(one),
      reason: 'an unchanged file must not change the blob',
    );
  });
}
