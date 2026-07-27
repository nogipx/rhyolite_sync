import 'dart:convert';
import 'dart:typed_data';

import 'package:convergent/convergent.dart';

import 'canonical_json.dart';
import 'plugin_dir_manifest.dart';

/// How a settings resource (one `.obsidian` file or logical unit) is merged.
///
/// Each kind maps to a distinct convergent CRDT — this is the per-resource
/// merge granularity, mirroring how VS Code Settings Sync uses one
/// synchronizer per resource type:
///
/// - [fieldMap] — structured JSON whose leaves merge independently
///   (`app.json`, `appearance.json`, `hotkeys.json`). Concurrent edits to
///   *different* leaves both survive.
/// - [orSet] — an unordered set of strings (enabled plugins / snippets).
///   Concurrent enables on different devices both survive.
/// - [wholeFile] — an opaque blob merged last-write-wins (theme/snippet CSS,
///   whose exact bytes are meaningful and must not be normalized).
/// - [jsonWholeFile] — a JSON file whose schema we do not field-merge (plugin
///   `data.json`) but which we store in CANONICAL form (keys sorted, whitespace
///   normalized). Unlike [wholeFile] this ignores formatting + key order, so
///   Obsidian re-serializing a data.json (insertion order, platform-dependent
///   indentation) is a no-op instead of a phantom change.
/// - [blobDir] — a whole directory of binary files (a community plugin's
///   install) merged last-write-wins. Unlike every kind above, the CONTENT is
///   not in the record: the state holds a [PluginDirManifest] of chunked-blob
///   references and the bytes ride the shared vault blob bucket. The platform
///   layer materializes it; [ResourceCrdtCodec.renderState] yields the manifest
///   JSON, not file bytes.
enum SettingsCrdtKind { fieldMap, orSet, wholeFile, jsonWholeFile, blobDir }

/// Bytes <-> convergent CRDT state for one resource kind, plus the
/// snapshot-diffing that turns a freshly-read file into CRDT mutations.
///
/// `state` is the opaque convergent type for the kind; callers treat it as
/// `Object` and round-trip it through this codec.
abstract class ResourceCrdtCodec {
  const ResourceCrdtCodec();

  static ResourceCrdtCodec forKind(SettingsCrdtKind kind) {
    switch (kind) {
      case SettingsCrdtKind.fieldMap:
        return const FieldMapCodec();
      case SettingsCrdtKind.orSet:
        return const OrSetResourceCodec();
      case SettingsCrdtKind.wholeFile:
        return const WholeFileCodec();
      case SettingsCrdtKind.jsonWholeFile:
        return const JsonWholeFileCodec();
      case SettingsCrdtKind.blobDir:
        return const BlobDirCodec();
    }
  }

  /// Identity element (an empty CRDT state).
  Object emptyState();

  /// Decode the convergent state from a parsed JSON payload.
  Object decodeState(Object? json);

  /// Encode the convergent state to a JSON-compatible payload.
  Object? encodeState(Object state);

  /// Convergent join (commutative, associative, idempotent).
  Object joinStates(Object a, Object b);

  /// Derive CRDT mutations from a freshly-read file snapshot and apply them,
  /// returning the new state. `tick` mints a fresh HLC per mutation.
  Object diffApply(Object state, Uint8List newFileBytes, Hlc Function() tick);

  /// Render the CRDT state back to canonical file bytes.
  Uint8List renderState(Object state);

  /// Blob ids this state keeps alive, declared on push so the server-side
  /// orphan sweep does not reclaim them. Empty for every kind that inlines its
  /// content into the record (all of them but [BlobDirCodec]).
  List<String> liveBlobIds(Object state) => const [];
}

// ---------------------------------------------------------------------------
// fieldMap: CrdtMap<jsonPath, LwwRegister<leaf>>
// ---------------------------------------------------------------------------

/// Field-level LWW over a structured JSON object.
///
/// Each leaf is keyed by its JSON path (encoded as a JSON array string, so
/// keys containing dots or other separators are unambiguous). The leaf value
/// is a presence-tagged wrapper `{'p': 1, 'v': <value>}` (present) or
/// `{'p': 0}` (deleted) — a dedicated tombstone so a genuine JSON `null`
/// value is never confused with a removal.
class FieldMapCodec extends ResourceCrdtCodec {
  const FieldMapCodec();

