/// Paths the engine never syncs, whatever the user's filters say.
///
/// One entry so far: the diagnostic report. It is written into the vault
/// because that is the only place Obsidian will show a user a file they can
/// share — and having been written there, it would otherwise upload, cost
/// quota, and land on every other device, none of which anyone wants. The
/// alternative was asking each user to add an exclusion by hand, which is a
/// setting to get wrong in exchange for nothing.
///
/// The suffix is compound (`.rhyolite-log.md`) rather than a plain extension
/// for two reasons: it still ends in `.md`, so Obsidian lists it, previews it
/// and offers to share it like any note; and the per-device extension filter
/// keys on the LAST extension, so `md` could not express this without
/// excluding every note in the vault.
///
/// Checked at every admission site, alongside the user's own filters. That
/// consistency is the invariant: "restore" and "reconcile" and "startup scan"
/// must all agree about what is in scope, or one of them resurrects what
/// another declined.
library;

/// The marker that says a file is ours.
///
/// A marker rather than a list of whole suffixes, because a list is tied to
/// whatever the artifact happens to look like today. `.rhyolite-log.md` was
/// listed while the report was markdown; when a compressed form was tried and
/// then dropped, `.rhyolite-log.gz` quietly stopped being covered — the rule
/// had silently narrowed to the one format still in use. Matching the marker
/// means the format can change and the guarantee cannot lapse behind it.
const kNeverSyncedMarker = '.rhyolite-log';

/// Whether [relPath] is one of ours and must stay on the device that made it.
///
/// True when the file name carries [kNeverSyncedMarker] in extension position:
/// the marker, then any number of ordinary extensions. So
/// `report.rhyolite-log.md`, `.rhyolite-log.gz` and a bare `.rhyolite-log` all
/// match, while a note the user happened to call
/// `about .rhyolite-log.md files.md` does not — what follows the marker there
/// is prose, not an extension. Erring toward the user's file syncing is
/// deliberate: refusing to sync a real note is a failure they cannot diagnose.
///
/// Case-insensitive. Obsidian will happily create `.MD` on a case-insensitive
/// filesystem, and a file that escaped the rule that way would sync silently.
bool isNeverSynced(String relPath) {
  if (relPath.isEmpty) return false;
  final name = relPath.split('/').last.toLowerCase();
  final at = name.indexOf(kNeverSyncedMarker);
  if (at < 0) return false;

  final rest = name.substring(at + kNeverSyncedMarker.length);
  if (rest.isEmpty) return true; // the marker is the whole ending
  if (!rest.startsWith('.')) return false;

  // Everything after the marker must be plain `.ext` segments. The leading dot
  // is dropped first: splitting `.md` on `.` yields an empty leading part.
  for (final part in rest.substring(1).split('.')) {
    if (part.isEmpty) return false; // a stray or doubled dot
    if (!_isPlainExtension(part)) return false;
  }
  return true;
}

bool _isPlainExtension(String part) {
  if (part.length > 12) return false;
  for (var i = 0; i < part.length; i++) {
    final c = part.codeUnitAt(i);
    final ok = (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39);
    if (!ok) return false;
  }
  return true;
}
