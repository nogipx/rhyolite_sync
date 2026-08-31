## [3.16.1] - 2026-08-31

**An interrupted first sync keeps what it already uploaded.**
Files are recorded as each batch completes, so a sync that stops part-way
resumes from there instead of beginning the vault again. A large vault now
finishes across as many sessions as it needs.

**A vault owned by another account is reported instead of retried.** Sync stops
and says so, rather than repeating a sign-in that cannot change the answer.

### Bug Fixes

- not owning a vault stops sync instead of looping on refresh (obsidian)
- a start superseded during the connect stops there (core)
- a disposed transfer hub stops spraying unhandled errors (core)
- a failed first sync keeps the files it already uploaded (core)

### Other

- bump plugin to 3.16.1 (obsidian)

## [3.16.0] - 2026-08-31

**A bug report reaches support in one press.**
It carries the plugin version, vault statistics and this device's recent logs,
and comes back with a short number to quote. Note and folder names are replaced
with pseudonyms before anything leaves the device, and nothing you wrote in a
note is included. A copy stays in your vault.

**Sync makes fewer round trips.** Notes and attachments transfer in batches
rather than one exchange each, and a large transfer names the file it is
moving. Notes no longer keep a second copy in the local cache, and a launch
sends only what the server does not already have.

### Features

- raise the report cap to a size that should never be reached (account)
- send the report to support instead of asking for a file (obsidian)
- a contract for handing a diagnostic report to support (account)
- the report is an archive of the log files, not one document (obsidian)
- a diagnostic report is never synced, whatever the filters say (core)
- logs kept by segment, and a way to delete them (obsidian)
- a bug report the user can hand to support (obsidian)
- a log declares its paths and urls rather than spelling them out (core)
- a re-upload says which large file it is sending (core)
- a pull says which large file it is fetching (core)

### Bug Fixes

- the bug-report copy describes what the report now does (obsidian)
- a preempted pull keeps the batches it already applied (core)
- a restart no longer re-pushes every file this device authored (core)
- startup progress counts files again, not upload groups (core)
- a start that lands on a running start supersedes it, quietly (core)
- the small indicator stops going green mid-sync (obsidian)
- a pull asked for during startup no longer races the startup pull (core)
- the engine states when it is busy instead of leaving the UI to guess (core)
- the engine says it is connected when the socket is up, not 49s later (core)
- settings sync survives an engine restart it did not order (obsidian)
- an upload batch is not cancelled out from under a caller who rejoined (core)
- re-upload confirmation says what it does to the other devices (obsidian)
- restore from server no longer deletes files it cannot bring back (core)

### Refactoring

- a settings scan names what it skipped once, not every time (obsidian)

### Other

- bump plugin to 3.16.0 (obsidian)
- per-file data moves off the global meta row, lazily (core)
- a startup upload group costs two round trips, not two per file (core)
- overlap the prefetch groups again — batching alone was a regression (core)
- a pull batch costs two round trips, not two per file (core)
- budget the remaining loop yields; leave the pre-flight ones alone (core)
- yield on a time budget, not on an item count (core)
- the post-pull sweep costs what changed, not the whole vault (core)
- a pull sweeps the cache it just filled, instead of leaving it a day (core)
- pin the byte-stability a note's blob recovery now depends on (core)
- say why a note's blob needs no local copy, in the right order (core)
- a note's blob is never cached, instead of cached and swept later (core)
- a note's blob leaves the local cache, like an attachment's (core)
- a note's CRDT tree is stored in the compact encoding, not JSON (core)

## [3.15.5] - 2026-08-28

**A database error now tells you what actually went wrong.**
When something went wrong writing to the local database, the sync panel showed
"cannot rollback - no transaction is active" — a message about the cleanup, not
about the failure. The real cause (the disk being full, a storage error from the
device) was discarded on the way out. It is now the one you see.

Writes to the local database are also genuinely atomic for the first time. A
batch that failed part-way used to leave everything it had already written in
place; it now leaves the database as it found it.

### Bug Fixes

- a database error reports what actually went wrong (core)

### Other

- bump plugin to 3.15.5 (obsidian)

## [3.15.4] - 2026-08-28

**A plugin reload now leaves one plugin behind, and keeps its database.**
Connecting a vault, switching to self-host and resetting the local database all
reload the plugin. The instance being replaced now releases everything it held:
its entry in Settings, its sync indicator, and its handle on the local database.

Until now it released none of that. Each reload left an extra "Rhyolite Sync" in
Settings and an extra sync circle in the status bar, and the database handle it
kept locked the next instance out of durable storage — sync fell back to memory,
which is lost when Obsidian closes, so the vault downloaded again on every
launch. Toggling the plugin off and on, or reinstalling it, added another copy
rather than clearing them; fully quitting Obsidian was the only way back.

### Bug Fixes

- a plugin reload releases the instance it replaced (obsidian)
- a reload replaces the plugin instead of adding a second copy (obsidian)

### Other

- bump plugin to 3.15.4 (obsidian)

## [3.15.3] - 2026-08-28

**The plugin now says when your subscription has ended.**
A plan that lapses puts your vault back on free-tier limits, and uploads above
the free storage quota stop going through. The sync panel and Settings now show
that, with the date and a way to renew — and give you a heads-up in the week
before a plan ends.

### Features

- say when a subscription has ended, where the effect is felt (obsidian)

### Other

- bump plugin to 3.15.3 (obsidian)

## [3.15.2] - 2026-08-28

**Plugin sync only transfers what you don't already have.**
Plugins installed on your device are recognised as current before anything is
fetched, so only genuine updates come down. Restoring settings from the server
on an up-to-date vault now takes about a second.

Plugin sync also holds steady on a slow connection: your plan is remembered
between sessions, so a momentary lookup failure no longer interrupts it.

### Bug Fixes

- a plugin already on disk is verified, not downloaded again (core)
- a plan lookup that times out no longer re-downloads every plugin (obsidian)

### Other

- bump plugin to 3.15.2 (obsidian)

## [3.15.1] - 2026-08-27

