// ignore_for_file: deprecated_member_use
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_util' as jsu;
import 'dart:typed_data';

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import '../i18n/i18n.dart';
import 'diff_view.dart';

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
  final viewer = engine is StateSyncEngine
      ? engine.createFileVersionViewer()
      : null;
  final browser = engine is StateSyncEngine
      ? engine.createHistoryBrowser()
      : null;
  if (viewer == null || browser == null) {
    showNotice(S.versionHistoryUnavailable);
    return;
  }

  // No note open, or the open one has nothing recorded: offer the whole
  // history rather than a dead end. Both used to be a notice.
  final activeFile = plugin.app.workspace.getActiveFile();
  if (activeFile == null) {
    await showHistoryPathPicker(plugin, viewer, browser);
    return;
  }
  final relPath = activeFile.path;

  final List<HistoryEntry> versions;
  try {
    versions = await viewer.versionsOf(relPath);
  } catch (e) {
    showNotice(S.failedToLoadHistory(relPath, e));
    return;
  }

  if (versions.isEmpty) {
    showNotice(S.noHistoryFor(relPath));
    await showHistoryPathPicker(plugin, viewer, browser);
    return;
  }

  await _showVersionList(plugin, viewer, browser, relPath, versions);
}

/// Every path the history knows, newest activity first — including paths that
/// no longer exist.
///
/// This is the only way to reach the versions of a note that was renamed or
/// deleted. History is keyed by PATH: renaming a note starts a fresh history
/// under the new name and leaves the old one behind, and since the version
/// browser opens the ACTIVE note's history, nothing that is no longer on disk
/// could be opened at all.
///
/// The list is built from the most recent [_kPathScanLimit] events because the
/// history endpoint takes a limit and no cursor. The hint says so rather than
/// implying the list is exhaustive; picking a path re-queries that path alone,
/// so the versions shown for it are complete.
Future<void> showHistoryPathPicker(
  PluginHandle plugin,
  FileVersionViewer viewer,
  HistoryBrowser browser,
) async {
  final List<HistoryEntry> all;
  try {
    all = await browser.list(limit: _kPathScanLimit);
  } catch (e) {
    showNotice(S.failedToLoadHistory('', e));
    return;
  }

  if (all.isEmpty) {
    showNotice(S.historyEmpty);
    return;
  }

  // Group by path, keeping the newest entry per path for the meta line. The
  // list arrives newest-first, so the first entry seen for a path is its
  // latest — and whether THAT one is a deletion is what decides the marker.
  final byPath = <String, ({int count, HistoryEntry newest})>{};
  for (final e in all) {
    if (e.path.isEmpty) continue;
    final seen = byPath[e.path];
    byPath[e.path] = seen == null
        ? (count: 1, newest: e)
        : (count: seen.count + 1, newest: seen.newest);
  }

  final paths = byPath.entries.toList()
    ..sort((a, b) => b.value.newest.createdAt.compareTo(
          a.value.newest.createdAt,
        ));

  await _showPathList(plugin, viewer, browser, paths, all.length);
}

/// How many history events the path list is built from. The endpoint has no
/// cursor, so this is a ceiling, not a page size.
const int _kPathScanLimit = 3000;

