import 'dart:async';

import 'package:rpc_data/rpc_data.dart';

/// Persistent per-file on-disk signature (`mtime` + `size`).
///
/// This is a DEVICE-LOCAL change-detection hint — never synced (mtime is
/// per-device). It lets startup and the reconciler skip reading and
/// Fugue-diffing a file whose on-disk signature is unchanged since the last
/// sync, across plugin restarts. Without it the reconciler's in-memory stat
/// cache is empty on every cold start, so every text file is re-reconciled.
///
/// Storage: one row per fileId in `<vaultId>_stat_sig`, payload `{m, s}`.
/// Keyed by the same deterministic fileId as [FileState] (see
/// `deterministicFileId` — the keyed HMAC, or the legacy `uuid.v5` fallback
/// for a keyless vault), so a caller holding either a relPath (via its
/// fileIdFor) or a fileId resolves the same row. This is why the caller's
/// fileIdFor MUST match the engine's scheme — a drifted deriver keys a
/// different row and the skip never fires.
///
/// Persistence is best-effort: a lost write just costs one extra reconcile
/// next startup, never correctness. The skip is only ever taken on an exact
/// mtime+size match, the same signal the reconciler already trusts.
class StatSigStore {
  StatSigStore({required IDataClient client, required this.vaultId})
      : _client = client;

  final IDataClient _client;
  final String vaultId;

  String get _col => '${vaultId}_stat_sig';

  final Map<String, ({int mtimeMs, int sizeBytes})> _cache = {};
  final Map<String, Future<void>> _writeQueue = {};

  /// Loads all persisted signatures into memory. Call once at startup.
  Future<void> load() async {
    final records = await _client.listAllRecords(collection: _col);
    _cache.clear();
    for (final r in records) {
      final m = r.payload['m'];
      final s = r.payload['s'];
      if (m is int && s is int) {
        _cache[r.id] = (mtimeMs: m, sizeBytes: s);
      }
    }
  }

  ({int mtimeMs, int sizeBytes})? get(String fileId) => _cache[fileId];

  /// All fileIds with a persisted signature. Used by the orphan sweep to
  /// reclaim rows for files that no longer have a live FileState.
  Iterable<String> get fileIds => _cache.keys;

  /// Records the signature for [fileId] and persists it (fire-and-forget,
  /// serialized per fileId). No-ops when the signature is unchanged.
  void set(String fileId, int mtimeMs, int sizeBytes) {
    final existing = _cache[fileId];
    if (existing != null &&
        existing.mtimeMs == mtimeMs &&
        existing.sizeBytes == sizeBytes) {
      return;
    }
    _cache[fileId] = (mtimeMs: mtimeMs, sizeBytes: sizeBytes);
    unawaited(_serialise(fileId, () => _write(fileId, mtimeMs, sizeBytes)));
  }

  void remove(String fileId) {
    if (_cache.remove(fileId) == null) return;
    unawaited(_serialise(fileId, () => _delete(fileId)));
  }

  Future<void> wipeAll() async {
    _cache.clear();
    try {
      await _client.deleteCollection(collection: _col);
    } catch (_) {}
  }

  /// Awaits all in-flight signature writes. Useful before a graceful shutdown
  /// (or in tests) so nothing is lost mid-write.
  Future<void> flushPending() async {
    await Future.wait(_writeQueue.values.toList());
  }

  // Per-fileId write serialization so a create races cleanly with a later
  // update/delete for the same row.
  Future<void> _serialise(String key, Future<void> Function() body) async {
    final prev = _writeQueue[key];
    final completer = Completer<void>();
    _writeQueue[key] = completer.future;
    try {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {}
      }
      await body();
    } catch (_) {
      // Best-effort — a lost signature write costs one extra reconcile.
    } finally {
      completer.complete();
      if (identical(_writeQueue[key], completer.future)) {
        _writeQueue.remove(key);
      }
    }
  }

  Future<void> _write(String fileId, int mtimeMs, int sizeBytes) async {
    final payload = <String, dynamic>{'m': mtimeMs, 's': sizeBytes};
    final existing = await _client.get(collection: _col, id: fileId);
    if (existing == null) {
      await _client.create(collection: _col, id: fileId, payload: payload);
    } else {
      await _client.update(
        collection: _col,
        id: fileId,
        expectedVersion: existing.version,
        payload: payload,
      );
    }
  }

  Future<void> _delete(String fileId) =>
      _client.delete(collection: _col, id: fileId);
}
