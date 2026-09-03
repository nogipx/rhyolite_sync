import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convergent/fugue.dart';
import 'package:rhyolite_core/rhyolite_core.dart' as core;
import 'package:rpc_data/rpc_data.dart';

/// Persistent + lazily-cached per-file [Fugue] text states.
///
/// Storage layout: one row per fileId in `<vaultId>_fugue_store`, payload is
/// the compact binary encoding of the tree, base64'd — see [_encodePayload].
/// Rows written before that carry the old JSON encoding and are still read;
/// see [_decodePayload].
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

  /// JSON codec. Legacy for local rows (still read, never written — see
  /// [_decodePayload]); still the format of [encodeForBlob].
  static const _codec = FugueCodec<String>(StringCodec());

  /// Compact binary codec (`Uint8List`, ~2 B/char). Used for the WIRE blob
  /// (see [encodeBlob]) and, since [_encodePayload], for local rows too.
  static const _binary = FugueTextBinaryCodec();

  /// Marks a row as carrying [_encodePayload]'s form. Absent on legacy rows.
  static const _binaryPayloadTag = 'fz1';

  /// Local rows now carry the same compact encoding the wire blob uses.
  ///
  /// The JSON form spent one quoted, comma-separated entry per character —
  /// 4 B for ASCII, 5 for Cyrillic — where the binary codec writes about 2,
  /// and it repeated the replica id in full on every block with no interning.
  /// On a text-heavy vault that made this store the largest thing in the
  /// database, for a tree the blob cache was already holding in the compact
  /// form a few tables over.
  ///
  /// base64 gives back most of that and costs no schema change. Raw bytes are
  /// not an option: `rpc_data`'s payload column is TEXT and the value is
  /// `jsonEncode`d, so a `Uint8List` would land as an array of integers —
  /// several times worse than the JSON it replaced.
  static Map<String, dynamic> _encodePayload(Fugue<String> state) => {
    'enc': _binaryPayloadTag,
    'd': base64Encode(_binary.encode(state)),
  };

  /// Reads either form.
  ///
  /// Migration is lazy on purpose: a row is rewritten when its file is next
  /// edited, never in a sweep at startup. A vault big enough to care about
  /// the size win is exactly the one that cannot afford rewriting every row
  /// before sync may begin.
  static Fugue<String> _decodePayload(Map<String, dynamic> payload) {
    if (payload['enc'] == _binaryPayloadTag) {
      return _binary.decode(base64Decode(payload['d'] as String));
    }
    return _codec.decode(payload);
  }

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

  /// Whether a tree is stored for [fileId], without decoding it.
  ///
  /// Deliberately not `get(...) != null`: that decodes the tree and pushes it
  /// through the LRU. Callers that sweep every file (the blob GC) would decode
  /// the whole vault and evict the working set to answer a yes/no question.
  bool has(String fileId) => _knownFileIds.contains(fileId);

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
      seq = _decodePayload(record.payload);
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
    await _writeWithRetry(
      collection: _storeCol,
      id: fileId,
      payload: _encodePayload(state),
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

  // The blob FORMAT moved to rhyolite_core (`codec/fugue_blob_codec.dart`).
  // It never belonged to a store: bytes in, tree out, no persistence — and the
  // blob id is a hash of exactly those bytes, so the format is part of what
  // makes two devices agree. These delegates stay because call sites name them
  // through the store; they carry no logic.
  static Fugue<String> decodeFromBlob(Object? json) =>
      core.decodeFugueFromJson(json);
  static Object encodeForBlob(Fugue<String> state) =>
      core.encodeFugueToJson(state);
  static Uint8List encodeBlob(Fugue<String> state) =>
      core.encodeFugueBlob(state);
  static Fugue<String>? tryDecodeBlob(Uint8List bytes) =>
      core.tryDecodeFugueBlob(bytes);
  // Named apart from the core function on purpose: a static and a top-level
  // sharing a name resolve to the static inside the class, so the delegate
  // would call itself forever. The prefix says which one you are getting.
  static bool isLegacySequenceBlob(Uint8List bytes) =>
      core.isLegacySequenceBlob(bytes);
}