**Resume no longer takes a minute, and no longer looks like it did nothing.**
Pausing and then resuming could leave sync idle for over a minute, with the
panel still reading "Sync stopped" the whole time. The button looked broken,
and the natural next move — press it again, or restart Obsidian — was the one
that helped least.

Two separate things caused that. Settings sync and note sync share one queue
that runs a single job at a time, and a settings download already under way
could not be interrupted: it kept the queue to itself until it gave up a
minute later, and the resume waited behind it. Pausing now cancels that
download outright. Separately, the panel had nothing to say between the click
and the engine actually starting, so it kept showing the state from before the
pause; it now says "Connecting..." from the moment you press it.

Both also apply when sync restarts on its own — after waking from sleep, or
when the connection is re-established.

### Bug Fixes

- resume says it is working instead of looking ignored (obsidian)
- a settings pull no longer holds the only scheduler slot through a pause (core)
- a paused sync stops settings work instead of letting it finish (core)
- a start nobody is waiting for gets out of the way (core)
- let a failed body read be caught like every other HTTP failure (core)

### Other

- bump plugin to 3.15.1 (obsidian)


## [3.15.0] - 2026-08-27

**Sync now tells you why it is not running.** Signed out, no vault chosen, a
passphrase never entered, a server address left blank — all four used to read
the same way: a grey "Sync stopped / Not connected", which looks exactly like
the service being down. There was nothing to press and nothing to go on.

Each of them now says what is missing and carries the button that fixes it:
Sign in, Connect vault, Unlock, Settings. Signing in from the panel is the
same one-click browser login the settings tab offers. If sync cannot start
when Obsidian opens, you get one notice saying so; the panel opens only when
you ask it to.

**The sync panel stopped disappearing after a restart.** If the panel was open
when Obsidian closed, reopening it often showed "This plugin is no longer
active" — and the plugin was missing from Settings for the first seconds too.
Obsidian rebuilds your layout as soon as plugins finish loading, and this one
was still waiting: on your click in a vault or passphrase dialog, or on a slow
network. It now claims its place in the sidebar before any of that, and both
dialogs open after startup instead of holding it up.

**A restart is no longer mistaken for a logout.** Settings could greet a
signed-in user with a Sign in button, and Connect vault would then do nothing
at all. Access passes are short-lived and get renewed in the background; the
plugin was reading "the pass expired a minute ago" as "this person is signed
out".

When a session really has ended, that is now acted on once, plainly: you are
signed out and asked to sign in. Previously nothing drew that conclusion, so
sync retried an account it could never reach — a panel stuck on "Connecting…",
and a startup that felt slow because every retry waited on the same doomed
renewal.

**Connecting a vault no longer re-downloads it on the next launch.** A vault
connected from Settings was stored under the previous session's name, so the
following start found nothing and pulled the entire vault down again. Nothing
was ever lost, and vaults connected before this update are unaffected.

**The plugin speaks your language on a phone.** A Russian Obsidian on iPhone
showed an English plugin. The language was only ever read from an explicit
choice in Obsidian's settings — and someone whose phone is already Russian
never makes that choice, because Obsidian follows the system. It now follows
the system too. Picking a language by hand still wins over everything.

**Version history opens for any file, not just the one in front of you.**
History is kept per path, so renaming a note starts a new history under the
new name — and the versions written under the old name had no way to be
opened at all, the same as for a note you deleted. There is now a list of
every path with history, with a filter and a marker on the ones that are gone.

**Questions and answers, one click away.** A help button in the sync panel and
at the top of Settings, open whether or not you are signed in. It opens a new
page covering what this sync does differently — empty notes, conflicts,
deletions, renames — since most "is it broken?" moments turn out to be
habits from another plugin.

### Features

- say why sync isn't running, and put the sign-in button in the panel (obsidian)
- open the history of any path, not just the open note (obsidian)
- reach the questions-and-answers page from the panel and settings (obsidian)

### Bug Fixes

- stop the sidebar panel from vanishing after an Obsidian restart (obsidian)
- a cold start is not a logout (obsidian)
- a refused refresh token now signs you out instead of retrying forever (obsidian)
- connecting a vault from settings no longer costs a full re-download (obsidian)
- follow Obsidian's language on a phone, not only an explicit choice (obsidian)

### Other

- bump plugin to 3.15.0 (obsidian)


## [3.14.2] - 2026-08-22

**Properties with an emoji stopped breaking.** A note whose `status` or
`priority` holds an emoji could come back with the following line glued onto
it and an unrenderable box where the emoji had been:

```
priority: 🇦?category:
  - "[[work]]"
```

3.14.1 fixed one cause of scrambled properties. This was a second, separate
one, which is why it could still happen after updating — and it is the reason
the damage always landed on an emoji rather than anywhere else.

Editing text stores the change by position. Emoji are counted as one character
almost everywhere, but as two in the format the comparison step works in, and
two emoji that look unrelated often share their first half — the coloured
squares do, the letter symbols do. When a change fell exactly there, the
position came out one off: the newline after the emoji was removed instead of
the emoji itself, and half a character was stored in its place.

Nothing needs to be done differently; edits at emoji are now counted the way
the rest of the note is. Notes already damaged stay as they are, and the
version from before the damage is in the file's history.

### Bug Fixes

- an edit next to an emoji no longer removes the following line break and
  stores a broken character (core)

### Other

- bump plugin to 3.14.2 (obsidian)


## [3.14.1] - 2026-08-21

**Properties no longer come back scrambled.** Change the same property on two
devices — a date, a status, anything Templater or the Linter rewrites on every
save — and the two values could be merged letter by letter instead of one of
them winning. `category` came back as `catgeory`, a timestamp as
`2026-08-121T11:23:01`. It took one device's copy of the note being in an
older form for this to happen, which is why it found the vaults that had
already had trouble once.

Properties now merge one key at a time whatever form the other device's copy
is in, and "Repair sync state" no longer causes it — it used to strip the
typed properties from every note in the vault as it went. Notes already
scrambled stay that way; the version from before the merge is in the file's
history.

**A vault you already had on a new device is no longer replaced.** Install
Rhyolite on a machine that already holds a copy of the vault, and any note
whose content differed was overwritten by the server's version on the first
sync, with nothing left to recover it from. Both versions are now kept and
merged.

