import 'dart:convert';
import 'dart:typed_data';

import 'package:convergent/convergent.dart';

import 'canonical_json.dart';

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
/// - [wholeFile] — an opaque blob merged last-write-wins
///   (theme/snippet CSS, plugin `data.json` whose schema we do not know and
///   must never field-merge).
enum SettingsCrdtKind { fieldMap, orSet, wholeFile }

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
