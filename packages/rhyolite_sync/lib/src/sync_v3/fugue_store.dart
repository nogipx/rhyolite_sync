import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convergent/fugue.dart';
import 'package:rpc_dart/rpc_dart.dart' show CborCodec;
import 'package:rpc_data/rpc_data.dart';

/// Persistent + lazily-cached per-file [Fugue] text states.
///
/// Storage layout: one row per fileId in `<vaultId>_fugue_store`,
/// payload is the JSON-encoded [Fugue] via [FugueCodec].
///
/// Load policy: [load] learns the set of stored fileIds (no Fugue
/// decode — that's the expensive part), then individual [get] calls
/// fetch + decode on demand. An LRU cache keeps the hottest [cacheMax]
/// trees in memory; cold files are evicted and re-read from sqlite
/// the next time they're touched.
///
/// Rationale: with a vault that's been edited for months, a single
/// FugueStore may carry hundreds of thousands of CRDT elements spread
/// across hundreds of files. Decoding all of them at start costs
/// seconds of pinned CPU on dart2js, plus tens of megabytes of
/// long-lived Dart objects that put V8 GC under pressure. Lazy
/// decode + LRU drops both the startup cost and the steady-state
/// memory footprint to "what's actually being edited right now".
///
/// Binary files never go through this store — they keep the existing
/// state-based blob path with LWW + conflict-copy semantics.
class FugueStore {
  FugueStore({
    required IDataClient client,
    required this.vaultId,
    this.cacheMax = 50,
  }) : _client = client;

  final IDataClient _client;
  final String vaultId;

  /// Maximum number of decoded Sequences kept in memory at once. When
  /// the cache exceeds this size, the least-recently-used entry is
  /// evicted. Default 50 is enough to hold the working set of an
  /// active editing session without dragging cold files along.
  final int cacheMax;

  String get _storeCol => '${vaultId}_fugue_store';

  /// JSON codec for LOCAL sqlite persistence (payload is a Map). The WIRE
  /// blob uses the compact binary codec instead — see [encodeBlob].
  static const _codec = FugueCodec<String>(StringCodec());

  /// Compact binary codec for the WIRE blob content (`Uint8List`, ~2 B/char).
  static const _binary = FugueTextBinaryCodec();

  /// Hot cache, LRU-evicted.
  final Map<String, Fugue<String>> _cache = {};

  /// LRU tracking — front is oldest, back is newest. Kept in sync with
  /// every cache mutation.
  final List<String> _accessOrder = [];

  /// Set of fileIds known to exist in the backing store. Populated by
  /// [load]; kept in sync as [set] and [remove] happen. Allows [get]
  /// to short-circuit the sqlite round trip when a fileId has never
  /// been seen.
  final Set<String> _knownFileIds = {};
  bool _idsLoaded = false;

  Iterable<String> get fileIds => _knownFileIds;
  int get count => _knownFileIds.length;

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// Returns the [Sequence] for [fileId]. Cache-hit completes
  /// effectively synchronously; cache-miss performs one sqlite read
  /// and decode, then caches the result.
  ///
  /// Returns null when the fileId is not in the store.
  Future<Fugue<String>?> get(String fileId) async {
    final cached = _cache[fileId];
    if (cached != null) {
      _touch(fileId);
      return cached;
    }
    if (_idsLoaded && !_knownFileIds.contains(fileId)) {
      // We know everything that's in sqlite, and this fileId isn't
      // there — skip the round trip.
      return null;
    }
    final record = await _client.get(collection: _storeCol, id: fileId);
    if (record == null) {
      _knownFileIds.remove(fileId);
      return null;
    }
    final Fugue<String> seq;
    try {
      seq = _codec.decode(record.payload);
    } catch (_) {
      // Corrupt row — the next save for this fileId rewrites it.
      return null;
    }
    _putInCache(fileId, seq);
    _knownFileIds.add(fileId);
    return seq;
  }

