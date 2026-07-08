/// A minimal seam over the plugin's `data.json` blob so the read-modify-write
/// serialization below can be unit-tested without the Obsidian JS bridge.
abstract interface class RawDataStore {
  Future<Object?> load();
  Future<void> save(Map<String, dynamic> data);
}

/// Serializes every `data.json` update through a single chain.
///
/// Each writer previously did an independent `load() -> mutate -> save()`.
/// Two of those interleaving (e.g. a background session-persist and the
/// side panel's savePaused) meant the second `save()` clobbered the whole
/// file with a stale copy, silently dropping the first update. Here every
/// [update] runs strictly after the previous one has persisted, so its
/// re-read already includes that change. Reads also deep-convert, so
/// untouched nested keys round-trip intact instead of being left as opaque
/// JS objects by a shallow copy.
class DataJsonWriter {
  DataJsonWriter(this._raw);

  final RawDataStore _raw;
  Future<void> _chain = Future<void>.value();

  Future<Map<String, dynamic>> read() async {
    final raw = await _raw.load();
    return raw is Map ? deepConvertJsonMap(raw) : <String, dynamic>{};
  }

  /// Applies [mutate] to the current decoded map and persists it, serialized
  /// against every other update on this writer.
  Future<void> update(void Function(Map<String, dynamic> map) mutate) {
    final next = _chain.then((_) async {
      final map = await read();
      mutate(map);
      await _raw.save(map);
    });
    // A failed update must not poison the chain for the next one.
    _chain = next.then((_) {}, onError: (_) {});
    return next;
  }
}

/// Deep-converts a JS (or plain) object tree to Dart `Map`/`List`.
///
/// Obsidian's `loadData()` returns JS objects; a shallow `Map.from()` leaves
/// nested objects as opaque JSObjects that fail Dart type casts.
Map<String, dynamic> deepConvertJsonMap(Map map) {
  final result = <String, dynamic>{};
  for (final entry in map.entries) {
    final key = entry.key.toString();
    final value = entry.value;
    if (value is Map) {
      result[key] = deepConvertJsonMap(value);
    } else if (value is List) {
      result[key] =
          value.map((e) => e is Map ? deepConvertJsonMap(e) : e).toList();
    } else {
      result[key] = value;
    }
  }
  return result;
}