  static final _codec = CrdtMapCodec<String, LwwRegister<Object?>>(
    keyCodec: const StringCodec(),
    valueCodec: LwwRegisterCodec<Object?>(const JsonCodec<Object?>()),
  );

  CrdtMap<String, LwwRegister<Object?>> _cast(Object s) =>
      s as CrdtMap<String, LwwRegister<Object?>>;

  @override
  Object emptyState() => CrdtMap<String, LwwRegister<Object?>>.empty();

  @override
  Object decodeState(Object? json) => _codec.decode(json);

  @override
  Object? encodeState(Object state) => _codec.encode(_cast(state));

  @override
  Object joinStates(Object a, Object b) => _cast(a).join(_cast(b));

  @override
  Object diffApply(Object state, Uint8List newFileBytes, Hlc Function() tick) {
    final map = _cast(state);
    final parsed = jsonDecode(utf8.decode(newFileBytes));
    final newLeaves = <String, Object?>{};
    _flatten(parsed, const [], newLeaves);

    final present = _presentLeaves(map);
    var result = map;

    // Upserts: new or changed leaves.
    newLeaves.forEach((key, value) {
      final changed = !present.containsKey(key) ||
          canonicalJson(present[key]) != canonicalJson(value);
      if (changed) {
        result = result.put(
          key,
          LwwRegister.deltaSet<Object?>(
            <String, Object?>{'p': 1, 'v': value},
            tick(),
            _ctxOf(map[key]),
          ),
        );
      }
    });

    // Deletions: keys present in CRDT but absent from the file snapshot.
    for (final key in present.keys) {
      if (!newLeaves.containsKey(key)) {
        result = result.put(
          key,
          LwwRegister.deltaSet<Object?>(
            <String, Object?>{'p': 0},
            tick(),
            _ctxOf(map[key]),
          ),
        );
      }
    }

    return result;
  }

  @override
  Uint8List renderState(Object state) {
    final leaves = _presentLeaves(_cast(state));
    final json = leaves.isEmpty ? <String, Object?>{} : _unflatten(leaves);
    return canonicalJsonBytes(json);
  }

  /// Current non-deleted leaves keyed by JSON path.
  Map<String, Object?> _presentLeaves(CrdtMap<String, LwwRegister<Object?>> m) {
    final out = <String, Object?>{};
    for (final key in m.keys) {
      final reg = m[key]!;
      if (reg.isEmpty) continue;
      final leaf = reg.value;
      if (leaf is Map && leaf['p'] == 1) out[key] = leaf['v'];
    }
    return out;
  }

  /// Causal context covering every HLC currently in [reg], so a new write
  /// dominates (drops) all prior local values of that key.
  CausalContext _ctxOf(LwwRegister<Object?>? reg) {
    var ctx = const CausalContext.empty();
    if (reg == null) return ctx;
    for (final tv in reg.inner.values) {
      ctx = ctx.advance(tv.hlc);
    }
    return ctx;
  }
}

/// Recursively flattens a JSON object into path-keyed leaves. Objects are
/// descended; scalars, `null` and arrays become leaves (whole-array LWW —
/// arrays are never element-merged here; sets are modelled as [orSet]).
void _flatten(Object? node, List<String> path, Map<String, Object?> out) {
  if (node is Map && node.isNotEmpty) {
    node.forEach((k, v) => _flatten(v, [...path, k.toString()], out));
  } else {
    out[jsonEncode(path)] = node;
  }
}

/// Rebuilds the nested JSON object from path-keyed leaves.
Object? _unflatten(Map<String, Object?> leaves) {
  final root = <String, Object?>{};
  for (final entry in leaves.entries) {
    final path = (jsonDecode(entry.key) as List).cast<String>();
    if (path.isEmpty) return entry.value; // top-level scalar (uncommon)
    var cursor = root;
    for (var i = 0; i < path.length - 1; i++) {
      cursor = cursor.putIfAbsent(path[i], () => <String, Object?>{})
          as Map<String, Object?>;
    }
    cursor[path.last] = entry.value;
  }
  return root;
}