**Settings and plugins sync faster.** Every settings file and every plugin
used to go up on its own — one request each, and a plugin's files one after
another — so the wait grew with how many things you had rather than with how
much had actually changed. A scan now sends everything it found in a single
request, and a plugin's files transfer together. The difference shows where it
was worst: the first sync on a new device, turning plugin sync back on, and
"Re-upload from this device".

**An emptied list property keeps its type.** Clear a list — `aliases`,
`tags`, `category` — and letting Obsidian rewrite the note turned the property
from a list into plain text, so it stopped behaving like a list everywhere
else.

### Bug Fixes

- properties merge per key even when the other device's copy carries no typed
  frontmatter, instead of blending both values character by character (core)
- "Repair sync state" keeps typed properties instead of stripping them from
  every note (core)
- a first sync no longer overwrites a note the device already had and had
  never synced (core)
- an emptied list property is no longer silently turned into text (core)

### Other

- bump plugin to 3.14.1 (obsidian)


## [3.14.0] - 2026-08-08

**Stray "Untitled" notes no longer appear on your other devices.** Creating a
note and naming it is two steps — Obsidian makes it as "Untitled", you type
the name — and if the first step reached your storage before the second, the
throwaway name was left behind on every other device with no way to notice.
The upload had to still be running when you renamed, so this hit hardest
where uploads are slowest: your own S3 or WebDAV, mobile connections, large
notes. Existing strays clear themselves the next time the name is reused.

**Rhyolite now asks about files that disappeared while it was off.** Delete
something with sync paused, or with Obsidian closed, and nothing was
watching: the deletion never reached your other devices, and worse, it lay in
wait — the moment another device edited that file, the two collided and the
file came back. The sync panel now lists these and asks, with "Delete on all
devices" and "Keep them".

It asks rather than decides, and that is deliberate. A vault that failed to
mount looks exactly like a folder you emptied, and there is no way to tell
them apart from here — so the wrong guess would delete your notes everywhere.
Only files this device actually held are listed; anything it simply never
downloaded, or that your folder filter excludes, is not a candidate.

**Faster uploads to your own storage.** A directory check meant for WebDAV was
being repeated before every upload, and on a remote backend the round trip is
most of the cost. Measured on a real vault, upload times stopped climbing —
they had been growing edit over edit, up to nineteen seconds for a short note.

### Bug Fixes

- a file removed while its upload was still running is no longer published
  under the old name (core)

### Other

- bump plugin to 3.14.0 (obsidian)


## [3.13.3] - 2026-08-08

Fixes a way the copy kept of a losing version could be discarded too early.

When the same attachment is changed on two devices at once, Rhyolite keeps
both: the newer one stays in place and the other is saved beside it as a
conflict copy. Since 3.13.0 an attachment already present in your vault is
no longer also held inside the plugin — and while a file was in that
unresolved state, that rule was being applied to *every* version of it,
including the one not on disk. The version that lost could lose its local
copy before it had been written out.

Now nothing belonging to a file in conflict is dropped until the conflict is
resolved. Worth updating if you edit attachments on more than one device.

### Other

- bump plugin to 3.13.3 (obsidian)


## [3.13.2] - 2026-08-08

The "Choose folders…" buttons are gone; the folder filters are typed in
directly, as the file-type list already was.

They were aimed at the wrong half of the problem. What made folder filtering
tedious elsewhere is having to name every folder you do *not* want — and
naming the one or two you *do* was never the hard part. Meanwhile the picker
listed only folders present on this device, which meant it omitted exactly
the ones you had excluded earlier: you could narrow the filter through it and
never widen it again.

Anything already chosen keeps working. Folder names are matched ignoring
case, and stray slashes or spaces around them do not matter.

### Other

- bump plugin to 3.13.2 (obsidian)


## [3.13.1] - 2026-08-08

The Local database card that 3.13.0 added to Storage overview is gone again.
It reported what the plugin's file cache weighs, and that figure turned out
not to be comparable to anything else on the screen: your plugin set counts
in it but not in the vault size beside it, and a note appears in one as its
text and in the other as the editing history that merges it. There was also
nothing to do about the number — that storage is cleaned automatically. A
figure nobody can read or act on is worse than no figure.

What 3.13.0 actually changed about disk use is still in place: an attachment
is no longer kept twice, once in your vault and once inside the plugin. Only
the counter went away.

### Bug Fixes

- a file saved by a newer version of Rhyolite is now listed under "Needs a
  newer version" instead of being retried silently on every sync, so a note
  that never arrives says why (core)
- that notice now says what to do about it, rather than leaving you to infer
  it (obsidian)

### Other

- bump plugin to 3.13.1 (obsidian)


## [3.13.0] - 2026-08-07

Choose which folders this device syncs. The only filter so far was by file
type, so putting one folder on a phone meant naming every folder you did not
want. Now you name the ones you do — from a picker that lists your vault's
folders with their file counts, or by typing them — and you can punch a hole
in that: sync `Work`, skip `Work/scratch`.

The filter belongs to the device, not the vault. Nothing about it reaches the
server or your other devices, and leaving a folder out is not a delete — those
files stay on disk, stay on the server, and keep syncing everywhere else. Add
a folder back and its files arrive on the next sync.

Attachments no longer take up twice the space. Each one was kept twice on the
device: once as the file in your vault, once inside the plugin's own database.
The second copy is now dropped once the first is in place, so a vault that is
mostly attachments roughly halves what the plugin occupies. Notes keep theirs,
because what is stored for a note is its editing history — the thing that makes
conflict-free merging possible in the first place. Storage overview has a new
Local database card showing the split.

Settings say who they apply to. The file-type and folder filters are yours
alone; the "sync as whole files" list is shared with every device you sync.
Those sat under one heading with nothing to tell them apart, and now sit under
two that say which is which. The file-type list moved to an explicit Save
along the way, since applying either filter restarts sync.

### Features

- sync only the folders you choose on this device, with an optional list of
  folders to skip inside them (obsidian)
- see what the plugin itself occupies on this device, split between notes and
  attachments, in Storage overview (obsidian)