  /// Sync cache probe — returns the cached Sequence if present, null
  /// otherwise. Does NOT touch sqlite. Useful in hot paths where a
  /// miss is "no-op" rather than "go load it".
  Fugue<String>? peek(String fileId) {
    final s = _cache[fileId];
    if (s != null) _touch(fileId);
    return s;
  }

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// Applies a new full state in memory. Schedule [persistOne] to
  /// flush to the backing store.
  void set(String fileId, Fugue<String> state) {
    _putInCache(fileId, state);
    _knownFileIds.add(fileId);
  }

  /// Removes the in-memory entry and queues a delete from persistence.
  Future<void> remove(String fileId) => _serialise('store:$fileId', () async {
    _cache.remove(fileId);
    _accessOrder.remove(fileId);
    _knownFileIds.remove(fileId);
    try {
      await _client.delete(collection: _storeCol, id: fileId);
    } catch (_) {}
  });

  // ---------------------------------------------------------------------------
  // LRU mechanics
  // ---------------------------------------------------------------------------

  void _touch(String fileId) {
    _accessOrder.remove(fileId);
    _accessOrder.add(fileId);
  }

  void _putInCache(String fileId, Fugue<String> seq) {
    _cache[fileId] = seq;
    _touch(fileId);
    while (_cache.length > cacheMax) {
      final oldest = _accessOrder.removeAt(0);
      _cache.remove(oldest);
    }
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  /// Learns the set of fileIds present in sqlite. Does NOT decode any
  /// Sequence — that work is deferred to the first [get] for each
  /// fileId, where it can be amortised against the work the caller was
  /// going to do anyway.
  ///
  /// Idempotent. Calling [load] a second time within the same session
  /// is a no-op (use [reloadIds] to force a re-scan after external
  /// writes to the backing store).
  Future<void> load() async {
    if (_idsLoaded) return;
    await reloadIds();
  }

  /// Forces a re-scan of fileIds from the backing store. Use only when
  /// an external process has written to the collection.
  Future<void> reloadIds() async {
    final records = await _client.listAllRecords(collection: _storeCol);
    _knownFileIds
      ..clear()
      ..addAll(records.map((r) => r.id));
    _idsLoaded = true;
  }

  /// Diagnostic snapshot. [files] is the total set known in sqlite;
  /// [cached] is the subset decoded into memory right now. The
  /// previous `totalEntries` field would have required loading every
  /// Sequence — which is exactly the work this rewrite avoids.
  ({int files, int cached}) get stats =>
      (files: _knownFileIds.length, cached: _cache.length);

  final Map<String, Future<void>> _persistQueue = {};

  Future<void> _serialise(String key, Future<void> Function() body) async {
    final prev = _persistQueue[key];
    final completer = Completer<void>();
    _persistQueue[key] = completer.future;
    try {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {}
      }
      await body();
    } finally {
      completer.complete();
      if (identical(_persistQueue[key], completer.future)) {
        _persistQueue.remove(key);
      }
    }
  }

  Future<void> persistOne(String fileId) =>
      _serialise('store:$fileId', () => _persistOneInner(fileId));

  Future<void> _persistOneInner(String fileId) async {
    final state = _cache[fileId];
    if (state == null) {
      try {
        await _client.delete(collection: _storeCol, id: fileId);
      } catch (_) {}
      _knownFileIds.remove(fileId);
      return;
    }
    final payload = _codec.encode(state)! as Map<String, Object?>;
    await _writeWithRetry(
      collection: _storeCol,
      id: fileId,
      payload: payload.cast<String, dynamic>(),
    );
    _knownFileIds.add(fileId);
  }

