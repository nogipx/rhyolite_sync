// ignore_for_file: deprecated_member_use

import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Renders a git-style unified diff into [host]: a scrollable monospace block
/// with old/new line-number gutters and red/green line backgrounds. Long runs
/// of unchanged lines collapse to a "⋯ N unchanged ⋯" marker; the row count is
/// capped so a huge file can't blow up the modal.
///
/// Shared by the history version viewer and the backup restore-point diff.
void renderUnifiedDiff(
  JSObject host,
  List<TextDiffLine> lines, {
  int context = 3,
  int maxRows = 4000,
}) {
  _css(host, {
    'fontFamily': 'var(--font-monospace, monospace)',
    'fontSize': '12px',
    'lineHeight': '1.45',
    'border': '1px solid var(--background-modifier-border)',
    'borderRadius': '6px',
    'overflow': 'auto',
    'maxHeight': '55vh',
    'whiteSpace': 'pre',
  });

  final oldNo = List<int?>.filled(lines.length, null);
  final newNo = List<int?>.filled(lines.length, null);
  var o = 1, n = 1;
  for (var i = 0; i < lines.length; i++) {
    switch (lines[i].op) {
      case TextDiffOp.equal:
        oldNo[i] = o++;
        newNo[i] = n++;
      case TextDiffOp.delete:
        oldNo[i] = o++;
      case TextDiffOp.insert:
        newNo[i] = n++;
    }
  }

  final keep = List<bool>.filled(lines.length, false);
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].op == TextDiffOp.equal) continue;
    final lo = (i - context).clamp(0, lines.length - 1);
    final hi = (i + context).clamp(0, lines.length - 1);
    for (var j = lo; j <= hi; j++) {
      keep[j] = true;
    }
  }

  final doc = jsu.getProperty<JSObject>(host, 'ownerDocument');
  var rows = 0;
  var i = 0;
  while (i < lines.length && rows < maxRows) {
    if (keep[i]) {
      _diffLineRow(doc, host, lines[i], oldNo[i], newNo[i]);
      rows++;
      i++;
    } else {
      var j = i;
      while (j < lines.length && !keep[j]) {
        j++;
      }
      _diffGapRow(doc, host, j - i);
      rows++;
      i = j;
    }
  }
  if (i < lines.length) _diffGapRow(doc, host, lines.length - i, truncated: true);
}

void _diffLineRow(
  JSObject doc,
  JSObject host,
  TextDiffLine line,
  int? oldNo,
  int? newNo,
) {
  final row = _el(doc, host, 'div');
  _css(row, {'display': 'flex', 'alignItems': 'flex-start'});
  final (bg, sign) = switch (line.op) {
    TextDiffOp.insert => ('rgba(46, 160, 67, 0.18)', '+'),
    TextDiffOp.delete => ('rgba(248, 81, 73, 0.18)', '-'),
    TextDiffOp.equal => ('transparent', ' '),
  };
  _css(row, {'background': bg});

  _gutter(doc, row, oldNo);
  _gutter(doc, row, newNo);

  final signEl = _el(doc, row, 'span', text: sign);
  _css(signEl, {
    'width': '1.2em',
    'flex': '0 0 auto',
    'textAlign': 'center',
    'color': 'var(--text-muted)',
    'userSelect': 'none',
  });

  final content = _el(doc, row, 'span', text: line.text.isEmpty ? ' ' : line.text);
  _css(content,
      {'flex': '1 1 auto', 'whiteSpace': 'pre-wrap', 'wordBreak': 'break-word'});
}

void _diffGapRow(JSObject doc, JSObject host, int count, {bool truncated = false}) {
  final row = _el(
    doc,
    host,
    'div',
    text: truncated
        ? '⋯ $count more lines (diff truncated) ⋯'
        : '⋯ $count unchanged ⋯',
  );
  _css(row, {
    'padding': '2px 8px',
    'color': 'var(--text-faint)',
    'background': 'var(--background-secondary)',
    'textAlign': 'center',
    'userSelect': 'none',
  });
}

void _gutter(JSObject doc, JSObject row, int? no) {
  final g = _el(doc, row, 'span', text: no?.toString() ?? '');
  _css(g, {
    'flex': '0 0 auto',
    'minWidth': '3em',
    'padding': '0 6px',
    'textAlign': 'right',
    'color': 'var(--text-faint)',
    'userSelect': 'none',
  });
}

JSObject _el(JSObject doc, JSObject parent, String tag, {String? text}) {
  final el = jsu.callMethod<JSObject>(doc, 'createElement', [tag]);
  if (text != null) jsu.setProperty(el, 'textContent', text);
  jsu.callMethod<void>(parent, 'appendChild', [el]);
  return el;
}

void _css(JSObject el, Map<String, String> styles) {
  final style = jsu.getProperty<JSObject>(el, 'style');
  styles.forEach((k, v) {
    jsu.setProperty(style, k, v);
  });
}