- reclaim unreferenced files from your own S3 or WebDAV storage: your device
  lists the bucket, the server decides what is safe to remove (core)
- restore a file the server has lost from the copy already in your vault, not
  only from the plugin's cache (core)

### Bug Fixes

- a vault on your own storage no longer reports itself as managed after a
  restart, and no longer applies the managed plan's per-file size limit to
  storage that plan does not govern (obsidian)
- WebDAV: recreate the vault folder and retry when the server reports it
  missing, instead of failing the upload (core)
- stop re-sending a directory-creation request to S3, which has no directories
  (core)

### Other

- bump plugin to 3.13.0 (obsidian)


## [3.12.0] - 2026-08-04

Properties now merge as data. Until now a note was merged character by
character from end to end — right for prose, and blind to the one rule
frontmatter has: a property name may appear only once. Two devices adding the
same property at the same time each contributed their line, and the note ended
up carrying the key twice. That is valid YAML, so nothing looked broken, and
Properties, Dataview and every other reader quietly showed half the data.

Both devices need 3.12 for the new merge. Against a device still on an older
version the previous behaviour applies, and no property is lost either way.

### Features

- merge properties by name, so two devices adding the same one at the same time
  end up with a single property holding both values (core)
- leave a file alone when it was written by a newer version of Rhyolite, and
  list it in the sync panel, instead of writing its internal form into the note
  (core)

### Bug Fixes

- resolve a conflict between two independently created notes without
  duplicating the properties of either (core)

### Other

- reclaim deleted properties once every device has seen the deletion (core)
- bump plugin to 3.12.0 (obsidian)


## [3.11.0] - 2026-08-02

### Features

- report a lost sync database instead of restoring in silence (core)
- rebuild the sync panel around a real stylesheet (obsidian)

### Bug Fixes

- keep the sync database durable across an Android app kill (obsidian)

### Refactoring

- drop the 3-way text merge from the binary resolver (core)

### Other

- probe the local blob cache by id instead of listing it (core)
- bump plugin to 3.11.0 (obsidian)


## [3.10.1] - 2026-07-28

### Bug Fixes

- stop signing the user out when a refresh simply fails (obsidian)
- never discard a session over a refresh we got no answer to (account)

### Other

- bump plugin to 3.10.1 (obsidian)


## [3.10.0] - 2026-07-28

### Features

- lay the storage overview out, and open it from settings (obsidian)
- sync community plugins and themes, not just their settings (obsidian)
- blob-backed directory resources for settings sync (core)

### Bug Fixes

- tie the settings pull cursor to the scope it was advanced under (core)
- stop a re-enabled category re-uploading everything, and a phone disabling desktop plugins (obsidian)
- do not report a refused capture as captured (obsidian)
- shorten the size label on the overview tile (obsidian)
- never build a filesystem path from record content (obsidian)

### Other

- bump plugin to 3.10.0 (obsidian)


## [3.9.4] - 2026-07-26

### Bug Fixes

- say why a passphrase was rejected, in the user's language (core)

### Other

- bump plugin to 3.9.4 (obsidian)


## [3.9.3] - 2026-07-26

### Bug Fixes

- keep one device identity per install, not one per reset (core)

### Other

- bump plugin to 3.9.3 (obsidian)


## [3.9.2] - 2026-07-25

### Bug Fixes

- signing in again restores sync instead of looping on "session expired" (obsidian)
- tell "no token attached" apart from "session expired" (core)

### Other

- bump plugin to 3.9.2 (obsidian)
- drop unnecessary non-null assertions on S3BlobConfig.fromJson (CI analyze) (core)


## [3.9.1] - 2026-07-24

### Bug Fixes

- derive notes fileId through one keyed deriver (history reads were empty) (core)

### Other

- bump plugin to 3.9.1 (obsidian)


## [3.9.0] - 2026-07-23

### Features

- setting for which extensions sync as whole files (obsidian)
- sync structured formats (excalidraw, canvas) as whole files (core)

### Other

- bump plugin to 3.9.0 (obsidian)


## [3.8.0] - 2026-07-19

### Features

- recover a stuck/offline session without an Obsidian restart (obsidian)

### Other

- bump plugin to 3.8.0 (obsidian)


## [3.7.2] - 2026-07-19

### Bug Fixes

- drop the BYO secret from the discovery event (kind only) (core)
- refuse credentialed BYO requests over plaintext http to public hosts (core)
- reject cloud-metadata/loopback BYO storage endpoints (SSRF) (core)
- reject weak/dictionary passphrases, not just low charset entropy (core)
- confine remote paths to the vault + cap blob downloads (core)

### Other

- bump plugin to 3.7.2 (obsidian)
- drop stale Supabase anon-key comment (obsidian)


## [3.7.1] - 2026-07-19

### Bug Fixes

- a delete no longer resurrects a peer's stale on-disk copy (core)

### Other

- bump plugin to 3.7.1 (obsidian)
- correct restore-points comment — manual works for free, only auto-capture is Pro (obsidian)


## [3.7.0] - 2026-07-18

### Features

- open settings-sync section + per-vault key secret (obsidian)
- localize the tail — self-host, db recovery, status indicator, commands, payment activation (obsidian)
- localize the sync side-panel (status, stats, transfers, warnings) (obsidian)
- localize the settings tab (auth, vault, troubleshooting, subscription, self-host, external storage, diagnostics) (obsidian)
- localize file version history modal (obsidian)
- localize device management modal (obsidian)
- localize restore-point inspect/diff modal (obsidian)
- localize storage cleanup (history) modal (obsidian)
- localize storage overview modal (obsidian)
- localize storage reclaim (orphan + tombstone sweep) modal (obsidian)
- localize first-run flow (setup, passphrase, vault picker) (obsidian)
- i18n scaffold (typed AppStrings, en/ru, auto-locale from Obsidian) + localize backup modal (obsidian)
- reclaim stable tombstones in the storage cleanup sweep (dry-run + reclaim both) (obsidian)
- sweepStableTombstones RPC — reclaim deleted-file markers past causal stability (core)

### Bug Fixes

- skip syncing empty (0-byte) new files (core)

### Other

- bump plugin to 3.7.0 (obsidian)


