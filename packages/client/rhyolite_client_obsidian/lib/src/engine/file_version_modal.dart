import 'dart:convert';

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
      ctx.spaceVertical(px: 12);

      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: '${versions.length} version(s), newest first. '
            'Select one to preview and restore.',
      );
      ctx.spaceVertical(px: 8);

      // One button per version. Click → preview submodal.
      final buttons = <ButtonSpec>[
        for (final entry in versions)
          ButtonSpec(
            _label(entry),
            () async {
              ctx.close(null);
              await _showVersionPreview(plugin, viewer, entry);
            },
          ),
        ButtonSpec('Cancel', () => ctx.close(null)),
      ];
      ctx.buttonRow(buttons);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

Future<void> _showVersionPreview(
  PluginHandle plugin,
  FileVersionViewer viewer,
  HistoryEntry entry,
) async {
  // Fetch + decrypt the bytes once, BEFORE building the modal so we
  // can show either a text preview or a 'binary' marker right away.
  final bytes = await viewer.contentAt(entry);

  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3('Version preview');
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: '${entry.path}  ·  ${_fmt(entry.createdAt)}',
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
        ctx.buttonRow([ButtonSpec('Close', () => ctx.close(null))]);
        return;
      }

      // Heuristic: probe first 4 KiB for a null byte to spot binary.
      final probe = bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes;
      final isText = !probe.contains(0);

      if (isText) {
        final text = utf8.decode(bytes, allowMalformed: true);
        final preview = text.length > 8000
            ? '${text.substring(0, 8000)}\n\n…(${text.length - 8000} more characters)'
            : text;
        ctx.createEl('pre', cls: 'rhyolite-version-preview', text: preview);
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
        ButtonSpec('Close', () => ctx.close(null)),
      ]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
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
