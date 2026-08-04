import 'package:rhyolite_sync/src/frontmatter/frontmatter_document.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_parser.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_render.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_split.dart';
import 'package:test/test.dart';

/// Parses a whole note the way ingest will: split, then model the region.
({FmDocument fm, String body}) model(String note) {
  final parts = splitFrontmatter(note);
  return (
    fm: parts.region == null
        ? const FmMap([])
        : parseFrontmatterRegion(parts.region!),
    body: parts.body,
  );
}

FmDocument region(String r, {Map<String, ScalarKind> priorKinds = const {}}) =>
    parseFrontmatterRegion(r, priorKinds: priorKinds);

FmEntry entryOf(FmDocument d, String key) =>
    (d as FmMap).entries.firstWhere((e) => e.key == key);

void main() {
  group('split — the region boundary must match Obsidian', () {
    test('the FIRST closing fence wins, so body rules stay safe', () {
      const note = '---\na: 1\n---\n\n# Title\n\n---\n\nmore\n';
      final s = splitFrontmatter(note);
      expect(s.region, 'a: 1\n');
      expect(s.body, '\n# Title\n\n---\n\nmore\n');
    });

    test('an unclosed opening fence is not a region at all', () {
      const note = '---\na: 1\n\nstill body\n';
      expect(splitFrontmatter(note).region, isNull);
      expect(splitFrontmatter(note).body, note);
    });

    test('a fence that does not start the file is not a region', () {
      const note = 'intro\n---\na: 1\n---\n';
      expect(splitFrontmatter(note).region, isNull);
    });

    test('CRLF and BOM are normalised before the fence test', () {
      final s = splitFrontmatter('\u{FEFF}---\r\na: 1\r\n---\r\nbody\r\n');
      expect(s.region, 'a: 1\n');
      expect(s.body, 'body\n');
    });

    test('an empty region is a region', () {
      expect(splitFrontmatter('---\n---\nbody').region, '');
    });
  });

  group('model — the subset', () {
    test('flat scalars and block lists are placed', () {
      final d = region('created: 2026-08-03\ntags:\n  - work\n  - home\n');
      expect((d as FmMap).entries.map((e) => e.key), ['created', 'tags']);
      expect(entryOf(d, 'created').value, const FmScalar(ScalarKind.date, '2026-08-03'));
      expect(entryOf(d, 'tags').value, const FmList(['work', 'home']));
    });

    test('a flow list is the same ListVal as the block form', () {
      expect(entryOf(region('tags: [work, home]\n'), 'tags').value,
          const FmList(['work', 'home']));
    });

    test('the six property types are told apart', () {
      final d = region(
        'a: hello\nb: 42\nc: 1.5\nd: true\ne: 2026-08-03\n'
        'f: 2026-08-03T06:14\n',
      );
      expect(entryOf(d, 'a').value, const FmScalar(ScalarKind.text, 'hello'));
      expect(entryOf(d, 'b').value, const FmScalar(ScalarKind.number, '42'));
      expect(entryOf(d, 'c').value, const FmScalar(ScalarKind.number, '1.5'));
      expect(entryOf(d, 'd').value, const FmScalar(ScalarKind.boolean, 'true'));
      expect(entryOf(d, 'e').value, const FmScalar(ScalarKind.date, '2026-08-03'));
      expect(entryOf(d, 'f').value,
          const FmScalar(ScalarKind.datetime, '2026-08-03T06:14'));
    });

    test('keys may be quoted, spaced, Cyrillic or hold a colon', () {
      final d = region('"my key": a\nкнига: б\n"a: b": c\n');
      expect((d as FmMap).entries.map((e) => e.key), ['my key', 'книга', 'a: b']);
    });

    test('an empty value keeps the kind it already had', () {
      final d = region('tags:\n', priorKinds: {'tags': ScalarKind.text});
      expect(entryOf(d, 'tags').value, const FmScalar(ScalarKind.text, ''));
    });
  });

  group('model — the escape hatches', () {
    test('a nested mapping becomes Opaque, the other keys stay placed', () {
      final d = region('a: 1\npublish:\n  status: draft\n  by: anna\nz: 2\n');
      expect(entryOf(d, 'publish').value, isA<FmOpaque>());
      expect(entryOf(d, 'a').value, const FmScalar(ScalarKind.number, '1'));
      expect(entryOf(d, 'z').value, const FmScalar(ScalarKind.number, '2'));
    });

    test('multi-line scalars, lists of mappings, anchors and tags are Opaque',
        () {
      for (final src in [
        'k: |\n  line one\n  line two\n',
        'k: >-\n  folded\n',
        'k:\n  - title: a\n    url: b\n',
        'k: &anchor value\n',
        'k: *alias\n',
        'k: !!str 5\n',
        'k: {a: 1}\n',
      ]) {
        expect(entryOf(region(src), 'k').value, isA<FmOpaque>(), reason: src);
      }
    });

    test('an inline comment makes the value Opaque rather than losing it', () {
      final d = region('status: draft   # TODO убрать\nnext: 1\n');
      final v = entryOf(d, 'status').value as FmOpaque;
      expect(v.raw, contains('# TODO убрать'));
      expect(entryOf(d, 'next').value, const FmScalar(ScalarKind.number, '1'));
    });

    test('a region that is not a mapping is Raw', () {
      for (final src in [
        '- just\n- a list\n',
        'plain scalar\n',
        'a: 1\n---\nb: 2\n',
        'a: 1\n\tb: 2\n',
        '# only a comment\n',
      ]) {
        expect(region(src), isA<FmRaw>(), reason: src);
      }
    });

    test('an empty region is an empty map, not Raw', () {
      expect(region(''), const FmMap([]));
    });
  });

  group('model — the original bug, as it already exists on disk', () {
    test('two list values under one key merge into one key', () {
      final d = region(
        'related:\n  - "[[2026-07-31]]"\nrelated:\n  - "[[2026-07-27]]"\n',
      );
      expect((d as FmMap).entries, hasLength(1));
      expect(entryOf(d, 'related').value,
          const FmList(['[[2026-07-31]]', '[[2026-07-27]]']));
    });

    test('two scalars under one key are last-wins by file order', () {
      final d = region('a: first\na: second\n');
      expect((d as FmMap).entries, hasLength(1));
      expect(entryOf(d, 'a').value, const FmScalar(ScalarKind.text, 'second'));
    });
  });

  group('render — quoting is decided by reading the bare form back', () {
    String rendered(FmValue v) => renderEntry(FmEntry(key: 'k', value: v));

    test('text that would read back as another kind is quoted', () {
      for (final text in ['true', 'false', '42', '1.5', '2026-08-03', '007']) {
        expect(rendered(FmScalar(ScalarKind.text, text)), 'k: "$text"\n',
            reason: text);
      }
    });

    test('values ambiguous across YAML versions are quoted', () {
      for (final text in ['yes', 'no', 'on', 'off', 'null', '~']) {
        expect(rendered(FmScalar(ScalarKind.text, text)), 'k: "$text"\n',
            reason: text);
      }
    });

    test('a value that would read as a fence is quoted', () {
      expect(rendered(const FmScalar(ScalarKind.text, '---')), 'k: "---"\n');
      expect(rendered(const FmScalar(ScalarKind.text, '...')), 'k: "..."\n');
    });

    test('punctuation, colons, comments and stray spaces are quoted', () {
      for (final text in ['[a]', '{a}', '#tag', 'a: b', 'a #c', ' pad', 'pad ',
        '*ref', '&anc', '@x', 'a:']) {
        expect(rendered(FmScalar(ScalarKind.text, text)), 'k: "$text"\n',
            reason: text);
      }
    });

    test('ordinary text and wikilinks stay bare', () {
      expect(rendered(const FmScalar(ScalarKind.text, 'hello world')),
          'k: hello world\n');
      expect(rendered(const FmScalar(ScalarKind.text, 'Привет')), 'k: Привет\n');
    });

    test('a real number stays bare — quoting it would change its type', () {
      expect(rendered(const FmScalar(ScalarKind.number, '42')), 'k: 42\n');
      expect(rendered(const FmScalar(ScalarKind.boolean, 'true')), 'k: true\n');
    });

    test('a list always renders block, whatever it was parsed from', () {
      expect(rendered(const FmList(['work', 'home'])),
          'k:\n  - work\n  - home\n');
    });

    test('a wikilink item is quoted because [ opens a construct', () {
      expect(rendered(const FmList(['[[a]]'])), 'k:\n  - "[[a]]"\n');
    });

    test('keys follow the same rule', () {
      expect(renderKey('книга'), 'книга');
      expect(renderKey('my key'), 'my key');
      expect(renderKey('a: b'), '"a: b"');
      expect(renderKey(' pad'), '" pad"');
      expect(renderKey('#x'), '"#x"');
    });
  });

  group('render — the note as a whole', () {
    test('a map with no live keys drops the fences entirely', () {
      expect(renderNote(const FmMap([]), '# Body\n'), '# Body\n');
    });

    test('Raw round-trips byte for byte', () {
      const raw = '- not\n- a mapping\n';
      expect(renderNote(const FmRaw(raw), 'body'), '---\n$raw---\nbody');
    });

    test('no rendered line is ever a fence', () {
      final note = renderNote(
        const FmMap([
          FmEntry(key: 'a', value: FmScalar(ScalarKind.text, '---')),
          FmEntry(key: 'b', value: FmList(['...'])),
        ]),
        'body\n',
      );
      final between = note.split('\n').sublist(1);
      final fences = between.takeWhile((l) => l != '---').toList();
      for (final line in fences) {
        expect(line, isNot(anyOf('---', '...')));
      }
    });
  });

  group('round-trip — the invariant', () {
    // §13: split ∘ project is idempotent and reaches a fixed point in one
    // step. Semantic stability is the blocking property; byte equality is a
    // quality metric, not a test.
    void stable(String note) {
      final first = model(note);
      final projected = renderNote(first.fm, first.body);
      final second = model(projected);
      expect(second.fm, first.fm, reason: 'model changed under render:\n$note');
      expect(second.body, first.body, reason: 'body changed:\n$note');
      // And a second pass changes nothing at all.
      expect(renderNote(second.fm, second.body), projected);
    }

    final cases = <String>[
      '---\ncreated: 2026-08-03\ntags:\n  - work\n---\n\n# Note\n',
      '---\ntags: [a, b]\n---\nbody\n',
      '---\n# leading comment\na: 1\n\n# another\nb: 2\n# trail\n---\nbody\n',
      '---\npublish:\n  status: draft\na: 1\n---\nbody\n',
      '---\nk: |\n  block\n  scalar\nz: 1\n---\nbody\n',
      '---\nstatus: draft  # inline\n---\nbody\n',
      '---\n"my key": v\nкнига: значение\n---\nbody\n',
      '---\na: "true"\nb: "007"\nc: "yes"\n---\nbody\n',
      '---\nempty:\nlist: []\n---\nbody\n',
      '---\n- not a mapping\n---\nbody\n',
      '---\n---\nbody with empty region\n',
      'no frontmatter at all\n',
      '---\na: 1\n---\n\n---\n\nrule in body\n',
      '---\nlinks:\n  - "[[a]]"\n  - "[[b]]"\n---\nbody\n',
    ];

    for (var i = 0; i < cases.length; i++) {
      test('case $i is stable under model → render → model', () {
        stable(cases[i]);
      });
    }
  });
}