## [3.6.0] - 2026-07-18

### Features

- in-place restore UI — explorer shows only changed files, per-file + bulk restore (obsidian)
- restore in place (not to a folder) + per-file restoreBackupFile (core)
- reuse the history git-style diff view for restore-point diffs (obsidian)
- storage overview — 'Restore points…' entry button + distinguish unavailable vs empty (obsidian)
- restore-point explorer — collapsible tree reusing Obsidian's native tree UI (tree-item/collapse-icon/setIcon), click any file for detail/diff (obsidian)
- restore point details — file tree + per-file text diff (obsidian)
- InspectBackupUseCase — per-file status vs current + engine inspectBackup/backupFileContent (core)
- backup modal — 'Create restore point now' + per-snapshot delete (obsidian)
- captureBackup + deleteBackup RPC + engine methods (core)
- storage overview shows restore points + 'Clear restore points' (obsidian)
- clearBackups RPC + engine.clearBackups() — release restore-point pin (core)
- 'Restore from backup' command + snapshot picker modal (obsidian)
- backup restore — RestoreBackupUseCase + engine listBackups/restoreBackup (core)

### Bug Fixes

- resolve concurrent versions by LWW in backup inspect/restore, not 'conflict' (core)
- materialise text (Fugue -> plain) for backup restore + diff (core)
- decide diff binary-ness by extension (FileTypeDetector), not strict utf8 decode (obsidian)

### Other

- bump plugin to 3.6.0 (obsidian)
- drop 'conflict' status from restore-point UI (resolved by LWW now) (obsidian)
- fileId is keyed HMAC-SHA256, not v5/SHA-1 (comment drift) (core)


## [3.5.4] - 2026-07-17

### Bug Fixes

- parallelize vault download (bounded blob-prefetch worker pool) (core)

### Other

- bump plugin to 3.5.4 (obsidian)


## [3.5.3] - 2026-07-17

### Bug Fixes

- key record ids with HMAC to close the path-enumeration oracle (core)

### Other

- bump plugin to 3.5.3 (obsidian)


## [3.5.2] - 2026-07-16

### Bug Fixes

- fix the "pending changes" indicator sticking after a rename or delete, and make sure renames/moves are always synced (core)


## [3.5.1] - 2026-07-16

### Bug Fixes

- stop a rare sync loop that could repeatedly re-send an unchanged file and hammer the server (core)


## [3.5.0] - 2026-07-15

### Features

- exclude file types from sync per device — list extensions to skip in Settings, and those files are neither uploaded nor downloaded on this device (other devices are unaffected) (obsidian)
- sync notes and small files before large attachments, so a slow upload can no longer hold up your note sync (core)


## [3.4.3] - 2026-07-15

### Features

- report plugin version + kind; show them in device management (obsidian)
- report client version + kind in device heads (core)

### Bug Fixes

- migrate BYO creds out of data.json + cap data-loss list (obsidian)
- fix edit-in-pull-window under-sync, reclaim deleted storage, keep BYO creds off local disk (core)

### Other

- bump plugin version to 3.4.3 (obsidian)
- edit-in-pull-window sync, tombstone GC, BYO config privacy (core)


## [3.4.2] - 2026-07-15

### Bug Fixes

- stop a stalled blob download from starving sync (core)

### Other

- bump plugin version to 3.4.2 (obsidian)
- cover pull preemption and download cancellation (core)


## [3.4.1] - 2026-07-15

### Features

- runtime-configurable remote log collector (obsidian)

### Bug Fixes

- position sync indicator lower on iOS (obsidian)
- a failed token refresh no longer escapes as an unhandled async error (account)

### Other

- bump plugin version to 3.4.1 (obsidian)


## [3.4.0] - 2026-07-14

### Vaults

- Deleting a vault now removes all of it from the server. Your notes were already cleared, but a vault's synced settings were left behind; a permanent delete now removes everything (obsidian, core).
- A vault you delete on one device now disappears from your other devices too. A connected device that sees the vault was deleted elsewhere disconnects and clears its local sync state — your note files on disk are left untouched (obsidian, core).


## [3.3.0] - 2026-07-13

### Settings sync

- Settings now sync the moment you switch away from Obsidian and when you close the settings dialog, not only when you return to it. A setting you change on one device reaches the others right away (obsidian).


## [3.2.0] - 2026-07-13

### Sign-in & account

- Sign in through your browser. Signing in now opens the website, you authenticate there, and the session is handed back to the plugin — the same single sign-in method used by the Telegram bot. Sign-in opens in your real browser rather than an in-app window (obsidian, account).
- Manage your subscription on the website. Subscribing and plan management open the account page already signed in as you, instead of a separate in-plugin payment screen (obsidian, account).

### Vaults

- Delete a vault from the vault picker. This permanently removes that vault's data from the server — files, history, and blobs — while leaving your local note files on disk untouched. Deletion requires typing the vault name to confirm (obsidian, core, account).
- The vault picker hides "Create vault" once you have reached your plan's vault limit (obsidian).

### Settings sync

- Settings no longer re-sync when a device merely reformats a JSON settings file. Plugin settings are now compared by their canonical content, so a different key order or indentation on another device no longer triggers a needless sync (core, obsidian).
- When settings arrive from another device, the plugin prompts you to reload so they take effect (obsidian).


## [3.1.2] - 2026-07-09

### Fixed

- Downloaded file data is now verified against its content hash before it is written, so a corrupted download or a damaged local cache can no longer silently corrupt a note — the affected file is re-fetched and repairs itself automatically (core).


## [3.1.1] - 2026-07-08

### Changed

- Updated the conflict-free text-sync engine with correctness fixes to the Fugue merge algorithm (convergent 0.6.0) (core).


## [3.1.0] - 2026-07-08

### Conflict-free text sync

- Text notes now merge with a true conflict-free algorithm (Fugue CRDT). When the same note is edited on two devices at the same time, both sets of edits are combined into one file — no conflict copies, no lost keystrokes (core).
- Large edits and full-file rewrites merge predictably: the diff is bounded by a deadline, so a big paste or bulk find-replace no longer stalls typing or drops characters (core).

### Storage management

