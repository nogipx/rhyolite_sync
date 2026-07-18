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
  final activeFile = plugin.app.workspace.getActiveFile();
  if (activeFile == null) {
    showNotice(S.noFileOpen);
    return;
  }
  final relPath = activeFile.path;

  final viewer = engine is StateSyncEngine
      ? engine.createFileVersionViewer()
      : null;
  if (viewer == null) {
    showNotice(S.versionHistoryUnavailable);
    return;
  }

  final List<HistoryEntry> versions;
  try {
    versions = await viewer.versionsOf(relPath);
  } catch (e) {
    showNotice(S.failedToLoadHistory(relPath, e));
    return;
  }

  if (versions.isEmpty) {
    showNotice(S.noHistoryFor(relPath));
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
          await _showVersionPreview(plugin, viewer, entry, relPath, versions);
        });
      }

      ctx.spaceVertical(px: 12);
      ctx.buttonRow([ButtonSpec(S.cancel, () => ctx.close(null))]);
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
