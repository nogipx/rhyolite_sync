import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

void main() {
  const diff = DiffTextUseCase();

  List<String> render(List<TextDiffLine> lines) => [
        for (final l in lines)
          '${switch (l.op) {
            TextDiffOp.equal => ' ',
            TextDiffOp.insert => '+',
            TextDiffOp.delete => '-',
          }}${l.text}',
      ];

  test('identical text → all equal', () {
    final r = diff('a\nb\nc', 'a\nb\nc')!;
    expect(r.every((l) => l.op == TextDiffOp.equal), isTrue);
    expect(r.map((l) => l.text), ['a', 'b', 'c']);
  });

  test('a changed line shows as delete + insert, context stays equal', () {
    final r = diff('# Title\nold paragraph\nend', '# Title\nhello\nend')!;
    expect(render(r), [
      ' # Title',
      '-old paragraph',
      '+hello',
      ' end',
    ]);
  });

  test('pure insertion at the end', () {
    final r = diff('a\nb', 'a\nb\nc')!;
    expect(render(r), [' a', ' b', '+c']);
  });

  test('pure deletion', () {
    final r = diff('a\nb\nc', 'a\nc')!;
    expect(render(r), [' a', '-b', ' c']);
  });

  test('empty before (new file) → everything inserted', () {
    final r = diff('', 'x\ny')!;
    expect(r.every((l) => l.op == TextDiffOp.insert), isTrue);
    expect(r.map((l) => l.text), ['x', 'y']);
  });

  test('repeated identical lines are matched, not spuriously rewritten', () {
    // Line-level (not char-level): duplicate lines must align.
    final r = diff('x\nx\nx', 'x\nx\nx\nx')!;
    expect(render(r).where((s) => s.startsWith('+')), ['+x']);
    expect(render(r).where((s) => s.startsWith('-')), isEmpty);
  });
}