- New storage overview shows how much space your synced vault and settings occupy, with a refresh control (obsidian).
- "Reclaim orphaned blobs" removes server data no longer referenced by any file (obsidian, core).
- Storage cleanup can now clear all synced history, not just history older than N days (obsidian, core).
- Cleanup and blob-delete failures are surfaced instead of failing silently (obsidian, core).

### Devices

- New device management view: list the devices syncing this vault and forget ones you no longer use (obsidian, core).

### File history

- History browser now shows a git-style line diff between versions, with a scrollable version list and back navigation (obsidian, core).
- Restoring an older version writes the real file content again (it could previously restore raw internal data) (core).

### Sync panel & transfers

- New docked sync side panel with a single unified pause/resume control (obsidian).
- Live per-file transfer progress and an active-transfers monitor, so large uploads and downloads show real movement (obsidian, core).
- Sync reconnects automatically when the network comes back (obsidian).

### Large files

- Files above your plan's per-file size limit are skipped cleanly before chunking instead of freezing the app, and are picked up automatically once they're within the limit (obsidian, core).
- Chunking is cooperative, so importing or editing very large files no longer freezes the interface (core).

### Reliability

- Engine startup is atomic — a failed start no longer leaves a half-running sync behind (core).
- A failed pull is retried instead of skipping that file forever, and sync no longer converges on data that isn't available yet (core).
- Every version is preserved in a three-or-more-way conflict (core).
- Settings sync no longer echoes its own writes, reformats unchanged files, or syncs device-specific workspace layout (obsidian).
- Remembered vault keys are verified on boot, and external-storage config is encrypted per vault (obsidian).

### Removed

- The in-plugin log viewer was removed (obsidian).


## [3.0.2] - 2026-07-06

### Fixed

- Filenames whose characters have more than one Unicode form — accented Latin or Cyrillic letters like «й»/«ё» — no longer sync as phantom duplicates between macOS/iOS and other platforms. Paths are normalized (NFC) so the same file keeps a single identity across devices instead of churning forever (core).


## [3.0.1] - 2026-07-06

### Changed

- Repository and container image URLs moved to the project's standalone account (obsidian, deploy).


## [2.7.0] - 2026-07-04

### Features

- keyed blob ids + persistent startup change-detection (core)

### Other

- bump version to 2.7.0 (obsidian)


## [2.6.0] - 2026-07-02

### Features

- map external_storage_unavailable rejection (obsidian)
- enable External Storage (BYO) for self-host (obsidian)
- gate External Storage to managed Pro tier (obsidian)
- self-host UX in settings tab (obsidian)
- self-host mode in the plugin (obsidian)
- IVaultDirectory seam (managed + self-host) (obsidian)
- vault registry contract (core)

### Bug Fixes

- bound self-host registry connect + reset vault on edition switch (obsidian)
- keep self-host token on config rebuild + fix offref crash (obsidian)
- apply self-host without manual reload + never prompt account (obsidian)

### Refactoring

- move shared auth surface into engine (core)

### Other

- bump version to 2.6.0 (obsidian)
- bump rpc_dart to d5a665e (core)


## [2.5.0] - 2026-06-22

### Features

- own the task scheduler, serialize engine restarts (obsidian)
- host-owned task scheduler behind ITaskScheduler (core)
- route settings sync through the engine background scheduler (obsidian)
- expose scheduleBackground hook for sibling subsystems (core)
- run GC + blob-verify as preemptible background tasks (core)
- add universal PriorityTaskScheduler (scheduler foundation) (core)

### Bug Fixes

- re-arm notify on resume when the socket is alive (obsidian)
- self-healing notify + explicit reissue hook (core)
- drain startup edits synchronously so notes sync before settings (core)
- capture file edits made during engine startup (core)
- keep both versions on divergent text conflict via CRDT line-union (core)

### Refactoring

- route engine sync work through PriorityTaskScheduler (core)
- decompose StateSyncEngine into testable collaborators (core)

### Other

- bump version to 2.5.0 (obsidian)
- pin that engine.stop() spares the host-owned scheduler (core)


## [2.4.0] - 2026-06-21

### Features

- re-upload / download buttons for settings sync (obsidian)
- notify-driven settings sync + indicator activity (obsidian)

### Bug Fixes

- reissue notify subscription on reconnect (core)
- persist session on every refresh to survive token rotation (account)
- hash settings-sync fileId to stop leaking .obsidian paths (core)

### Other

- bump version to 2.4.0 (obsidian)
- rename secret keys to rhyolite-vault-key / rhyolite-auth-token (obsidian)


## [2.3.0] - 2026-06-20

### Features

- verify blob durability with ack-check + bulkExists, auto-heal orphans (core)
- retry transient RPC failures with backoff (rate limit, unavailable) (core)
- VaultCipher to AES-256-GCM (WebCrypto/hardware-accelerated) (core)
- move settings-sync section to bottom, collapse behind <details> (obsidian)
- drop settings-sync polling timer, add manual sync command (obsidian)
- drop plugin-code sync entirely (installedPlugins category) (obsidian)
- .obsidian settings sync (opt-in, default off) (obsidian)
- settings sync CRDT engine for .obsidian config keyspace (core)

### Bug Fixes

- retry transient "First chunk must carry blobId" upload error (core)
- route text files through Fugue reconciler in StartupDiff (core)
- batch blob exists probe to avoid RPC call timeout on large vaults (core)
- drop runaway-bloated settings states on start (one-time heal) (core)
- skip large wholeFile settings (pure-Dart cipher freezes UI) (obsidian)
- relaunch settings sync after auth recovery restarts (obsidian)
- core-plugins.json is fieldMap, isolate per-resource push errors (obsidian)

### Other

- bump version to 2.3.0 (obsidian)
- lazy-decode settings states + purge orphan rows (fixes 81s open freeze) (core)
- timing logs for settings-sync startup phases (core)


## [2.2.1] - 2026-06-15

### Bug Fixes

- defer auto sign-in modal instead of stacking on resume (obsidian)

### Refactoring

- remove dead Migrate-blobs button from settings (obsidian)

### Other

- bump version to 2.2.1 (obsidian)


## [2.2.0] - 2026-06-15

