import 'dart:convert';
import 'dart:typed_data';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_core/rhyolite_core.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_store.dart';
import 'package:test/test.dart';

/// Every path that turns a stored blob back into something a user reads.
///
/// A blob can now carry a frontmatter tail, and these paths were written when
/// it could not. None of them was changed for the tail — they go through
/// `materializeFileContent`, which sees an ordinary Fugue blob — so what these
/// tests pin is that the "no change needed" conclusion is actually true, on
/// each path, rather than assumed once and generalised.
int _wall = 20000;
Hlc at(String node) => Hlc(++_wall, 0, node);

FmState build(String region, {String node = 'device-a'}) =>
    applyDiskFrontmatter(
      FmMapState(entries: const {}, fmHlc: at(node), trailHlc: at(node)),
      parseFrontmatterRegion(region),
      at(node),
    );

Uint8List blobOf(String note, {FmState? fm}) {
  final blob = FugueStore.encodeBlob(FugueTextSync.seedFromText(note));
  return fm == null ? blob : appendFmTail(blob, fm);
}

void main() {
  const note = '---\ntitle: Note\ntags:\n  - work\n---\n\n# Note\n\nbody\n';

  group('reading a tailed blob back', () {
    test('history restore shows the note, not the serialisation', () {
      // state_sync_engine downloadContent -> materializeFileContent, shared by
      // the version viewer and the backup diff.
      final tailed = blobOf(note, fm: build('title: Note\ntags:\n  - work\n'));
      expect(
        utf8.decode(materializeFileContent(tailed, 'n.md', isTextPath: true)!),
        note,
      );
    });

    test('backup restore writes the note', () {
      // RestoreBackupUseCase takes downloadContent as a callback and the engine
      // wires materializeFileContent into it, so the same call is the whole
      // path. Pinned because the wiring is a closure, not a type.
      final tailed = blobOf(note, fm: build('title: Note\n'));
      expect(
        utf8.decode(materializeFileContent(tailed, 'n.md', isTextPath: true)!),
        note,
      );
    });

    test('a conflict copy of the loser is readable', () {
      // remote_applier materialises the losing side before writing it beside
      // the winner. A raw tail here would make the copy unopenable.
      final loser = blobOf('---\nx: 2\n---\nloser body\n', fm: build('x: 2\n'));
      expect(
        utf8.decode(materializeFileContent(loser, 'n.md', isTextPath: true)!),
        '---\nx: 2\n---\nloser body\n',
      );
    });

    test('a blob written before tails existed still reads', () {
      expect(
        utf8.decode(
          materializeFileContent(blobOf(note), 'n.md', isTextPath: true)!,
        ),
        note,
      );
    });

    test('a tail on a path now classified binary does not leak', () {
      // The .excalidraw.md case: synced as text, reclassified binary later.
      // The Fugue check is path-independent precisely so this still projects.
      final tailed = blobOf(note, fm: build('title: Note\n'));
      expect(
        utf8.decode(
          materializeFileContent(tailed, 'd.excalidraw.md', isTextPath: true)!,
        ),
        note,
      );
    });
  });

  group('the union view — divergent create', () {
    const a = '---\nx: 1\ntags:\n  - a\n---\n\nbody from A\n';
    const b = '---\nx: 2\ntags:\n  - b\n---\n\nbody from B\n';

    test('the line union alone reproduces the original defect', () {
      // Worth pinning as the reason the branch below exists. The fences are
      // lines too, so they collapse into ONE region — which then holds `x`
      // twice, the exact file this whole effort is about.
      final union = deterministicLineUnion([a, b]);
      expect('x:'.allMatches(union).length, 2);
      expect(
        splitFrontmatter(union).region,
        isNotNull,
        reason: 'one region, not two',
      );
    });

    test('joining the frontmatter gives a valid region and keeps the union '
        'of bodies', () {
      final union = deterministicLineUnion([a, b]);
      final joined = joinFm(
        build('x: 1\ntags:\n  - a\n'),
        build('x: 2\ntags:\n  - b\n', node: 'device-b'),
      );

      final view = renderNote(
        materializeFm(joined),
        splitFrontmatter(union).body,
      );

      expect('x:'.allMatches(view).length, 1, reason: 'one key');
      final tags =
          (materializeFm(joined) as FmMap).entries
                  .firstWhere((e) => e.key == 'tags')
                  .value
              as FmList;
      expect(
        tags.items,
        containsAll(['a', 'b']),
        reason: 'the list still merges',
      );
      // Nothing from either body is dropped — that is what this branch is for.
      expect(view, contains('body from A'));
      expect(view, contains('body from B'));
    });

    test('a partial view must NOT be rendered — it would drop the other side', () {
      // The mixed-version case, which is what a real vault looks like during a
      // rollout. Only one device carries state; the other's frontmatter edits
      // exist solely in its text, and the character join has already kept them.
      // Rendering from the one state we have would discard them — strictly
      // worse than the duplicate key, because that keeps both values.
      final union = deterministicLineUnion([a, b]);
      final onlyOurs = build('x: 1\ntags:\n  - a\n');

      // What the guard prevents:
      final wrong = renderNote(
        materializeFm(onlyOurs),
        splitFrontmatter(union).body,
      );
      expect(
        wrong,
        isNot(contains('x: 2')),
        reason: 'this is the loss the guard exists to prevent',
      );

      // What the guard leaves in place: the union, both values intact.
      expect(union, contains('x: 1'));
      expect(union, contains('x: 2'));
      expect(union, contains('- a'));
      expect(union, contains('- b'));
    });

    test('with no frontmatter state the view is the plain union', () {
      // A peer that predates the tail contributes none, and the branch must
      // fall back rather than invent an empty region.
      final union = deterministicLineUnion([a, b]);
      expect(union, contains('body from A'));
      expect(union, contains('body from B'));
    });
  });
}