Future<void> _showPathList(
  PluginHandle plugin,
  FileVersionViewer viewer,
  HistoryBrowser browser,
  List<MapEntry<String, ({int count, HistoryEntry newest})>> paths,
  int scannedEvents,
) {
  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3(S.historyPickFile);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: S.historyPickHint(paths.length, scannedEvents),
      );
      ctx.spaceVertical(px: 8);

      final filter = ctx.createEl('input', cls: 'rhyolite-history-filter');
      jsu.setProperty(filter, 'type', 'text');
      jsu.setProperty(filter, 'placeholder', S.historyFilterPlaceholder);
      _css(filter, {'width': '100%'});
      ctx.spaceVertical(px: 8);

      final list = ctx.createEl('div');
      _css(list, {
        'display': 'flex',
        'flexDirection': 'column',
        'gap': '6px',
        'maxHeight': '55vh',
        'overflowY': 'auto',
        'paddingRight': '4px',
      });
      final doc = jsu.getProperty<JSObject>(list, 'ownerDocument');

      final empty = _el(doc, list, 'p', text: S.historyNothingMatches);
      _css(empty, {'display': 'none', 'opacity': '0.7'});

      final rows = <(String, JSObject)>[];
      for (final entry in paths) {
        final path = entry.key;
        final info = entry.value;
        final gone = info.newest.operation == HistoryOperation.delete;

        final btn = _el(doc, list, 'button');
        _css(btn, {
          'width': '100%',
          'textAlign': 'left',
          'flex': '0 0 auto',
          'display': 'flex',
          'flexDirection': 'column',
          'alignItems': 'flex-start',
          'gap': '2px',
          'height': 'auto',
          'padding': '8px 10px',
        });

        final title = _el(doc, btn, 'span', text: path);
        _css(title, {
          'width': '100%',
          'overflow': 'hidden',
          'textOverflow': 'ellipsis',
          'whiteSpace': 'nowrap',
        });
        if (gone) _css(title, {'opacity': '0.75'});

        final meta = _el(
          doc,
          btn,
          'span',
          text: gone
              ? '${S.historyGoneMark}  ·  '
                  '${S.historyPathMeta(info.count, _fmt(info.newest.createdAt))}'
              : S.historyPathMeta(info.count, _fmt(info.newest.createdAt)),
        );
        _css(meta, {'fontSize': '11px', 'opacity': '0.7'});

        _onClick(btn, () async {
          ctx.close(null);
          await _openPath(plugin, viewer, browser, path);
        });
        rows.add((path.toLowerCase(), btn));
      }

      jsu.callMethod<void>(filter, 'addEventListener', [
        'input',
        jsu.allowInterop((JSAny? _) {
          final q =
              (jsu.getProperty<String?>(filter, 'value') ?? '').toLowerCase();
          var shown = 0;
          for (final (haystack, el) in rows) {
            final match = q.isEmpty || haystack.contains(q);
            if (match) shown++;
            _css(el, {'display': match ? 'flex' : 'none'});
          }
          _css(empty, {'display': shown == 0 ? 'block' : 'none'});
        }),
      ]);

      ctx.spaceVertical(px: 12);
      ctx.buttonRow([ButtonSpec(S.cancel, () => ctx.close(null))]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

/// Re-queries one path so its version list is complete, rather than reusing
/// the slice that fitted in the scan window.
Future<void> _openPath(
  PluginHandle plugin,
  FileVersionViewer viewer,
  HistoryBrowser browser,
  String path,
) async {
  final List<HistoryEntry> versions;
  try {
    versions = await viewer.versionsOf(path);
  } catch (e) {
    showNotice(S.failedToLoadHistory(path, e));
    return;
  }
  if (versions.isEmpty) {
    showNotice(S.noHistoryFor(path));
    return;
  }
  await _showVersionList(plugin, viewer, browser, path, versions);
}

Future<void> _showVersionList(
  PluginHandle plugin,
  FileVersionViewer viewer,
  HistoryBrowser browser,
  String relPath,
  List<HistoryEntry> versions,
) {
  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3(S.versionHistoryTitle);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: relPath,
      );
      ctx.spaceVertical(px: 8);

      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: S.versionsCountHint(versions.length),
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
          await _showVersionPreview(
            plugin,
            viewer,
            browser,
            entry,
            relPath,
            versions,
          );
        });
      }

      ctx.spaceVertical(px: 12);
      // Reachable from here, not only from an empty editor: the file whose
      // history you want is often not the one you have open — above all when
      // it no longer exists.
      ctx.buttonRow([
        ButtonSpec(S.historyOtherFile, () async {
          ctx.close(null);
          await showHistoryPathPicker(plugin, viewer, browser);
        }),
        ButtonSpec(S.cancel, () => ctx.close(null)),
      ]);
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
  HistoryBrowser browser,
  HistoryEntry entry,
  String relPath,
  List<HistoryEntry> versions,
) async {
  // Fetch both the version's content and the current on-disk file BEFORE
  // building the modal so we can show a diff (or a binary marker) right away.
  final bytes = await viewer.contentAt(entry);
  final current = await viewer.currentContent(entry.path);

  // Closes this preview and returns to the version list (no re-fetch).
  Future<void> back() =>
      _showVersionList(plugin, viewer, browser, relPath, versions);

  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3(S.versionPreviewTitle);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: S.versionPreviewSubtitle(entry.path, _fmt(entry.createdAt)),
      );
      ctx.spaceVertical(px: 12);

      if (bytes == null) {
        ctx.createEl('p', text: S.blobNoLongerAvailable);
        ctx.spaceVertical(px: 16);
        ctx.buttonRow([
          ButtonSpec(S.back, () async {
            ctx.close(null);
            await back();
          }),
          ButtonSpec(S.close, () => ctx.close(null)),
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
          ctx.createEl('p',
              cls: 'rhyolite-setting-desc',
              text: S.fileDoesNotExistWillRecreate);
        }
        final diff = const DiffTextUseCase()(currentText, versionText);
        if (diff == null) {
          // Too many distinct lines to diff — fall back to a plain preview.
          final preview = versionText.length > 8000
              ? '${versionText.substring(0, 8000)}\n\n'
                  '${S.moreCharacters(versionText.length - 8000)}'
              : versionText;
          ctx.createEl('pre', cls: 'rhyolite-version-preview', text: preview);
        } else if (diff.every((l) => l.op == TextDiffOp.equal)) {
          ctx.createEl('p', text: S.noDifferencesMatchesDisk);
        } else {
          renderUnifiedDiff(ctx.createEl('div'), diff);
        }
      } else {
        ctx.createEl('p', text: S.binaryContentPreview(_fmtSize(bytes.length)));
      }
      ctx.spaceVertical(px: 16);

      Future<void> doRestore() async {
        try {
          await viewer.restore(entry);
          showNotice(S.restoredFromVersion(entry.path, _fmt(entry.createdAt)));
          ctx.close(null);
        } catch (e) {
          ctx.showError(S.restoreFailed(e));
        }
      }

      ctx.buttonRow([
        ButtonSpec(S.restoreVerb, doRestore, variant: ButtonVariant.destructive),
        ButtonSpec(S.back, () async {
          ctx.close(null);
          await back();
        }),
        ButtonSpec(S.close, () => ctx.close(null)),
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
