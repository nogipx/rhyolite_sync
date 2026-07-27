import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'canonical_json.dart';

/// The files that constitute an Obsidian community-plugin install.
///
/// Deliberately a fixed, tiny set rather than a walk of `plugins/<id>/**`: a
/// blind walk picks up plugin caches, databases and downloaded assets, which
/// are device-local junk of unbounded size. These three are what an install
/// actually is (`styles.css` is optional — many plugins ship without one).
///
/// `data.json` is intentionally ABSENT: it syncs as its own field-merged
/// settings resource, and letting a whole-directory LWW overwrite it would
/// fight that merge.
const pluginCodeFileNames = <String>['manifest.json', 'main.js', 'styles.css'];

/// The files that constitute an Obsidian theme: its metadata and its stylesheet.
///
/// Themes ride the same blob-backed directory resource as plugins — they have
/// the same problem (a single CSS file routinely exceeds the size at which
/// inlining content into a settings record stops being viable) and the same
/// shape (a small, fixed, known file set inside one directory).
const themeFileNames = <String>['manifest.json', 'theme.css'];

/// Every file name a blob-backed directory may legitimately carry.
///
/// The parser validates against the union rather than against one kind's list:
/// which files a directory actually holds is decided by the capture side, and
/// the resource id already says whether it is a plugin or a theme. The union's
/// job is only to keep unrelated junk out of a manifest.
final Set<String> syncedDirFileNames = {
  ...pluginCodeFileNames,
  ...themeFileNames,
};

/// One file inside a synced plugin directory.
///
/// [blobRef] is the chunked-blob manifest hash (what `ChunkedBlobIO.download`
/// takes); [chunks] are the chunk ids it references, carried so the push can
/// declare them to the server's blob GC as live.
class PluginFileRef {
  const PluginFileRef({
    required this.blobRef,
    required this.chunks,
    required this.size,
  });

  final String blobRef;
  final List<String> chunks;
  final int size;

  static PluginFileRef? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final blobRef = json['b'];
    if (blobRef is! String || blobRef.isEmpty) return null;
    return PluginFileRef(
      blobRef: blobRef,
      chunks: ((json['c'] as List?) ?? const [])
          .whereType<String>()
          .toList(growable: false),
      size: (json['s'] as int?) ?? 0,
    );
  }

  Map<String, Object?> toJson() => {
        'b': blobRef,
        if (chunks.isNotEmpty) 'c': chunks,
        's': size,
      };
}

/// One entry of a plugin's version trail.
class PluginVersionEntry {
  const PluginVersionEntry({
    required this.version,
    required this.atMs,
    this.device,
  });

  final String version;
  final int atMs;
  final String? device;

  static PluginVersionEntry? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final version = json['v'];
    if (version is! String) return null;
    return PluginVersionEntry(
      version: version,
      atMs: (json['t'] as int?) ?? 0,
      device: json['d'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
        'v': version,
        't': atMs,
        if (device != null) 'd': device,
      };
}

/// The synced state of one plugin directory: which blobs hold its files, plus
/// the metadata the UI needs (version, who pushed it, the recent version
/// trail).
///
/// This is the *value* of a [SettingsCrdtKind.blobDir] resource — a
/// last-write-wins register over the whole directory. Per-file LWW would let a
/// vault end up with `main.js` from one release and `manifest.json` from
/// another, which is exactly the torn state that breaks Obsidian's plugin
/// updater. The directory is therefore one atomic unit.
class PluginDirManifest {
  const PluginDirManifest({
    required this.pluginId,
    required this.files,
    this.version,
    this.desktopOnly = false,
    this.updatedAtMs = 0,
    this.updatedBy,
    this.history = const [],
    this.deleted = false,
  });

  /// The vault no longer carries this plugin: every device that pulls this
  /// removes its copy.
  ///
  /// Modelled as a value of the register rather than a record tombstone, so it
  /// converges by the same last-write-wins rule as any other version — a device
  /// that reinstalls the plugin afterwards simply writes a newer value and wins.
  /// It also carries no files, so the previous version's blobs stop being
  /// referenced and become reclaimable the moment this lands.
  factory PluginDirManifest.removed({
    required String pluginId,
    String? version,
    int updatedAtMs = 0,
    String? updatedBy,
    List<PluginVersionEntry> history = const [],
  }) =>
      PluginDirManifest(
        pluginId: pluginId,
        files: const {},
        version: version,
        updatedAtMs: updatedAtMs,
        updatedBy: updatedBy,
        history: history,
        deleted: true,
      );

  static const schemaVersion = 1;

  /// How many past versions the trail keeps. Bounded so the record can't grow
  /// without limit — the config keyspace has no history table, so this trail is
  /// the only "what changed when" the UI can show.
  static const maxHistoryEntries = 8;

  final String pluginId;

  /// File name (`main.js`, …) -> blob reference. Only names from
  /// [pluginCodeFileNames] ever appear here.
  final Map<String, PluginFileRef> files;

  /// `version` from the plugin's `manifest.json`, for display only. It is NOT
  /// the merge ordering key: semver is not a total order across pre-releases,
  /// and ordering by it would make a deliberate downgrade unable to propagate.
  /// Ordering is the record HLC, like every other settings resource.
  final String? version;