  Future<void> _writeWithRetry({
    required String collection,
    required String id,
    required Map<String, dynamic> payload,
  }) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final existing = await _client.get(collection: collection, id: id);
        if (existing == null) {
          await _client.create(
            collection: collection,
            id: id,
            payload: payload,
          );
        } else {
          await _client.update(
            collection: collection,
            id: id,
            expectedVersion: existing.version,
            payload: payload,
          );
        }
        return;
      } catch (e) {
        final msg = e.toString().toLowerCase();
        final transient =
            msg.contains('not newer') ||
            msg.contains('conflict') ||
            msg.contains('expected version') ||
            msg.contains('already exists');
        if (!transient || attempt == 4) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 5 * (1 << attempt)));
      }
    }
  }

  Future<void> wipeAll() async {
    _cache.clear();
    _accessOrder.clear();
    _knownFileIds.clear();
    _idsLoaded = false;
    try {
      await _client.deleteCollection(collection: _storeCol);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Wire codec — exposed so callers (state engine, history viewer) can go
  // straight from blob bytes to Fugue and back without depending on the
  // convergent codec types directly.
  // ---------------------------------------------------------------------------

  /// JSON (Map) round-trip helper — same format as local persistence. Kept
  /// for tests and any caller that needs a JSON-compatible view of a tree.
  static Fugue<String> decodeFromBlob(Object? json) => _codec.decode(json);

  /// JSON (Map) encode — inverse of [decodeFromBlob].
  static Object encodeForBlob(Fugue<String> state) => _codec.encode(state)!;

  /// Magic prefix that makes a new-format Fugue blob self-identifying. The
  /// leading `0x00` guarantees the bytes are never mistaken for a UTF-8 text
  /// blob (real notes never start with NUL), and the `fg1` tag distinguishes
  /// it from the pre-Fugue Sequence blobs (CBOR/JSON maps) still on the
  /// server during a rollout. See [tryDecodeBlob] / [isLegacySequenceBlob].
  static const List<int> _magic = <int>[0x00, 0x66, 0x67, 0x31]; // \0fg1

  /// Encode a tree for the WIRE blob: [_magic] + compact binary codec.
  static Uint8List encodeBlob(Fugue<String> state) {
    final body = _binary.encode(state);
    final out = Uint8List(_magic.length + body.length);
    out.setRange(0, _magic.length, _magic);
    out.setRange(_magic.length, out.length, body);
    return out;
  }

  /// Decode a WIRE blob back into a [Fugue], or null when [bytes] are NOT a
  /// new-format (magic-prefixed) Fugue blob — a pre-Fugue plain-text blob, a
  /// legacy Sequence blob, or a binary file. Callers pair a null with
  /// [isLegacySequenceBlob] to decide between "genuine plain text" (write /
  /// seed as-is) and "old-format, awaiting reseed" (skip). Pure — no store
  /// side effects — so the history viewer can project a past version without
  /// touching the live tree.
  static Fugue<String>? tryDecodeBlob(Uint8List bytes) {
    if (bytes.length < _magic.length) return null;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return null;
    }
    try {
      return _binary.decode(Uint8List.sublistView(bytes, _magic.length));
    } catch (_) {
      return null;
    }
  }

  /// True when [bytes] are a PRE-Fugue [Sequence] blob (the format shipped
  /// before this migration: a CBOR or JSON map with `v` + `chars`/`c`).
  ///
  /// Such a blob is NOT valid document text — writing its raw bytes to disk,
  /// or seeding a tree from them, would corrupt the note. Callers use this to
  /// tell an old-format blob apart from a genuine plain-text blob so they can
  /// skip it and let a reseed-from-disk (from this device or an upgraded
  /// peer) replace it. Read-only; no `Sequence` decode is performed, so the
  /// old CRDT type is not resurrected.
  static bool isLegacySequenceBlob(Uint8List bytes) {
    bool looksLikeSequence(Object? obj) =>
        obj is Map &&
        obj['v'] is int &&
        (obj['chars'] is List || obj['c'] is List);
    try {
      if (looksLikeSequence(CborCodec.decode(bytes))) return true;
    } catch (_) {
      // Not CBOR — fall through to the JSON probe.
    }
    try {
      if (looksLikeSequence(jsonDecode(utf8.decode(bytes)))) return true;
    } catch (_) {
      // Not JSON text either.
    }
    return false;
  }
}
