// ignore_for_file: deprecated_member_use
import 'dart:convert';
import 'dart:js_util' as jsu;
import 'dart:typed_data';

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart'
    show ChunkedBlobIO, PluginDirManifest, PluginFileRef, boundedParallel;

import 'obsidian_settings_registry.dart';
import 'synced_dir_kind.dart';

export 'synced_dir_kind.dart';

/// Live progress of one blob-backed file transfer, for the sync panel's
/// active-transfers view.
typedef DirTransferReport = void Function({
  required String path,
  required bool upload,
  required int sentBytes,
  required int totalBytes,
  required bool done,
});

/// Moves blob-backed `.obsidian` directories — community plugins and themes —
/// between disk and the vault's blob bucket.
///
/// The settings CRDT layer only ever sees a [PluginDirManifest]: a few hundred
/// bytes of blob references. The bytes themselves never enter a state record;
/// they are chunked, encrypted and uploaded through [ChunkedBlobIO], the same
/// path notes use, into the same per-vault bucket. That sharing is what keeps
/// them safe from the server's orphan sweep, which builds its live set from
/// both keyspaces' records.
///
/// A directory is one atomic unit in both directions: a capture that cannot
/// read every required file produces nothing, and an apply that cannot fetch
/// every blob writes nothing. A half-applied install (new `main.js`, old
/// `manifest.json`) is exactly the state that breaks Obsidian's plugin updater,
/// so it must not be reachable even through a failure.
class BlobDirSync {
  BlobDirSync({
    required AdapterHandle adapter,
    required ChunkedBlobIO? Function() blobIO,
    required this.isMobile,
    this.deviceLabel,
    void Function(String message)? log,
    Object? pluginsManagerRaw,
    DirTransferReport? onTransfer,
  })  : _adapter = adapter,
        _blobIO = blobIO,
        _log = log,
        _pluginsManagerRaw = pluginsManagerRaw,
        _onTransfer = onTransfer;

  static const configDir = '.obsidian';

  /// A single file above this is not synced. Nothing legitimate comes close —
  /// the largest community plugins ship a few MB of bundled JS, the largest
  /// themes a couple of MB of CSS — so this is a guard against a pathological
  /// or hostile record, not a policy knob. It also bounds what a peer holding
  /// the vault key can make this client assemble in memory.
  static const maxFileBytes = 32 * 1024 * 1024;

  final AdapterHandle _adapter;

  /// Rebuilt per call rather than held: the engine swaps its remote storage on
  /// reconnect and on a BYO-credentials change, and a captured instance would
  /// keep writing to the old one. Null means "no connection yet" — callers skip
  /// this cycle instead of failing.
  final ChunkedBlobIO? Function() _blobIO;

  /// Mobile devices skip plugins whose manifest declares `isDesktopOnly` —
  /// Obsidian could never load them there, so downloading them is pure waste.
  /// This is a local materialization choice: the CRDT state is untouched, so
  /// the desktop devices still converge normally.
  final bool isMobile;

  /// Human-readable name of this device, shown in the UI as "updated from …".
  final String? deviceLabel;

  final void Function(String message)? _log;

  /// Obsidian's `app.plugins` manager, used to cycle a plugin after its files
  /// change. Null in tests / when the host does not expose it.
  final Object? _pluginsManagerRaw;

  /// Reports transfer progress so these directories appear in the same
  /// active-transfers view as note content. Without it a first sync of a plugin
  /// set is minutes of complete silence.
  final DirTransferReport? _onTransfer;

  String dirPath(SyncedDirKind kind, String id) =>
      '$configDir/${kind.folder}/$id';

  String filePath(SyncedDirKind kind, String id, String fileName) =>
      '${dirPath(kind, id)}/$fileName';

  // -- local inventory ------------------------------------------------------

  /// Directory names of [kind] installed on this device, i.e. those holding a
  /// `manifest.json`. Our own plugin — under any id it has ever used — is
  /// excluded, as everywhere else.
  Future<List<String>> installedDirs(SyncedDirKind kind) async {
    final out = <String>[];
    try {
      final dir = '$configDir/${kind.folder}';
      if (!await _adapter.exists(dir)) return out;
      final listed = await _adapter.list(dir);
      for (final folder in listed.folders) {
        final id = folder.split('/').last;
        if (id.isEmpty) continue;
        if (kind == SyncedDirKind.plugin &&
            ObsidianSettingsRegistry.selfPluginIds.contains(id)) {
          continue;
        }
        if (await _statOrNull(filePath(kind, id, 'manifest.json')) == null) {
          continue;
        }
        out.add(id);
      }
    } catch (e) {
      _log?.call('${kind.folder} listing failed: $e');
    }
    out.sort();
    return out;
  }

