import 'package:diff_match_patch/diff_match_patch.dart';

/// One line of a unified diff.
enum TextDiffOp { equal, insert, delete }

class TextDiffLine {
  const TextDiffLine(this.op, this.text);

  final TextDiffOp op;

  /// The line content (without the trailing newline).
  final String text;
}

/// Line-level diff between two text snapshots — for the file-history viewer's
/// "what changed" view. Callable: `DiffTextUseCase()(before, after)`.
///
/// diff_match_patch is character-oriented, so we run it over a per-line
/// encoding (each distinct line → one UTF-16 code unit) to get a LINE-level
/// diff. Returns null when a text has more distinct lines than fit that
/// encoding (~65k) — the caller then falls back to a plain preview.
class DiffTextUseCase {
  const DiffTextUseCase();

  static const _maxLines = 0xFFFF;

  List<TextDiffLine>? call(String before, String after) {
    final lines = <String>[];
    final ids = <String, int>{};

    // Empty text = zero lines; a trailing newline terminates its line rather
    // than adding an empty one — so an empty file vs content reads as pure
    // insertions, not a spurious blank-line delete.
    List<String> splitLines(String text) {
      if (text.isEmpty) return const [];
      final body =
          text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
      return body.split('\n');
    }

    String? encode(String text) {
      final buf = StringBuffer();
      for (final line in splitLines(text)) {
        var id = ids[line];
        if (id == null) {
          if (lines.length >= _maxLines) return null;
          id = lines.length;
          lines.add(line);
          ids[line] = id;
        }
        buf.writeCharCode(id);
      }
      return buf.toString();
    }

    final e1 = encode(before);
    final e2 = encode(after);
    if (e1 == null || e2 == null) return null;

    final diffs = diff(e1, e2, checklines: false);
    final out = <TextDiffLine>[];
    for (final d in diffs) {
      final op = switch (d.operation) {
        DIFF_INSERT => TextDiffOp.insert,
        DIFF_DELETE => TextDiffOp.delete,
        _ => TextDiffOp.equal,
      };
      // We encoded each line as a single code unit, so iterate code units.
      for (final unit in d.text.codeUnits) {
        out.add(TextDiffLine(op, lines[unit]));
      }
    }
    return out;
  }
}
