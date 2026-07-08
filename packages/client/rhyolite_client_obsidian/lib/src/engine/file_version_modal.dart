// ignore_for_file: deprecated_member_use
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_util' as jsu;
import 'dart:typed_data';

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Per-file version history for the currently active note. Mirrors the
/// shape of Obsidian Sync's "Open version history": pick a version from
/// the list, see its content, click Restore to revert the file on disk.
///
/// Two-modal navigation because the modal primitive doesn't support
/// dynamic re-rendering of preview content in-place: list → preview.
Future<void> showFileVersionModal(
  PluginHandle plugin,
  ISyncEngine engine,
) async {
  final activeFile = plugin.app.workspace.getActiveFile();
  if (activeFile == null) {
    showNotice('No file is open');
    return;
  }
  final relPath = activeFile.path;

  final viewer = engine is StateSyncEngine
      ? engine.createFileVersionViewer()
      : null;
  if (viewer == null) {
    showNotice('Version history not available — engine is not connected');
    return;
  }

  final List<HistoryEntry> versions;
  try {
    versions = await viewer.versionsOf(relPath);
  } catch (e) {
    showNotice('Failed to load history for $relPath: $e');
    return;
  }

  if (versions.isEmpty) {
    showNotice('No history for $relPath');
    return;
  }

  await _showVersionList(plugin, viewer, relPath, versions);
}

Future<void> _showVersionList(
  PluginHandle plugin,
  FileVersionViewer viewer,
  String relPath,
  List<HistoryEntry> versions,
) {
  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3('Version history');
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: relPath,
      );
      ctx.spaceVertical(px: 8);

      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: '${versions.length} version(s), newest first. '
            'Select one to preview and restore.',
      );
      ctx.spaceVertical(px: 8);

      // Single-column, vertically scrollable list — one full-width row per
      // version. Click drills into the preview; the preview's Back returns
      // here. Raw <button>s keep Obsidian's native styling + hover.
      final list = ctx.createEl('div');
      _css(list, {
        'display': 'flex',
        'flexDirection': 'column',
        'gap': '6px',
        'maxHeight': '60vh',
        'overflowY': 'auto',
        'paddingRight': '4px',
      });
      final doc = jsu.getProperty<JSObject>(list, 'ownerDocument');
      for (final entry in versions) {
        final btn = _el(doc, list, 'button', text: _label(entry));
        _css(btn, {
          'width': '100%',
          'textAlign': 'left',
          'flex': '0 0 auto',
          'whiteSpace': 'nowrap',
        });
        _onClick(btn, () async {
          ctx.close(null);
          await _showVersionPreview(plugin, viewer, entry, relPath, versions);
        });
      }

      ctx.spaceVertical(px: 12);
      ctx.buttonRow([ButtonSpec('Cancel', () => ctx.close(null))]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

bool _looksBinary(Uint8List bytes) {
  final probe = bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes;
  return probe.contains(0);
}

Future<void> _showVersionPreview(
  PluginHandle plugin,
  FileVersionViewer viewer,
  HistoryEntry entry,
  String relPath,
  List<HistoryEntry> versions,
) async {
  // Fetch both the version's content and the current on-disk file BEFORE
  // building the modal so we can show a diff (or a binary marker) right away.
  final bytes = await viewer.contentAt(entry);
  final current = await viewer.currentContent(entry.path);

  // Closes this preview and returns to the version list (no re-fetch).
  Future<void> back() => _showVersionList(plugin, viewer, relPath, versions);

  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3('Version preview');
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: '${entry.path}  ·  ${_fmt(entry.createdAt)}  ·  vs current',
      );
      ctx.spaceVertical(px: 12);

      if (bytes == null) {
        ctx.createEl(
          'p',
          text: 'The blob for this version is no longer available — '
              'it may have been removed during a cleanup, or never '
              'downloaded to this device.',
        );
        ctx.spaceVertical(px: 16);
        ctx.buttonRow([
          ButtonSpec('Back', () async {
            ctx.close(null);
            await back();
          }),
          ButtonSpec('Close', () => ctx.close(null)),
        ]);
        ctx.onEscape(() async {
          ctx.close(null);
          await back();
        });
        return;
      }

      final versionIsText = !_looksBinary(bytes);
      final currentIsText = current == null || !_looksBinary(current);

      if (versionIsText && currentIsText) {
        // Diff current → version: '-' lines are dropped by a restore, '+'
        // lines are added — so the user sees exactly what Restore would do.
        final currentText =
            current == null ? '' : utf8.decode(current, allowMalformed: true);
        final versionText = utf8.decode(bytes, allowMalformed: true);
        if (current == null) {
          ctx.createEl(
            'p',
            cls: 'rhyolite-setting-desc',
            text: 'This file does not currently exist on disk — restoring '
                'will re-create it.',
          );
        }
        final diff = const DiffTextUseCase()(currentText, versionText);
        if (diff == null) {
          // Too many distinct lines to diff — fall back to a plain preview.
          final preview = versionText.length > 8000
              ? '${versionText.substring(0, 8000)}\n\n…(${versionText.length - 8000} more characters)'
              : versionText;
          ctx.createEl('pre', cls: 'rhyolite-version-preview', text: preview);
        } else if (diff.every((l) => l.op == TextDiffOp.equal)) {
          ctx.createEl(
            'p',
            text: 'No differences — this version matches the file on disk.',
          );
        } else {
          _renderDiffDom(ctx.createEl('div'), diff);
        }
      } else {
        ctx.createEl(
          'p',
          text: 'Binary content (${_fmtSize(bytes.length)}). '
              'Cannot preview, but Restore will write the original bytes.',
        );
      }
      ctx.spaceVertical(px: 16);

      Future<void> doRestore() async {
        try {
          await viewer.restore(entry);
          showNotice('Restored ${entry.path} from ${_fmt(entry.createdAt)}.');
          ctx.close(null);
        } catch (e) {
          ctx.showError('Restore failed: $e');
        }
      }

      ctx.buttonRow([
        ButtonSpec('Restore', doRestore, variant: ButtonVariant.destructive),
        ButtonSpec('Back', () async {
          ctx.close(null);
          await back();
        }),
        ButtonSpec('Close', () => ctx.close(null)),
      ]);
      // Escape returns to the version list (drill in → step back), not a full
      // dismiss — that's the Close button.
      ctx.onEscape(() async {
        ctx.close(null);
        await back();
      });
    },
  );
}