  /// Whether this device has the directory's entry point on disk. Obsidian can
  /// only load what it can find.
  Future<bool> isInstalled(SyncedDirKind kind, String id) async =>
      await _statOrNull(filePath(kind, id, kind.entryFile)) != null;

  /// Bytes this directory's files occupy on this device. Stat-only — this is
  /// the number shown before the user opts in, so it must not read content.
  Future<int> localBytes(SyncedDirKind kind, String id) async {
    var total = 0;
    for (final name in kind.fileNames) {
      final st = await _statOrNull(filePath(kind, id, name));
      total += st?.size ?? 0;
    }
    return total;
  }

  /// What every installed directory of [kind] weighs on this device, together.
  Future<int> localTotalBytes(SyncedDirKind kind) async {
    var total = 0;
    for (final id in await installedDirs(kind)) {
      total += await localBytes(kind, id);
    }
    return total;
  }

  /// The version this device has installed, read from the directory's own
  /// `manifest.json`. Null when absent or unparseable.
  Future<String?> localVersion(SyncedDirKind kind, String id) async {
    final bytes = await _readOrNull(filePath(kind, id, 'manifest.json'));
    return bytes == null ? null : _parseObsidianManifest(bytes).version;
  }

  // -- local -> remote ------------------------------------------------------

  /// Cheap change token for a directory: the `mtime:size` of each file present.
  /// A scan compares this against the last synced signature and only reads and
  /// uploads when it moved, so the common "nothing changed" cycle costs a
  /// couple of stats and no bytes.
  ///
  /// Returns null when the directory holds no `manifest.json` — an incomplete
  /// or foreign folder that must not be captured.
  Future<String?> dirSignature(SyncedDirKind kind, String id) async {
    final parts = <String>[];
    var hasManifest = false;
    for (final name in kind.fileNames) {
      final st = await _statOrNull(filePath(kind, id, name));
      if (st == null) continue;
      if (name == 'manifest.json') hasManifest = true;
      parts.add('$name:${st.mtime}:${st.size ?? -1}');
    }
    if (!hasManifest) return null;
    return parts.join('|');
  }

  /// Reads the directory's files, uploads any bytes the server lacks, and
  /// returns the manifest describing the result — or null when the directory is
  /// not a usable install, a file is over [maxFileBytes], or the upload path is
  /// unavailable.
  ///
  /// [previous] is the currently merged manifest, used to carry the version
  /// trail forward so it accumulates across devices instead of resetting.
  Future<PluginDirManifest?> capture(
    SyncedDirKind kind,
    String id, {
    PluginDirManifest? previous,
  }) async {
    final io = _blobIO();
    if (io == null) {
      _log?.call('${kind.folder} capture skipped (no connection): $id');
      return null;
    }

    final manifestBytes =
        await _readOrNull(filePath(kind, id, 'manifest.json'));
    if (manifestBytes == null) return null;
    final meta = _parseObsidianManifest(manifestBytes);

    final entryBytes = await _readOrNull(filePath(kind, id, kind.entryFile));
    if (entryBytes == null) {
      _log?.call('${kind.folder} capture skipped (no ${kind.entryFile}): $id');
      return null;
    }

    final sources = <String, Uint8List>{
      'manifest.json': manifestBytes,
      kind.entryFile: entryBytes,
    };
    // Anything else the kind declares is optional (a plugin's `styles.css`).
    for (final name in kind.fileNames) {
      if (sources.containsKey(name)) continue;
      final bytes = await _readOrNull(filePath(kind, id, name));
      if (bytes != null) sources[name] = bytes;
    }

    for (final entry in sources.entries) {
      if (entry.value.length > maxFileBytes) {
        _log?.call('${kind.folder} capture skipped (${entry.key} is '
            '${entry.value.length} B > $maxFileBytes): $id');
        return null;
      }
    }

    // Blobs the previous merged manifest already put on the server. An
    // unchanged file therefore uploads nothing, and a version bump only sends
    // the chunks that actually differ. Safe to trust: [previous] is the state
    // the server itself handed us, so its blobs exist by construction.
    final known = {...?previous?.liveBlobIds};
    final files = <String, PluginFileRef>{};
    // In parallel: a directory is at most three files, and uploading them one
    // after another made a plugin cost three round trips instead of one. What
    // this gives up is the chunk sharing a serial loop had — a later file could
    // reuse the chunks an earlier one had just uploaded. Between a manifest, a
    // bundled main.js and a stylesheet there is nothing to share, so the trade
    // is a round trip against a dedup that does not happen. Chunks the PREVIOUS
    // manifest put on the server are still skipped: `known` is seeded before
    // the pool starts and is only read from inside it.
    await boundedParallel(sources.entries.toList(), sources.length, (entry) async {
      final path = filePath(kind, id, entry.key);
      final total = entry.value.length;
      try {
        final res = await io.upload(
          entry.value,
          known,
          onProgress: (sent, _) => _report(path, true, sent, total, false),
        );
        files[entry.key] = PluginFileRef(
          blobRef: res.manifestHash,
          chunks: res.chunkHashes,
          size: total,
        );
      } finally {
        // Always closed, success or not, or the UI keeps a dead row forever.
        _report(path, true, total, total, true);
      }
    });

    return PluginDirManifest(
      pluginId: id,
      files: files,
      version: meta.version,
      desktopOnly: meta.desktopOnly,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      updatedBy: deviceLabel,
    ).withHistoryFrom(previous);
  }

