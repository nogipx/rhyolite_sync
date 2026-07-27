import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart' show canonicalJsonBytes;

/// Splitting `community-plugins.json` into what may be written to disk now and
/// what must wait.
///
/// The three parts of a plugin install travel independently: the enabled list
/// is a few bytes and lands first, the code is megabytes and lands last.
/// Writing the list verbatim makes Obsidian try to enable a plugin that is not
/// on disk yet.
///
/// Only ids whose code the vault is actually going to deliver are held back.
/// An id the vault has no code record for belongs to a plugin the user
/// installs themselves — withholding that one would break what works today.
({List<String> keep, Set<String> withheld}) partitionEnabledList(
  Iterable<String> ids, {
  required bool Function(String id) vaultHasCode,
  required bool Function(String id) installedHere,
}) {
  final keep = <String>[];
  final withheld = <String>{};
  for (final id in ids) {
    if (id.isEmpty) continue;
    if (vaultHasCode(id) && !installedHere(id)) {
      withheld.add(id);
      continue;
    }
    keep.add(id);
  }
  return (keep: keep..sort(), withheld: withheld);
}

/// Parses an enabled-list file into ids. Returns null when the bytes are not a
/// JSON array — callers then leave the file alone rather than guessing.
List<String>? parseEnabledList(Uint8List bytes) {
  try {
    final parsed = jsonDecode(utf8.decode(bytes));
    if (parsed is! List) return null;
    return parsed
        .map((e) => e?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  } catch (_) {
    return null;
  }
}

/// Puts ids this device has no standing to remove back into a freshly-read
/// enabled list, before it is diffed into the CRDT.
///
/// Two sources feed [withheld], and both are cases where the id's absence from
/// the local file says nothing about what the user wants:
///
///  - plugins whose code has not landed here yet, which we shortened the file
///    ourselves to avoid Obsidian trying to load what is not on disk. Without
///    restoring them, any local toggle in that window reads our own edit as
///    the user's intent and removes those plugins everywhere.
///  - plugins the platform cannot run at all. A desktop-only plugin is dropped
///    from the list by Obsidian on mobile as a matter of course; propagating
///    that turns the phone into a device that silently disables desktop
///    plugins for every other device.
Uint8List restoreWithheld(Uint8List diskBytes, Set<String> withheld) {
  if (withheld.isEmpty) return diskBytes;
  final ids = parseEnabledList(diskBytes);
  if (ids == null) return diskBytes;
  return canonicalJsonBytes({...ids, ...withheld}.toList()..sort());
}
