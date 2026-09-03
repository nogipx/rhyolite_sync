@TestOn('vm')
library;

import 'package:rhyolite_client_obsidian/src/engine/frontmatter_audit.dart';
import 'package:test/test.dart';

/// The comparison logic, tested without Obsidian.
///
/// `auditVault` is the thin part — it fetches paths and reads the cache. What
/// is worth testing is the judgement: which differences count as a
/// disagreement, and which are the recogniser working as designed.
Future<FrontmatterAuditResult> run(
  Map<String, ({String text, ObsidianFrontmatter? cache})> vault,
) => auditFrontmatter(
  paths: vault.keys.toList(),
  readFile: (p) async => vault[p]!.text,
  obsidianCache: (p) => vault[p]!.cache,
);

void main() {
  test('agreement produces no findings', () async {
    final r = await run({
      'a.md': (
        text: '---\ntitle: A\ntags:\n  - work\n---\n\nbody\n',
        cache: (hasRegion: true, keys: ['title', 'tags'], values: const {}),
      ),
      'b.md': (
        text: 'no frontmatter\n',
        cache: (hasRegion: false, keys: [], values: const {}),
      ),
    });

    expect(r.clean, isTrue, reason: r.summary());
    expect(r.notes, 2);
    expect(r.withFrontmatter, 1);
  });

  test('a boundary disagreement is reported and stops there', () async {
    // The one that matters most: if we disagree about whether a region exists,
    // nothing downstream means anything, so keys are not compared.
    final r = await run({
      'a.md': (
        text: 'intro\n---\nnot really frontmatter\n---\n',
        cache: (hasRegion: true, keys: ['x'], values: const {}),
      ),
    });

    expect(r.regionDisagreements, hasLength(1));
    expect(r.regionDisagreements.single, contains('a.md'));
    expect(r.keyDisagreements, isEmpty);
  });

  test('a key we missed is a disagreement', () async {
    final r = await run({
      'a.md': (
        text: '---\ntitle: A\n---\nbody\n',
        cache: (
          hasRegion: true,
          keys: ['title', 'invisible'],
          values: const {},
        ),
      ),
    });

    expect(r.keyDisagreements, hasLength(1));
    expect(r.keyDisagreements.single, contains('invisible'));
  });

  test(
    'falling back to raw is only a finding when Obsidian read properties',
    () async {
      // Raw is a lossless fallback, not a failure. It becomes interesting only
      // when the user IS being shown properties for a region we could not place.
      final quiet = await run({
        'a.md': (
          text: '---\n- not a mapping\n---\nbody\n',
          cache: (hasRegion: true, keys: [], values: const {}),
        ),
      });
      expect(quiet.asRaw, 1);
      expect(quiet.clean, isTrue, reason: quiet.summary());

      final loud = await run({
        'a.md': (
          text: '---\n- not a mapping\n---\nbody\n',
          cache: (hasRegion: true, keys: ['x'], values: const {}),
        ),
      });
      expect(loud.asRaw, 1);
      expect(loud.keyDisagreements, hasLength(1));
    },
  );

  test(
    'a type disagreement is caught — the failure key sets would miss',
    () async {
      // The reason this comparison exists. `007` is a number to js-yaml's core
      // schema, and if we read it as text the renderer quotes it and the file
      // starts meaning something else. Key sets are identical either way.
      final r = await run({
        'a.md': (
          text: '---\nid: 007\n---\nbody\n',
          cache: (hasRegion: true, keys: ['id'], values: {'id': 7}),
        ),
      });
      expect(r.keyDisagreements, isEmpty, reason: 'the key set agrees');
      expect(
        r.valueDisagreements,
        isEmpty,
        reason: 'and so does the value: we read 007 as the number seven',
      );

      final wrong = await run({
        'a.md': (
          text: '---\nid: "007"\n---\nbody\n',
          cache: (hasRegion: true, keys: ['id'], values: {'id': 7}),
        ),
      });
      expect(wrong.valueDisagreements, hasLength(1));
      expect(wrong.valueDisagreements.single, contains('number'));
    },
  );

  test('a list that differs is caught', () async {
    final r = await run({
      'a.md': (
        text: '---\ntags:\n  - a\n  - b\n---\nbody\n',
        cache: (
          hasRegion: true,
          keys: ['tags'],
          values: {
            'tags': ['a', 'c'],
          },
        ),
      ),
    });
    expect(r.valueDisagreements, hasLength(1));
    expect(r.valueDisagreements.single, contains('list differs'));
  });

  test('an opaque value is never a value disagreement', () async {
    // Declining to model something is the escape hatch working, not a
    // mismatch — Obsidian will have produced a map where we hold raw text.
    final r = await run({
      'a.md': (
        text: '---\nnested:\n  deep: 1\n---\nbody\n',
        cache: (hasRegion: true, keys: ['nested'], values: {'nested': null}),
      ),
    });
    expect(r.valueDisagreements, isEmpty, reason: r.summary());
  });

  test('escape hatches are counted, since a vault may exercise none', () async {
    // The reason the instrument exists: the developer's own vaults contain
    // zero of these, so the counts say whether a corpus is worth anything.
    final r = await run({
      'a.md': (
        text: '---\n# lead\nnested:\n  deep: 1\nplain: 2\n---\nbody\n',
        cache: (hasRegion: true, keys: ['nested', 'plain'], values: const {}),
      ),
    });

    expect(r.withOpaque, 1);
    expect(r.withComments, 1);
    expect(r.clean, isTrue, reason: r.summary());
  });

  test(
    'an unreadable file is skipped, not counted as a disagreement',
    () async {
      final r = await auditFrontmatter(
        paths: ['gone.md'],
        readFile: (_) async => throw StateError('deleted mid-scan'),
        obsidianCache: (_) => (hasRegion: true, keys: ['x'], values: const {}),
      );
      expect(r.clean, isTrue);
      expect(r.notes, 1);
    },
  );
}