  // -- remote -> local ------------------------------------------------------

  /// Writes [manifest]'s files to disk and, for a plugin, reloads it.
  ///
  /// Returns true when the directory changed. False means "nothing to do" or
  /// "deliberately skipped" (desktop-only plugin on mobile); a failure to fetch
  /// throws after writing nothing.
  Future<bool> apply(
    SyncedDirKind kind,
    String resourceId,
    PluginDirManifest manifest,
  ) async {
    // The directory name comes from the RESOURCE ID, never from the record's
    // own `pluginId`. The resource id has been through classify() — which
    // rejects `..` and our own plugin's directory — while record content is
    // authored by whichever device pushed it and has been through nothing.
    // Building a path out of it let a peer holding the vault key write
    // `../plugins/rhyolite-sync/main.js` and replace the running engine.
    final id = kind.idOf(resourceId);
    if (id == null) {
      _log?.call('refusing unusable resource id: $resourceId');
      return false;
    }
    // The same denylist classify() applies to resource ids, restated at the
    // boundary that actually touches disk.
    if (kind == SyncedDirKind.plugin &&
        ObsidianSettingsRegistry.selfPluginIds.contains(id)) {
      _log?.call('refusing to apply over our own plugin: $id');
      return false;
    }
    // Checked BEFORE the desktop-only skip: a removal applies everywhere, and
    // a device that once had it must drop it even if it would no longer
    // download it.
    if (manifest.deleted) return _removeLocally(kind, id);
    if (manifest.desktopOnly && isMobile) {
      _log?.call('${kind.folder} skipped on mobile (desktop-only): $id');
      return false;
    }
    final io = _blobIO();
    if (io == null) {
      _log?.call('${kind.folder} apply skipped (no connection): $id');
      return false;
    }

    final fetched = <String, Uint8List>{};
    final wanted = manifest.files.entries.where((entry) {
      // The parser accepts the union of every kind's file names, so a theme
      // record may carry `main.js`. Only what THIS kind declares reaches disk.
      if (kind.fileNames.contains(entry.key)) return true;
      _log?.call('${kind.folder} $id: ignoring foreign file ${entry.key}');
      return false;
    }).toList();
    for (final entry in wanted) {
      if (entry.value.size > maxFileBytes) {
        throw StateError('${kind.folder} file ${entry.key} of $id declares '
            '${entry.value.size} B, over the $maxFileBytes B cap');
      }
    }

    // What is already correct on disk is not downloaded again.
    //
    // A blob id is a pure function of the plain bytes and the vault key, so a
    // local copy can be checked against a ref without fetching anything. That
    // turns the disk into evidence instead of a thing to be overwritten: this
    // path is reached whenever the merged manifest differs from what the
    // settings store remembers, and "the store no longer remembers" is not the
    // same claim as "the content is not here". A purged row, a rebuilt local
    // database, a re-enabled category and a restore-from-server all produce
    // the first without the second, and each of them used to re-download an
    // intact plugin set — minutes of transfer to arrive at the bytes already
    // sitting there.
    //
    // Verification failure of any shape falls through to fetching. This may
    // never conclude "present" about content it has not hashed.
    final stale = <MapEntry<String, PluginFileRef>>[];
    for (final entry in wanted) {
      if (await _matchesOnDisk(io, kind, id, entry.key, entry.value)) continue;
      stale.add(entry);
    }
    if (stale.length < wanted.length) {
      _log?.call('${kind.folder} $id: ${wanted.length - stale.length} of '
          '${wanted.length} file(s) already current on disk');
    }

    // Fetch everything MISSING before touching disk. A partial write would
    // leave the install torn across two releases, which is worse than not
    // applying — and the files skipped above are already at the target
    // version, so writing only these still lands the directory whole.
    //
    // In parallel, for the same reason as the upload above: `boundedParallel`
    // rejects once a task throws, and the write loop below is not reached, so
    // a failed fetch cannot leave the install torn.
    await boundedParallel(stale, stale.length, (entry) async {
      final ref = entry.value;
      final path = filePath(kind, id, entry.key);
      final Uint8List? bytes;
      try {
        bytes = await io.download(
          ref.blobRef,
          onProgress: (got, _) => _report(path, false, got, ref.size, false),
        );
      } finally {
        _report(path, false, ref.size, ref.size, true);
      }
      if (bytes == null) {
        throw StateError('blob ${ref.blobRef} for $id/${entry.key} '
            'could not be fetched');
      }
      fetched[entry.key] = bytes;
    });

    final dir = dirPath(kind, id);
    await _ensureDir(dir);

    // `manifest.json` LAST. It carries the version Obsidian shows and compares,
    // so a crash mid-apply must never leave a manifest advertising a release
    // whose content did not land.
    final ordered = fetched.keys.toList()
      ..sort((a, b) => a == 'manifest.json'
          ? 1
          : b == 'manifest.json'
              ? -1
              : a.compareTo(b));
    var wrote = 0;
    for (final name in ordered) {
      final path = filePath(kind, id, name);
      final existing = await _readOrNull(path);
      if (existing != null && _bytesEqual(existing, fetched[name]!)) continue;
      await _adapter.writeBinary(path, fetched[name]!);
      wrote++;
    }

    // A release that dropped a file (most often a plugin's `styles.css`) must
    // drop it here too, or the stale copy keeps being applied. Bounded to the
    // kind's known names — never a directory sweep.
    var removed = 0;
    for (final name in kind.fileNames) {
      if (manifest.files.containsKey(name)) continue;
      final path = filePath(kind, id, name);
      if (await _statOrNull(path) == null) continue;
      try {
        await _adapter.remove(path);
        removed++;
      } catch (e) {
        _log?.call('${kind.folder} file remove failed: $path: $e');
      }
    }

    if (wrote == 0 && removed == 0) return false;
    _log?.call('${kind.folder} applied: $id ${manifest.version ?? "?"} '
        '($wrote written, $removed removed)');
    if (kind.reloadable) _reload(id);
    return true;
  }

