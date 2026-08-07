import 'package:obsidian_dart/obsidian_dart.dart';

import '../i18n/i18n.dart';

/// A vault folder offered in the picker, with how many files sit under it
/// (including nested ones) so the user can see what a choice actually costs.
typedef VaultFolder = ({String path, int fileCount});

/// Every folder in the vault that holds at least one syncable file, sorted so
/// a child always follows its parent.
///
/// Derived from the file list rather than from Obsidian's folder tree: the
/// engine only ever sees files, an empty folder is nothing to sync, and this
/// way the counts come for free. Dot-prefixed segments are dropped for the
/// same reason the startup scan skips them — `.obsidian` and friends belong to
/// settings sync, not to the note keyspace this filter governs.
List<VaultFolder> vaultFolders(VaultHandle vault) {
  final counts = <String, int>{};
  for (final file in vault.getFiles()) {
    final segments = file.path.split('/');
    if (segments.any((s) => s.startsWith('.'))) continue;
    for (var i = 1; i < segments.length; i++) {
      final dir = segments.take(i).join('/');
      counts[dir] = (counts[dir] ?? 0) + 1;
    }
  }
  final paths = counts.keys.toList()..sort();
  return [for (final p in paths) (path: p, fileCount: counts[p]!)];
}

/// Checkbox picker over the vault's folders. Returns the chosen set, or null
/// when the user cancels.
///
/// [initial] may contain entries that are not folders (a single file, or a
/// folder that has since been renamed). Those are kept verbatim in the result
/// so opening the picker never silently drops what the user typed by hand.
Future<Set<String>?> showFolderScopeModal(
  PluginHandle plugin, {
  required String title,
  required String description,
  required Set<String> initial,
}) {
  final folders = vaultFolders(plugin.app.vault);
  final byLowerPath = {for (final f in folders) f.path.toLowerCase(): f.path};
  final selected = <String>{};
  // Entries the picker cannot show as a row — hand-typed file paths, folders
  // that no longer exist. Carried through untouched.
  final unlisted = <String>{};
  for (final entry in initial) {
    final match = byLowerPath[entry.toLowerCase()];
    if (match != null) {
      selected.add(match);
    } else {
      unlisted.add(entry);
    }
  }

  return showModalWith<Set<String>?>(
    plugin,
    build: (ctx) {
      ctx.h3(title);
      ctx.createEl('p', cls: 'rhyolite-setting-desc', text: description);
      ctx.spaceVertical(px: 8);

      if (folders.isEmpty) {
        ctx.createEl('p', cls: 'rhyolite-setting-desc', text: S.noFoldersFound);
      }
      for (final folder in folders) {
        ctx.toggle(
          label: '${folder.path}  (${folder.fileCount})',
          initialValue: selected.contains(folder.path),
          onChange: (on) {
            if (on) {
              selected.add(folder.path);
            } else {
              selected.remove(folder.path);
            }
          },
        );
      }

      ctx.spaceVertical(px: 8);
      ctx.buttonRow([
        ButtonSpec(
          S.save,
          () => ctx.close({...selected, ...unlisted}),
          variant: ButtonVariant.primary,
        ),
        ButtonSpec(S.cancel, () => ctx.close(null)),
      ]);
    },
  );
}