  /// `isDesktopOnly` from the plugin's `manifest.json`. Lets a mobile device
  /// skip downloading a plugin it could never load — a local materialization
  /// choice that does not affect convergence.
  final bool desktopOnly;

  final int updatedAtMs;

  /// Human-readable label of the device that captured this version.
  final String? updatedBy;

  final List<PluginVersionEntry> history;

  /// This value REMOVES the plugin from the vault (see
  /// [PluginDirManifest.removed]). Carries no files.
  final bool deleted;

  /// Total plain size of the plugin's files.
  int get totalSize => files.values.fold(0, (a, f) => a + f.size);

  /// Every blob id this manifest keeps alive: the per-file chunked-blob
  /// manifests plus the chunks they reference. Declared on push so the
  /// server-side orphan sweep does not reclaim them.
  List<String> get liveBlobIds {
    final out = <String>{};
    for (final f in files.values) {
      out.add(f.blobRef);
      out.addAll(f.chunks);
    }
    return out.toList(growable: false);
  }

  /// Content address of the file set. Two devices that installed the same
  /// plugin release produce the SAME hash (blob ids are content-addressed under
  /// the shared vault key), so a capture can be suppressed instead of pushed —
  /// without this, every device auto-updating to the same release would push,
  /// self-notify and pull the others in a loop.
  ///
  /// Deliberately covers only the identity and the bytes: timestamp, device
  /// label and version trail are metadata and must not make content look
  /// changed.
  String get contentHash {
    final names = files.keys.toList()..sort();
    final payload = <String, Object?>{
      'id': pluginId,
      'f': {for (final n in names) n: files[n]!.blobRef},
      // Part of the identity, not metadata: a removal must never hash equal to
      // any live version, or the codec would suppress it as "no change".
      if (deleted) 'x': 1,
    };
    return sha256.convert(utf8.encode(canonicalJson(payload))).toString();
  }

  /// Returns this manifest with [previous]'s version trail carried forward, and
  /// [previous]'s version appended when it differs. Called by the capture path
  /// so the trail accumulates across devices instead of resetting on each push.
  PluginDirManifest withHistoryFrom(PluginDirManifest? previous) {
    if (previous == null) return this;
    final trail = <PluginVersionEntry>[...previous.history];
    final prevVersion = previous.version;
    if (prevVersion != null && prevVersion != version) {
      trail.add(PluginVersionEntry(
        version: prevVersion,
        atMs: previous.updatedAtMs,
        device: previous.updatedBy,
      ));
    }
    final trimmed = trail.length <= maxHistoryEntries
        ? trail
        : trail.sublist(trail.length - maxHistoryEntries);
    return PluginDirManifest(
      pluginId: pluginId,
      files: files,
      version: version,
      desktopOnly: desktopOnly,
      updatedAtMs: updatedAtMs,
      updatedBy: updatedBy,
      history: trimmed,
      deleted: deleted,
    );
  }

  /// A directory name that is safe to use as ONE path segment.
  ///
  /// The id travels inside a record authored by whichever device pushed it, so
  /// it is untrusted input on the receiving side. Rejecting the dangerous
  /// shapes here is defence in depth — the consumer derives its path from the
  /// resource id instead — but a manifest whose id could not name a directory
  /// is malformed regardless, so refusing it outright costs nothing.
  static final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  static PluginDirManifest? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final pluginId = json['id'];
    if (pluginId is! String || !_safeId.hasMatch(pluginId)) return null;
    final rawFiles = json['f'];
    if (rawFiles is! Map) return null;
    final files = <String, PluginFileRef>{};
    rawFiles.forEach((name, value) {
      final key = name.toString();
      if (!syncedDirFileNames.contains(key)) return;
      final ref = PluginFileRef.tryFromJson(value);
      if (ref != null) files[key] = ref;
    });
    final deleted = json['del'] == true;
    // A live manifest with no usable file is malformed and must not replace a
    // working install; a removal legitimately has none.
    if (files.isEmpty && !deleted) return null;
    return PluginDirManifest(
      pluginId: pluginId,
      files: files,
      deleted: deleted,
      version: json['ver'] as String?,
      desktopOnly: json['do'] == true,
      updatedAtMs: (json['ts'] as int?) ?? 0,
      updatedBy: json['by'] as String?,
      history: ((json['log'] as List?) ?? const [])
          .map(PluginVersionEntry.tryFromJson)
          .whereType<PluginVersionEntry>()
          .toList(growable: false),
    );
  }

  /// Parses a manifest from the bytes a [SettingsCrdtKind.blobDir] resource
  /// renders to. Returns null for anything unparseable.
  static PluginDirManifest? tryParse(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    try {
      return tryFromJson(jsonDecode(utf8.decode(bytes)));
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> toJson() {
    final names = files.keys.toList()..sort();
    return <String, Object?>{
      'v': schemaVersion,
      'id': pluginId,
      'f': {for (final n in names) n: files[n]!.toJson()},
      if (deleted) 'del': true,
      if (version != null) 'ver': version,
      if (desktopOnly) 'do': true,
      'ts': updatedAtMs,
      if (updatedBy != null) 'by': updatedBy,
      if (history.isNotEmpty) 'log': history.map((e) => e.toJson()).toList(),
    };
  }

  Uint8List toBytes() => canonicalJsonBytes(toJson());
}