  /// Whether the file already on disk IS the one [ref] names.
  ///
  /// Answers only from content: the bytes are read and hashed under the same
  /// scheme that produced [ref], so a stale mtime, a lost database row or a
  /// file some other tool rewrote cannot make this say yes. Anything it cannot
  /// establish — absent file, unreadable, hashing threw — is a no, and the
  /// caller downloads.
  Future<bool> _matchesOnDisk(
    ChunkedBlobIO io,
    SyncedDirKind kind,
    String id,
    String name,
    PluginFileRef ref,
  ) async {
    final path = filePath(kind, id, name);
    // Size first: it comes free with the stat, and a release that changed a
    // file almost always changed its length. Saves reading and chunking a
    // multi-MB bundle to learn what one number already said.
    final st = await _statOrNull(path);
    if (st == null) return false;
    final size = st.size;
    if (size != null && size != ref.size) return false;

    final bytes = await _readOrNull(path);
    if (bytes == null || bytes.length != ref.size) return false;
    try {
      return await io.blobRefOf(bytes) == ref.blobRef;
    } catch (e) {
      _log?.call('${kind.folder} $id: verify failed for $name, '
          'will download: $e');
      return false;
    }
  }

  /// Uninstalls a directory whose vault record says it is gone: stop it (if it
  /// is a plugin), delete the files we manage, then the directory itself.
  ///
  /// Bounded to the kind's names plus an `rmdir` that only succeeds on an empty
  /// directory — a plugin's own leftovers (databases, caches) are device-local,
  /// and blowing the tree away would delete data nobody asked us to touch.
  /// Returns whether anything was actually removed.
  Future<bool> _removeLocally(SyncedDirKind kind, String id) async {
    final dir = dirPath(kind, id);
    if (!await _dirExists(dir)) return false;

    if (kind.reloadable) _disable(id);

    var removed = 0;
    for (final name in kind.fileNames) {
      final path = filePath(kind, id, name);
      if (await _statOrNull(path) == null) continue;
      try {
        await _adapter.remove(path);
        removed++;
      } catch (e) {
        _log?.call('${kind.folder} file remove failed: $path: $e');
      }
    }
    try {
      await _adapter.rmdir(dir);
    } catch (e) {
      // Non-empty (it kept its own state) or held open — the content is gone
      // either way, which is what the removal was about.
      _log?.call('${kind.folder} dir not removed: $dir: $e');
    }
    _log?.call('${kind.folder} removed locally: $id ($removed files)');
    return removed > 0;
  }

