// ignore_for_file: deprecated_member_use

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import 'diff_view.dart';

/// Inspects one restore point against the current vault as an interactive file
/// explorer: collapsible folders + a per-file status (identical / changed /
/// restores-a-deleted-file / tombstoned). Click any file to see its
/// detail — for a changed text file, a content diff of the frozen version vs
/// what's on disk now. Read-only; restoring is done from the list modal.
Future<void> showBackupInspectModal(
  PluginHandle plugin,
  StateSyncEngine engine,
  BackupSnapshotInfo snapshot,
) async {
  final BackupInspection? inspection;
  try {
    inspection = await engine.inspectBackup(snapshot.snapshotId);
  } catch (e) {
    showNotice('Failed to inspect restore point: $e');
    return;
  }
  if (inspection == null) {
    showNotice('Not connected — cannot inspect.');
    return;
  }

  final when = DateTime.fromMillisecondsSinceEpoch(snapshot.createdAtMs).toLocal();
  // The tree shows only files that differ from the current vault — an identical
  // file is noise here. The summary line still reports the identical count.
  final changedEntries = inspection.entries
      .where((e) => e.status != BackupEntryStatus.identical)
      .toList();
  final root = _buildTree(changedEntries);

  await showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3('Restore point · ${_fmt(when)}');
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: '${inspection!.changed} changed · '
            '${inspection.restoresDeleted} to restore (deleted since) · '
            '${inspection.identical} identical'
            '${inspection.deletedInBackup > 0 ? ' · ${inspection.deletedInBackup} deletion' : ''}',
      );
      ctx.spaceVertical(px: 8);

      if (changedEntries.isEmpty) {
        ctx.createEl('p',
            cls: 'rhyolite-setting-desc',
            text: 'No changes vs the current vault — every file is identical.');
      } else {
        final treeRoot = ctx.createEl('div', cls: 'rhyolite-backup-tree');
        _renderNode(
          root,
          treeRoot,
          onFile: (entry) => _showEntryDetail(plugin, engine, entry),
        );
      }

      ctx.spaceVertical(px: 12);
      ctx.buttonRow([ButtonSpec('Close', () => ctx.close(null))]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

// ---------------------------------------------------------------------------
// Tree model
// ---------------------------------------------------------------------------

class _Node {
  _Node(this.name);
  final String name;
  final Map<String, _Node> dirs = {};
  final List<BackupEntry> files = [];
}

_Node _buildTree(List<BackupEntry> entries) {
  final root = _Node('');
  for (final e in entries) {
    final parts = e.path.split('/');
    var node = root;
    for (var i = 0; i < parts.length - 1; i++) {
      node = node.dirs.putIfAbsent(parts[i], () => _Node(parts[i]));
    }
    node.files.add(e);
  }
  return root;
}

/// Renders a node's folders (collapsible) then files (clickable) into [parent],
/// reusing Obsidian's own tree DOM/CSS (`tree-item*`, `collapse-icon`, the
/// `right-triangle` icon, `is-collapsed`) so it looks and behaves like the
/// native file explorer — indentation, hover and caret come from the theme.
void _renderNode(
  _Node node,
  JSObject parent, {
  required void Function(BackupEntry) onFile,
}) {
  final dirNames = node.dirs.keys.toList()..sort();
  for (final name in dirNames) {
    final child = node.dirs[name]!;
    final item = _child(parent, 'div', cls: 'tree-item nav-folder');
    final self = _child(item, 'div',
        cls: 'tree-item-self nav-folder-title is-clickable mod-collapsible');
    final icon = _child(self, 'div', cls: 'tree-item-icon collapse-icon');
    _setIcon(icon, 'right-triangle');
    _text(_child(self, 'div', cls: 'tree-item-inner nav-folder-title-content'),
        name);

    final children =
        _child(item, 'div', cls: 'tree-item-children nav-folder-children');
    _renderNode(child, children, onFile: onFile);

    var collapsed = false;
    _onClick(self, () {
      collapsed = !collapsed;
      if (collapsed) {
        _addClass(item, 'is-collapsed');
        _display(children, 'none');
      } else {
        _removeClass(item, 'is-collapsed');
        _display(children, '');
      }
    });
  }

  final files = node.files.toList()
    ..sort((a, b) =>
        a.path.split('/').last.compareTo(b.path.split('/').last));
  for (final e in files) {
    final name = e.path.split('/').last;
    final item = _child(parent, 'div', cls: 'tree-item nav-file');
    final self = _child(item, 'div',
        cls: 'tree-item-self nav-file-title is-clickable');
    _text(_child(self, 'div', cls: 'tree-item-inner nav-file-title-content'),
        name);
    final flair = _flair(e.status);
    if (flair.isNotEmpty) {
      final outer = _child(self, 'div', cls: 'tree-item-flair-outer');
      _text(_child(outer, 'span', cls: 'tree-item-flair'), flair);
    }
    _onClick(self, () => onFile(e));
  }
}

String _flair(BackupEntryStatus s) => switch (s) {
      BackupEntryStatus.identical => '',
      BackupEntryStatus.changed => 'changed',
      BackupEntryStatus.restoresDeleted => 'deleted now',
      BackupEntryStatus.deletedInBackup => 'tombstone',
    };

// ---------------------------------------------------------------------------
// Per-file detail / diff
// ---------------------------------------------------------------------------

Future<void> _showEntryDetail(
  PluginHandle plugin,
  StateSyncEngine engine,
  BackupEntry entry,
) async {
  switch (entry.status) {
    case BackupEntryStatus.identical:
      showNotice('${entry.path}: identical to current — nothing would change.');
      return;
    case BackupEntryStatus.deletedInBackup:
      showNotice('${entry.path}: was deleted in this restore point.');
      return;
    case BackupEntryStatus.changed:
    case BackupEntryStatus.restoresDeleted:
      break;
  }

  final restoresDeleted = entry.status == BackupEntryStatus.restoresDeleted;

  // Text vs binary is decided by extension (the same call the engine uses to
  // pick Fugue vs LWW) — NOT by whether utf8 happens to decode, so a note with
  // an odd byte still shows a diff instead of a false "binary".
  final isText = FileTypeDetector().isText(entry.path);
  if (!isText) {
    await showModalWith<void>(
      plugin,
      build: (ctx) {
        ctx.h3('${restoresDeleted ? 'Restores' : 'Diff'} · ${entry.path}');
        ctx.createEl(
          'p',
          cls: 'rhyolite-setting-desc',
          text: restoresDeleted
              ? 'Binary file — would be restored (${entry.sizeBytes} bytes).'
              : 'Binary file — content differs (not shown as text).',
        );
        ctx.spaceVertical(px: 12);
        ctx.buttonRow([
          ButtonSpec(
            restoresDeleted ? 'Restore this file' : 'Restore this version',
            () => _restoreOne(plugin, ctx, engine, entry),
            variant: ButtonVariant.primary,
          ),
          ButtonSpec('Close', () => ctx.close(null)),
        ]);
        ctx.onEscape(() => ctx.close(null));
      },
    );
    return;
  }

  showNotice('Loading ${entry.path} …');
  // Text content is materialised server-side into plain text (the blob is the
  // Fugue serialization) by engine.backupFileContent — no \0fg1 leaks here.
  final String backupText;
  var currentText = ''; // empty for restoresDeleted (no current file)
  try {
    final backupBytes = await engine.backupFileContent(entry.blobRef, entry.path);
    if (backupBytes == null) {
      showNotice('Backup content for ${entry.path} is unavailable.');
      return;
    }
    backupText = utf8.decode(backupBytes, allowMalformed: true);
    if (!restoresDeleted) {
      currentText =
          utf8.decode(await engine.io.readFile(entry.path), allowMalformed: true);
    }
  } catch (e) {
    showNotice('Could not load ${entry.path}: $e');
    return;
  }

  // Diff current -> backup version, like the history viewer: '+' is what a
  // restore would add, '-' is what it would drop.
  final diff = const DiffTextUseCase()(currentText, backupText);

  await showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3('${restoresDeleted ? 'Restores' : 'Diff'} · ${entry.path}');
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: restoresDeleted
            ? 'Deleted from the vault since — restoring adds this content:'
            : 'Restoring would apply these changes (- current, + backup):',
      );
      if (diff == null) {
        ctx.createEl('p',
            cls: 'rhyolite-setting-desc',
            text: 'Too many changes to diff — restore to inspect.');
      } else if (diff.every((l) => l.op == TextDiffOp.equal)) {
        ctx.createEl('p',
            cls: 'rhyolite-setting-desc',
            text: 'No differences — identical to the file on disk.');
      } else {
        renderUnifiedDiff(ctx.createEl('div'), diff);
      }

      ctx.spaceVertical(px: 12);
      ctx.buttonRow([
        ButtonSpec(
          restoresDeleted ? 'Restore this file' : 'Restore this version',
          () => _restoreOne(plugin, ctx, engine, entry),
          variant: ButtonVariant.primary,
        ),
        ButtonSpec('Close', () => ctx.close(null)),
      ]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

/// Restore one file in place — overwrite the live file with the backup version
/// (syncs as a normal edit, reversible via file history).
Future<void> _restoreOne(
  PluginHandle plugin,
  ModalContext<void> ctx,
  StateSyncEngine engine,
  BackupEntry entry,
) async {
  ctx.close(null);
  showNotice('Restoring ${entry.path} …');
  try {
    final ok = await engine.restoreBackupFile(entry.blobRef, entry.path);
    showNotice(ok
        ? '${entry.path} restored (reversible via history).'
        : 'Could not restore ${entry.path} — not connected or blob gone.');
  } catch (e) {
    showNotice('Restore failed: $e');
  }
}

// ---------------------------------------------------------------------------
// Low-level DOM helpers (Obsidian augments HTMLElement with createEl)
// ---------------------------------------------------------------------------

JSObject _child(JSObject parent, String tag, {String? cls}) {
  final el = jsu.callMethod<JSObject>(parent, 'createEl', [tag]);
  if (cls != null) jsu.setProperty(el, 'className', cls);
  return el;
}

void _text(JSObject el, String text) {
  jsu.setProperty(el, 'textContent', text);
}

void _display(JSObject el, String value) {
  jsu.setProperty(jsu.getProperty<JSObject>(el, 'style'), 'display', value);
}

void _addClass(JSObject el, String cls) {
  jsu.callMethod<Object?>(el, 'addClass', [cls]);
}

void _removeClass(JSObject el, String cls) {
  jsu.callMethod<Object?>(el, 'removeClass', [cls]);
}

/// Renders an Obsidian Lucide icon into [el] via the module's `setIcon`.
void _setIcon(JSObject el, String iconId) {
  jsu.callMethod<Object?>(obsidianModule(), 'setIcon', [el, iconId]);
}

void _onClick(JSObject el, void Function() cb) {
  jsu.callMethod<Object?>(el, 'addEventListener', [
    'click',
    jsu.allowInterop((JSAny? _) => cb()),
  ]);
}


String _fmt(DateTime d) =>
    '${d.year}-${_pad(d.month)}-${_pad(d.day)} ${_pad(d.hour)}:${_pad(d.minute)}';
String _pad(int n) => n.toString().padLeft(2, '0');