### Features

- gzip blob compression decorator (core)
- blob transfer hub, parallel startup upload, disconnect wipe (core)
- include PlanCapabilities in SubscriptionDto (account)
- extend refresh TTL to 180d, retry once on unauthenticated (account)

### Other

- bump version to 2.2.0 (obsidian)


## [2.1.1] - 2026-06-12

### Other

- bump version to 2.1.1 (obsidian)


## [2.1.0] - 2026-06-12

### Bug Fixes

- wipe local blob cache on triggerRestoreFromServer too (core)
- wipe local blob cache on triggerReset (core)

### Refactoring

- replace PASETO v4.local with raw XChaCha20-Poly1305 in VaultCipher (core)

### Other

- bump version to 2.1.0 (obsidian)
- interleave blob prefetch with apply in _pull (batch=8) (core)


## [2.0.14] - 2026-06-10

### Features

- switch text reconcile to Sequence.applyOps batch (core)

### Other

- bump version to 2.0.14 (obsidian)


## [2.0.13] - 2026-06-07

### Features

- amber idle dot when there are unsynced local edits (obsidian)
- SyncPending event + incremental dirty tracking (core)

### Bug Fixes

- drop _seedPendingFromStore — caused permanent amber on start (core)
- mark pending immediately on text disk event (core)

### Other

- bump version to 2.0.13 (obsidian)
- hide progress counter when total <= 1 (obsidian)
- drop bare status labels, keep only progress counters (obsidian)
- unify push/pull dot color (both blue) (obsidian)


## [2.0.12] - 2026-06-07

_No client-facing changes._


## [2.0.11] - 2026-06-07

### Features

- resume-aware health check + push/pull color split (obsidian)
- healthCheck + RPC deadlines + pushing/pulling events (core)
- promo code input + live preview in payment modal (obsidian)
- expose discountCode in createPayment + previewDiscount client (account)

### Bug Fixes

- emit terminal SyncFilePulled so indicator can leave pulling (core)
- use awaiter-level timeout, not RpcContext deadline (core)

### Other

- bump version to 2.0.11 (obsidian)
- text edit debounce 5s -> 3s (core)


## [2.0.10] - 2026-06-06

_No client-facing changes._


## [2.0.9] - 2026-06-06

### Other

- bump version to 2.0.9 (obsidian)


## [2.0.8] - 2026-06-06

### Other

- bump version to 2.0.8 (obsidian)
- minLevel=warning in release builds + tidy CONTRIBUTING (obsidian)
- clarify CONTRIBUTING — main.js is a release artifact, not committed (obsidian)
- repo layout + README + CONTRIBUTING for plugin scorecard (obsidian)
- gate dev log collector behind RHYOLITE_DEBUG (obsidian)


## [2.0.7] - 2026-06-06

### Other

- bump version to 2.0.7 (obsidian)
- StartupDiff fast-path for empty + multi-chunk files (core)
- diagnostic log for StartupDiff pending files (core)


## [2.0.6] - 2026-06-06

### Other

- bump version to 2.0.6 (obsidian)
- lazy-decode FugueStore with LRU cache (core)
- fix applyTextSnapshot hang — checklines + cost cap (core)
- log sub-phases of text reconcile (seed/diff/upload) (core)
- per-fileId logs in apply loop + preReconcile begin/end (core)
- instrument _pull phases — getStates and prefetch timings (core)
- yield + log phases during StartupDiff scan (core)
- skip pre-reconcile when disk stat is unchanged (core)


## [2.0.5] - 2026-06-06

### Features

- cancellable sync — typing aborts in-flight reconcile + push (core)

### Bug Fixes

- expand text-file extensions to include .fountain and friends (core)

### Other

- bump version to 2.0.5 (obsidian)


## [2.0.4] - 2026-06-05

### Bug Fixes

- release editor-change handler on engine stop (obsidian)
- defer push until typing pauses (obsidian)

### Other

- bump version to 2.0.4 (obsidian)


## [2.0.3] - 2026-06-05

### Features

- surface Repair progress in the status indicator + truthful button copy (obsidian)
- real triggerRepair — reseed text files from disk and re-upload (core)

### Other

- bump version to 2.0.3 (obsidian)


## [2.0.2] - 2026-06-04

### Bug Fixes

- surface external-storage save errors, refresh settings on discovery (obsidian)
- discover external blob config before pull + require cipher in VaultMetaService (core)

### Other

- bump version to 2.0.2 (obsidian)


## [2.0.1] - 2026-06-04

### Bug Fixes

- defer engine.start, refresh metaStorage on auth, surface fatal rejections (obsidian)
- converge first-seed across devices, keep UI responsive, stop on fatal rejections (core)

### Other

- bump version to 2.0.1 (obsidian)


## [2.0.0] - 2026-06-04

### Features

- replace ribbon with floating indicator dot (obsidian)
- ribbon sync indicator + drop per-file pushed/pulled toasts (obsidian)
- TTL stale device frontiers out of causal-stability min (core)
- tombstone GC via causal stability frontier (Phase 5) (core)
- route text files through Fugue end-to-end (Phase 3.2) (core)
- FugueTextSync — plain-text snapshot → CRDT ops translator (core)
- plumb FugueStore + isText detector into StateSyncEngine (Phase 3.0) (core)
- FugueStore — per-file Sequence cache + persistence (Phase 2) (core)
- Sequence backed by HAMT IMap with O(log N) append/prepend (convergent)
- Phase C — Δ-state Sequence (Fugue list CRDT) (convergent)
- Phase B — Pruneable interface + OrSet causal-stability GC (convergent)
- Phase A — delta extraction, Mutator, DotSet for OrSet (convergent)
- Δ-state OrSet refactor, public Dot, JSON codecs (convergent)
- OCP extension points — events, use cases, resolver strategy (core)
- per-record poison isolation + schema version field (core)
- HLC self-stabilization defence (paper §4) (core)
- FileStateStore on MvRegister<FileState> (doc §4.4) (core)
- wire contract for Δ-state CRDT (doc §2/§5) (core)
- MvRegister.join + Δ-state CRDT property tests (core)
- BlobJanitor — user-triggered cleanup orchestration (core)
- local blob cache GC at engine startup (core)
- switch plugin to StateSyncEngine (obsidian)
- StateSyncEngine — pull/push/merge over the state-based protocol (core)
- FileState + FileStateStore for state-based sync (core)
- switch plugin to CrdtSyncEngine (obsidian)
- CrdtSyncEngine -- drop-in replacement for SyncEngine (core)
- sync_v2 integration layer with replicated_state (core)
- add comprehensive logging across sync pipeline (core)
- add vault storage usage API and display in plugin settings (core)
- introduce GraphBloc as central graph controller (core)
- add statusbar (obsidian)
- add IncomingUpdatesBloc and wire into SyncEngine lifecycle (core)