// ---------------------------------------------------------------------------
// orSet: OrSet<String>
// ---------------------------------------------------------------------------

/// An add-wins set of strings, serialized as a sorted JSON array.
class OrSetResourceCodec extends ResourceCrdtCodec {
  const OrSetResourceCodec();

  static const _codec = OrSetCodec<String>(StringCodec());

  OrSet<String> _cast(Object s) => s as OrSet<String>;

  @override
  Object emptyState() => OrSet<String>.empty();

  @override
  Object decodeState(Object? json) => _codec.decode(json);

  @override
  Object? encodeState(Object state) => _codec.encode(_cast(state));

  @override
  Object joinStates(Object a, Object b) => _cast(a).join(_cast(b));

  @override
  Object diffApply(Object state, Uint8List newFileBytes, Hlc Function() tick) {
    final set = _cast(state);
    final parsed = jsonDecode(utf8.decode(newFileBytes));
    final newVals = (parsed as List).map((e) => e.toString()).toSet();

    var result = set;
    for (final v in newVals) {
      if (!set.contains(v)) result = result.add(v, tick());
    }
    for (final v in set.values) {
      if (!newVals.contains(v)) result = result.remove(v);
    }
    return result;
  }

  @override
  Uint8List renderState(Object state) {
    final values = _cast(state).values.toList()..sort();
    return canonicalJsonBytes(values);
  }
}

// ---------------------------------------------------------------------------
// wholeFile: LwwRegister<base64 bytes>
// ---------------------------------------------------------------------------

/// Opaque last-write-wins blob. Bytes are base64-encoded so the payload is
/// JSON-serializable.
class WholeFileCodec extends ResourceCrdtCodec {
  const WholeFileCodec();

  static final _codec = LwwRegisterCodec<Object?>(const JsonCodec<Object?>());

  LwwRegister<Object?> _cast(Object s) => s as LwwRegister<Object?>;

  @override
  Object emptyState() => LwwRegister<Object?>.empty();

  @override
  Object decodeState(Object? json) => _codec.decode(json);

  @override
  Object? encodeState(Object state) => _codec.encode(_cast(state));

  @override
  Object joinStates(Object a, Object b) => _cast(a).join(_cast(b));

  @override
  Object diffApply(Object state, Uint8List newFileBytes, Hlc Function() tick) {
    final reg = _cast(state);
    final encoded = base64Encode(newFileBytes);
    if (reg.value == encoded) return reg;
    var ctx = const CausalContext.empty();
    for (final tv in reg.inner.values) {
      ctx = ctx.advance(tv.hlc);
    }
    return reg.set(encoded, tick(), ctx);
  }

  @override
  Uint8List renderState(Object state) {
    final reg = _cast(state);
    final value = reg.value;
    if (reg.isEmpty || value == null) return Uint8List(0);
    return base64Decode(value as String);
  }
}

// ---------------------------------------------------------------------------
// jsonWholeFile: LwwRegister<canonical JSON text>
// ---------------------------------------------------------------------------

/// Last-write-wins over a JSON file's CANONICAL form (keys sorted recursively,
/// whitespace normalized). For JSON configs we don't field-merge (plugin
/// `data.json`). Storing the canonical text means two devices that produce the
/// same value in different formats (insertion order, indentation, platform)
/// converge on identical CRDT state — no format/reorder churn, and no LWW
/// flip-flop between equivalent renderings.
class JsonWholeFileCodec extends ResourceCrdtCodec {
  const JsonWholeFileCodec();

  static final _codec = LwwRegisterCodec<Object?>(const JsonCodec<Object?>());

  LwwRegister<Object?> _cast(Object s) => s as LwwRegister<Object?>;

  @override
  Object emptyState() => LwwRegister<Object?>.empty();

  @override
  Object decodeState(Object? json) => _codec.decode(json);

  @override
  Object? encodeState(Object state) => _codec.encode(_cast(state));

  @override
  Object joinStates(Object a, Object b) => _cast(a).join(_cast(b));

