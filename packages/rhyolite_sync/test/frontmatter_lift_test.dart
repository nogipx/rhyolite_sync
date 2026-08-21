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

FmState lift(String note, Hlc at) {
  final region = splitFrontmatter(note).region;
  return liftFm(
    region == null ? const FmMap([]) : parseFrontmatterRegion(region),
    at,
  );
}

void main() {
  final raw = normalizeNewlines(File(_notePath).readAsStringSync());
  final body = splitFrontmatter(raw).body;

  group('liftFm — reading a state back out of a region that carried none', () {
    test('a lifted state renders back to the bytes it came from', () {
      final state = lift(raw, Hlc(1000, 0, 'A'));
      expect(renderNote(materializeFm(state), body), raw);
    });

    test('two devices lift the same blob to byte-identical states', () {
      // The convergence requirement: the lift runs independently on every
      // device that meets a tail-less blob, and they must agree on the bytes
      // or they push at each other forever.
      final at = Hlc(1000, 0, 'writer');
      expect(encodeFmState(lift(raw, at)), encodeFmState(lift(raw, at)));
    });

    test('the stamp is the version clock, so a lifted side does not win by '
        'merely lacking a tail', () {
      // Same region, two clocks. The newer stamp must take the value.
      final older = lift(
        raw.replaceFirst('stage: 0. Черновик', 'stage: OLD'),
        Hlc(1000, 0, 'A'),
      );
      final newer = lift(
        raw.replaceFirst('stage: 0. Черновик', 'stage: NEW'),
        Hlc(2000, 0, 'B'),
      );
      final merged = renderNote(materializeFm(joinFm(older, newer)), body);
      expect(merged.contains('stage: NEW'), isTrue);
      expect(merged.contains('stage: OLD'), isFalse);
      // …and the join is commutative, as a join must be.
      expect(renderNote(materializeFm(joinFm(newer, older)), body), merged);
    });

    test('a lifted side merges per-property against a carried state', () {
      // The whole point: the tail-less side contributes its OWN keys instead
      // of dropping the region to a character merge.
      final carried = liftFm(
        parseFrontmatterRegion(splitFrontmatter(raw).region!),
        Hlc(1000, 0, 'A'),
      );
      final lifted = lift(
        raw.replaceFirst('start: 2026-08-04', 'start: 2026-08-09'),
        Hlc(2000, 0, 'B'),
      );
      final out = renderNote(materializeFm(joinFm(carried, lifted)), body);
      expect(out.contains('start: 2026-08-09'), isTrue);
      expect(RegExp(r'^start:', multiLine: true).allMatches(out).length, 1,
          reason: 'exactly one start key — no duplicate, no blend');
      expect(out.contains('2026-08-0409'), isFalse);
      expect(out.contains('2026-08-0904'), isFalse);
    });

    test('a note with no frontmatter lifts to the join identity', () {
      const plain = '# Title\n\njust a body\n';
      final state = lift(plain, Hlc(1000, 0, 'A'));
      expect(fmStateIsWorthStoring(state), isFalse,
          reason: 'nothing to carry, so nothing is written to the blob');
      expect(renderNote(materializeFm(state), plain), plain);
    });

    test('a region we cannot model lifts to raw and is left to the text join',
        () {
      // Tabs in indentation — js-yaml errors, so the recogniser refuses.
      const note = '---\na:\n\t- x\n---\nbody\n';
      final state = lift(note, Hlc(1000, 0, 'A'));
      expect(state, isA<FmRawState>(),
          reason: 'the resolver skips the rewrite for this shape');
    });
  });

  group('an emptied list keeps its type (§6.5)', () {
    test('Obsidian rewriting `aliases: []` as `aliases:` stays a list', () {
      final doc = parseFrontmatterRegion(
        splitFrontmatter(raw.replaceFirst('aliases: []', 'aliases:')).region!,
        priorListKeys: const {'aliases'},
      ) as FmMap;
      final aliases = doc.entries.firstWhere((e) => e.key == 'aliases');
      expect(aliases.value, const FmList([]));
      expect(renderEntry(aliases), 'aliases: []\n');
    });

    test('without the prior type it is an empty string, as before', () {
      final doc = parseFrontmatterRegion('aliases:\n') as FmMap;
      expect(doc.entries.single.value, const FmScalar(ScalarKind.text, ''));
    });
  });
}