### Bug Fixes

- apply ribbon state via inline cssText, not CSS classes (obsidian)
- make ribbon indicator state changes actually visible (obsidian)
- seedFromPlainText O(1) via fromRaw instead of N appends (core)
- only record LCA at convergence points, not on local push (core)
- stop clobbering 3-way-merge base on local push (core)
- reconcile disk into local register before joining remote (core)
- resolve blobRef through ChunkedBlobIO in conflict paths (core)
- surface conflict-copy data loss as explicit SyncDataLoss event (core)
- parallelise HTTP blob upload/delete + progress log in StartupDiff (core)
- serialise FileStateStore persist + retry on version race (core)
- clean re-upload uploads blobs and wipes server first (core)
- poison op isolation and cursor persist order in CrdtSyncEngine (core)
- proper reset and restore in CrdtSyncEngine (core)
- use RemoteBlobStorage as default, WebDAV as override (core)
- reset local cursor when server cursor is behind (server data reset) (core)
- reuse endpoint for notify, add notify debug logging (core)
- persist server cursor, push only local ops (core)
- unstub external blob config save/clear in settings (obsidian)
- cast JSArray to List<bool> in conflict resolver for dart2js (core)
- add auth interceptor to notify endpoint in CrdtSyncEngine (core)
- skip duplicate ops in DataOperationStore.saveOps (core)
- wait for WebSocket online before calling pull (core)
- use WebSocket transport for CrdtSyncEngine (core)
- pull-first startup — defer reconciler until after server sync (core)
- skip missing blobs during restore instead of aborting (core)
- dual-mode HTTP client (Node.js on desktop, requestUrl on mobile) (obsidian)
- address 4 latent bugs in sync engine (core)
- prevent cleanBrokenFiles from deleting valid records with missing parents (core)
- remove file-exists-on-disk filter that blocked pull updates (core)
- skip discovery disk write for files with local unsynced edits (core)
- bloc-managed reconnect with exponential backoff (core)
- use discovery in _restoreFromServer instead of pull with empty cursor (core)
- use adapter.writeBinary fallback to fix FILE_NOTCREATED on mobile (obsidian)
- remove lock/release/renew synchronization mechanism (core)

### Refactoring

- unified SyncStatusIndicator (dot + progress label) (obsidian)
- migrate FileStateStore register encoding to convergent codecs (core)
- extract ISyncEngine interface (core)
- replace SqliteOperationStore with DataOperationStore (core)
- decouple DiskApplier from IGraphView (core)
- remove reset epoch mechanism from client (core)
- typed bus payloads and sealed SyncPhase states (core)
- extract workflows and sync_ops from SyncBloc (core)

### Other

- bump version to 2.0.0 (obsidian)
- comply with Community Plugins guidelines (obsidian)
- gate post-freeze diagnostic logs to only-when-interesting (core)
- compact wire format — SequenceCodec v3 + CBOR transport (core)
- debounce text-file reconciles to coalesce burst saves (core)
- instrument Fugue hot paths with timing logs (core)
- release 0.3.0 (convergent)
- release 0.2.0 (convergent)
- pubspec topics + runnable example (convergent)
- OSS-prep — README, LICENSE, CHANGELOG, SPDX, strict lints (convergent)
- Δ-state CRDT design document (core)
- CRDT audit and production-readiness checklist (core)
- add pull debug logging for empty response (core)
- add SyncBloc orchestration and LocalGC chunk cleanup tests (core)
- add integration tests for sync conflict scenarios (core)
- add regression tests for discovery skip on local unsynced edits (core)
- add tests for extracted sync_ops and workflows (core)
- skip ChangeRecord blob downloads in discovery phase of pull (core)
- reduce startup latency and memory usage (core)


## [1.2.1] - 2026-04-13

### Features

- storage quota + streaming blob upload/download (core)


## [1.2.0] - 2026-04-10

### Features

- add vault repair flow (obsidian)
- add server timestamp for deterministic leaf ordering (graph)
- add deleteNodes RPC to remove orphaned nodes from server (core)
- prune side branches on startup for all files (core)
- rewrite sync client as three BLoCs with in-process bus (core)

### Bug Fixes

- notify and retry when vault lock is released (core)
- add lease lock to sync flow (core)
- prune all file nodes from graph on startup, not just registry (core)
- push delete record before removing from file registry (core)
- two-pass apply to handle out-of-order records from server (graph)
- two-pass graph build to handle out-of-order records (core)
- in-process notify bus calls (core)
- handle missing blobs gracefully instead of null crash (core)

### Refactoring

- replace SyncEngine internals with BLoC facade (core)
- file change event merge files (core)
- make use cases pure — graph mutated only via apply/markSynced (graph)

### Other

- add token bucket rate limiter for outbound RPC calls (core)
- optimize large vault startup and sync (core)


## [1.1.1] - 2026-04-07

### Other

- add section about bundled sqlite3mc (obsidian)


## [1.1.0] - 2026-04-07

### Features

- inline sqlite3mc.wasm as base64 in main.js (obsidian)


## [1.0.0] - 2026-04-05

### Features

- add logging and message field to RestoreSubscriptionResponse (account)
- block disposable email providers on signup (account)
- normalize email on signup to prevent trial abuse via aliases (account)

### Refactoring

- replace print logs with RpcLogger, disable in production (obsidian)
- replace inline styles with CSS classes via bootstrapPlugin extraCss (obsidian)
- centralize collection names and improve restore subscription UX (account)