  @override
  Object diffApply(Object state, Uint8List newFileBytes, Hlc Function() tick) {
    final reg = _cast(state);
    final String canon;
    try {
      canon = canonicalJson(jsonDecode(utf8.decode(newFileBytes)));
    } catch (_) {
      // Not valid JSON (e.g. a transient half-write) — leave the CRDT untouched
      // rather than pushing garbage; a later scan of the valid file wins.
      return reg;
    }
    if (reg.value == canon) return reg;
    var ctx = const CausalContext.empty();
    for (final tv in reg.inner.values) {
      ctx = ctx.advance(tv.hlc);
    }
    return reg.set(canon, tick(), ctx);
  }

  @override
  Uint8List renderState(Object state) {
    final reg = _cast(state);
    final value = reg.value;
    if (reg.isEmpty || value is! String || value.isEmpty) return Uint8List(0);
    // Value is already canonical JSON text. Obsidian re-pretties it on its next
    // save; diskMatchesRendered (canonical compare) keeps us from overwriting an
    // equivalent on-disk copy in the meantime.
    return Uint8List.fromList(utf8.encode(value));
  }
}

// ---------------------------------------------------------------------------
// blobDir: LwwRegister<canonical PluginDirManifest JSON>
// ---------------------------------------------------------------------------

/// Last-write-wins over a whole directory of blob-backed files (see
/// [PluginDirManifest]).
///
/// The register holds the manifest as canonical JSON text — references only, a
/// few hundred bytes, so the record stays far below the server's record-size
/// cap no matter how large the plugin is. Bytes live in the vault's blob
/// bucket and are moved by the platform layer through `ChunkedBlobIO`.
///
/// The directory merges as ONE unit. Per-file registers would let a vault
/// converge on `main.js` from one release and `manifest.json` from another —
/// a torn install that breaks Obsidian's plugin updater.
class BlobDirCodec extends ResourceCrdtCodec {
  const BlobDirCodec();

  static final _codec = LwwRegisterCodec<Object?>(const JsonCodec<Object?>());

  LwwRegister<Object?> _cast(Object s) => s as LwwRegister<Object?>;

  @override
  Object emptyState() => LwwRegister<Object?>.empty();

  @override
  Object decodeState(Object? json) => _codec.decode(json);

  @override
  Object? encodeState(Object state) => _codec.encode(_cast(state));

  @override
  Object joinStates(Object a, Object b) => _cast(a).join(_cast(b));

  @override
  Object diffApply(Object state, Uint8List newFileBytes, Hlc Function() tick) {
    final reg = _cast(state);
    final incoming = PluginDirManifest.tryParse(newFileBytes);
    // Not a manifest (a caller bug, or a half-built capture) — leave the CRDT
    // alone rather than replacing a good install with garbage.
    if (incoming == null) return reg;

    // Content-addressed suppression. Devices auto-update plugins independently,
    // so several of them reach the same release and capture byte-identical
    // files; blob ids are content-addressed under the shared vault key, so
    // those captures share a contentHash. Suppressing here stops the
    // push -> self-notify -> pull -> push loop that would otherwise run across
    // every device on every plugin update.
    final current = manifestOf(reg);
    if (current != null && current.contentHash == incoming.contentHash) {
      return reg;
    }

    var ctx = const CausalContext.empty();
    for (final tv in reg.inner.values) {
      ctx = ctx.advance(tv.hlc);
    }
    return reg.set(canonicalJson(incoming.toJson()), tick(), ctx);
  }

  @override
  Uint8List renderState(Object state) {
    final reg = _cast(state);
    final value = reg.value;
    if (reg.isEmpty || value is! String || value.isEmpty) return Uint8List(0);
    return Uint8List.fromList(utf8.encode(value));
  }

  @override
  List<String> liveBlobIds(Object state) =>
      manifestOf(_cast(state))?.liveBlobIds ?? const [];

  /// The decoded manifest currently held by [reg], or null when empty/corrupt.
  PluginDirManifest? manifestOf(LwwRegister<Object?> reg) {
    final value = reg.value;
    if (reg.isEmpty || value is! String || value.isEmpty) return null;
    try {
      return PluginDirManifest.tryFromJson(jsonDecode(value));
    } catch (_) {
      return null;
    }
  }
}