/// Renders a git-style unified diff into [host]: a scrollable monospace block
/// with old/new line-number gutters and red/green line backgrounds. Long runs
/// of unchanged lines collapse to a "⋯ N unchanged ⋯" marker; the row count is
/// capped so a huge file can't blow up the modal.
void _renderDiffDom(
  JSObject host,
  List<TextDiffLine> lines, {
  int context = 3,
  int maxRows = 4000,
}) {
  // Container: monospace, bordered, vertically scrollable.
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

  // Assign old/new line numbers up front so gutters are correct even in the
  // collapsed view.
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

  // Keep changed lines plus `context` unchanged lines around each change.
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
  _css(content, {'flex': '1 1 auto', 'whiteSpace': 'pre-wrap', 'wordBreak': 'break-word'});
}

void _diffGapRow(JSObject doc, JSObject host, int count, {bool truncated = false}) {
  final row = _el(
    doc,
    host,
    'div',
    text: truncated ? '⋯ $count more lines (diff truncated) ⋯' : '⋯ $count unchanged ⋯',
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

void _onClick(JSObject el, void Function() handler) {
  jsu.callMethod<void>(el, 'addEventListener', [
    'click',
    jsu.allowInterop((JSAny? _) => handler()),
  ]);
}

void _css(JSObject el, Map<String, String> styles) {
  final style = jsu.getProperty<JSObject>(el, 'style');
  styles.forEach((k, v) {
    jsu.setProperty(style, k, v);
  });
}

String _label(HistoryEntry entry) {
  final size = entry.operation == HistoryOperation.delete
      ? ''
      : '  (${_fmtSize(entry.sizeBytes)})';
  return '${_opLabel(entry.operation)}  ${_fmt(entry.createdAt)}$size';
}

String _opLabel(HistoryOperation op) {
  switch (op) {
    case HistoryOperation.create:
      return '[+]';
    case HistoryOperation.modify:
      return '[~]';
    case HistoryOperation.delete:
      return '[-]';
    case HistoryOperation.move:
      return '[>]';
  }
}

String _fmt(DateTime d) {
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
