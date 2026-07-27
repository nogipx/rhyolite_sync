/// Deciding which plugins the user actually uninstalled.
///
/// This is the one inference in plugin sync whose false positive is expensive:
/// wrongly concluding "uninstalled" deletes a plugin's code from every device,
/// while the opposite mistake only leaves a stale directory and some storage in
/// use. The rule is therefore deliberately over-constrained — five independent
/// conditions must agree, and a scan that would remove an implausible number of
/// plugins at once refuses outright.
///
/// Kept pure and free of IO so every branch is testable.
class PluginUninstallDecision {
  const PluginUninstallDecision({
    this.tombstone = const [],
    this.abortReason,
  });

  /// Plugin ids to mark removed in the vault.
  final List<String> tombstone;

  /// Set when the scan refused to conclude anything. Not an error — the normal
  /// answer whenever the evidence is incomplete.
  final String? abortReason;

  bool get aborted => abortReason != null;
}

/// The smallest batch that can still be refused as implausible. Below this,
/// removals always go through: uninstalling one or two plugins is ordinary.
const int kMinUninstallBatchToQuestion = 3;

PluginUninstallDecision detectPluginUninstalls({
  /// Directories of one kind the vault currently carries (live records,
  /// removals excluded).
  required Iterable<String> vaultPluginIds,

  /// Directory names found under `.obsidian/plugins`. NULL means the listing
  /// failed — the difference between "no plugins" and "could not look" is the
  /// whole safety of this, so it must never be flattened to an empty set.
  required Set<String>? installedDirs,

  /// Plugin ids the vault's enabled set holds, read from the MERGED CRDT
  /// value, never from the file on disk: our own withholding of not-yet-
  /// downloaded plugins makes the on-disk list say "absent" for plugins that
  /// are very much alive.
  ///
  /// This is what tells "the user uninstalled it" apart from "it has not been
  /// downloaded here yet". Only plugins have such a list — Obsidian records the
  /// SELECTED theme (`appearance.json`'s `cssTheme`), never the installed set —
  /// so themes run without it, on the strength of [hadItHere] instead.
  required Set<String>? enabledInVault,

  /// Whether a missing [enabledInVault] blocks the scan. True for plugins,
  /// where the list exists and its absence means we simply cannot see the
  /// corroborating signal; false for themes, where no such list exists at all
  /// and waiting for one would mean never concluding anything.
  bool requiresEnabledList = true,

  /// Whether THIS device ever had the plugin synced. A device that never
  /// materialized it — a fresh install, or a phone that skipped a desktop-only
  /// plugin — has no standing to declare it uninstalled.
  required bool Function(String pluginId) hadItHere,
}) {
  if (installedDirs == null) {
    return const PluginUninstallDecision(
      abortReason: 'plugins directory listing failed',
    );
  }
  if (requiresEnabledList && enabledInVault == null) {
    return const PluginUninstallDecision(
      abortReason: 'enabled-plugin list unavailable',
    );
  }

  final known = vaultPluginIds.toList();
  final tombstone = <String>[];
  for (final id in known) {
    if (installedDirs.contains(id)) continue; // still on disk here
    if (!hadItHere(id)) continue; // never ours to speak for
    // Vault still wants it enabled — so it is pending download, not removed.
    if (enabledInVault?.contains(id) ?? false) continue;
    tombstone.add(id);
  }
  if (tombstone.isEmpty) return const PluginUninstallDecision();

  // Backstop. A real uninstall spree is a handful of plugins; a bug, a broken
  // adapter or a half-mounted vault looks like "they all went away at once".
  final cap = known.length ~/ 2;
  final limit = cap < kMinUninstallBatchToQuestion
      ? kMinUninstallBatchToQuestion
      : cap;
  if (tombstone.length > limit) {
    return PluginUninstallDecision(
      abortReason: 'refusing to remove ${tombstone.length} of ${known.length} '
          'plugins at once',
    );
  }

  return PluginUninstallDecision(tombstone: tombstone..sort());
}