  void _report(String path, bool upload, int sent, int total, bool done) {
    _onTransfer?.call(
      path: path,
      upload: upload,
      sentBytes: sent,
      totalBytes: total,
      done: done,
    );
  }

  Future<bool> _dirExists(String path) async {
    try {
      return await _adapter.exists(path);
    } catch (_) {
      return false;
    }
  }

  /// Stops a running plugin without re-enabling it.
  void _disable(String pluginId) {
    final plugins = _pluginsManagerRaw;
    if (plugins == null) return;
    try {
      jsu.callMethod<Object?>(plugins, 'disablePlugin', [pluginId]);
    } catch (e) {
      _log?.call('plugin disable failed: $pluginId: $e');
    }
  }

  /// Cycles a plugin so Obsidian picks up the files just written. Without this
  /// the running instance keeps the old code in memory until the app restarts.
  /// Best-effort: a plugin that refuses to disable is left to the reload
  /// prompt the config sync already raises.
  void _reload(String pluginId) {
    final plugins = _pluginsManagerRaw;
    if (plugins == null) return;
    try {
      final enabled = jsu.getProperty<Object?>(plugins, 'enabledPlugins');
      final isEnabled = enabled == null
          ? false
          : jsu.callMethod<bool>(enabled, 'has', [pluginId]);
      if (!isEnabled) return; // not loaded — nothing to cycle
      jsu.callMethod<Object?>(plugins, 'disablePlugin', [pluginId]);
      jsu.callMethod<Object?>(plugins, 'enablePlugin', [pluginId]);
      _log?.call('plugin reloaded: $pluginId');
    } catch (e) {
      _log?.call('plugin reload failed: $pluginId: $e');
    }
  }

  // -- helpers --------------------------------------------------------------

  Future<StatHandle?> _statOrNull(String path) async {
    try {
      return await _adapter.stat(path);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _readOrNull(String path) async {
    if (await _statOrNull(path) == null) return null;
    try {
      return await _adapter.readBinary(path);
    } catch (e) {
      _log?.call('read failed: $path: $e');
      return null;
    }
  }

  Future<void> _ensureDir(String dir) async {
    try {
      if (!await _adapter.exists(dir)) await _adapter.mkdir(dir);
    } catch (_) {
      // Races and already-exists are harmless.
    }
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The two fields we read out of a directory's own `manifest.json`.
class ObsidianPluginMeta {
  const ObsidianPluginMeta({this.version, this.desktopOnly = false});
  final String? version;
  final bool desktopOnly;
}

/// Parses `version` and `isDesktopOnly` out of a `manifest.json`. Unparseable
/// manifests yield empty metadata rather than failing the capture: the files
/// still sync, they just show no version.
ObsidianPluginMeta _parseObsidianManifest(Uint8List bytes) {
  try {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map) return const ObsidianPluginMeta();
    final version = json['version'];
    return ObsidianPluginMeta(
      version: version is String ? version : null,
      desktopOnly: json['isDesktopOnly'] == true,
    );
  } catch (_) {
    return const ObsidianPluginMeta();
  }
}
