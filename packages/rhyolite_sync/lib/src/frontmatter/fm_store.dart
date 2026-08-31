/// Persistent, lazily-cached per-file frontmatter state.
///
/// Mirrors [FugueStore] on purpose — one row per fileId in
/// `<vaultId>_fm_store`, lazy decode, LRU eviction — because the reasoning is
/// the same: a vault edited for months holds hundreds of these, and decoding
/// them all at start is seconds of pinned CPU on dart2js for state nobody is
/// looking at.
///
/// It is a CACHE, not the source of truth. The state lives in the blob; this
/// only saves re-downloading it to answer "what did this file's frontmatter
/// look like last time". A local wipe — db_recovery in the plugin, or the
/// engine's own reset — is therefore survivable: FileState comes back from the
/// server, the blob is downloaded, and the state is decoded from it again.
///
/// The reset path has to remember to wipe this alongside the others. Leaving
/// it behind would keep frontmatter state pointing at a vault that no longer
/// exists.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_data/rpc_data.dart';

import 'fm_codec.dart';
import 'fm_state.dart';

class FmStore {
  FmStore({
    required IDataClient client,
    required this.vaultId,
    this.cacheMax = 50,
  }) : _client = client;

  final IDataClient _client;
  final String vaultId;

  /// How many decoded states stay in memory. Matches [FugueStore]'s default:
  /// enough for the working set of an editing session, not the whole vault.
  final int cacheMax;

  String get _storeCol => '${vaultId}_fm_store';

  /// Payload column. The stored bytes are exactly the canonical CBOR that goes
  /// into the blob, so persistence and the wire cannot drift apart.
  static const _payloadKey = 'fm';

  final Map<String, FmState> _cache = {};
  final List<String> _accessOrder = [];
  final Set<String> _knownFileIds = {};
  bool _idsLoaded = false;

  /// Serialises writes per fileId so a persist and a delete for the same file
  /// cannot interleave.
  final Map<String, Future<void>> _inFlight = {};

  Future<void> load() async {
    if (_idsLoaded) return;
    await reloadIds();
  }

  Future<void> reloadIds() async {
    final records = await _client.listAllRecords(collection: _storeCol);
    _knownFileIds
      ..clear()
      ..addAll(records.map((r) => r.id));
    _idsLoaded = true;
  }

  /// The stored state, or null when this file has none.
  ///
  /// A row that cannot be decoded — written by a newer build, or bit-rotted —
  /// answers null rather than throwing. Null means "no prior state", which
  /// makes the caller rebuild from the blob; that is the correct recovery, and
  /// the blob is authoritative anyway.
  Future<FmState?> get(String fileId) async {
    final cached = _cache[fileId];
    if (cached != null) {
      _touch(fileId);
      return cached;
    }
    if (_idsLoaded && !_knownFileIds.contains(fileId)) return null;

    final record = await _client.get(collection: _storeCol, id: fileId);
    if (record == null) {
      _knownFileIds.remove(fileId);
      return null;
    }
    final bytes = record.payload[_payloadKey];
    if (bytes is! Uint8List) return null;
    try {
      final state = decodeFmState(bytes);
      _put(fileId, state);
      return state;
    } on FmDecodeException {
      return null;
    }
  }

  /// Places [state] in the cache. Persist with [persistOne].
  void set(String fileId, FmState state) {
    _put(fileId, state);
    _knownFileIds.add(fileId);
  }

  Future<void> persistOne(String fileId) =>
      _serialise(fileId, () => _persistInner(fileId));

  Future<void> _persistInner(String fileId) async {
    final state = _cache[fileId];
    if (state == null) {
      try {
        await _client.delete(collection: _storeCol, id: fileId);
      } catch (_) {}
      _knownFileIds.remove(fileId);
      return;
    }
    await _writeWithRetry(fileId, {_payloadKey: encodeFmState(state)});
    _knownFileIds.add(fileId);
  }

  /// Create-or-update with optimistic-version retry.
  ///
  /// A plain `create` fails the second time a file is persisted, and an
  /// `update` needs the version it is replacing. The version can move under us
  /// when two persists for one file overlap — [_serialise] makes that rare
  /// rather than impossible, since a caller may hold an older handle.
  Future<void> _writeWithRetry(String id, Map<String, dynamic> payload) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final existing = await _client.get(collection: _storeCol, id: id);
        if (existing == null) {
          await _client.create(collection: _storeCol, id: id, payload: payload);
        } else {
          await _client.update(
            collection: _storeCol,
            id: id,
            expectedVersion: existing.version,
            payload: payload,
          );
        }
        return;
      } catch (_) {
        if (attempt == 4) rethrow;
      }
    }
  }

  Future<void> remove(String fileId) => _serialise(fileId, () async {
    _cache.remove(fileId);
    _accessOrder.remove(fileId);
    _knownFileIds.remove(fileId);
    try {
      await _client.delete(collection: _storeCol, id: fileId);
    } catch (_) {}
  });

  Future<void> wipeAll() async {
    _cache.clear();
    _accessOrder.clear();
    _knownFileIds.clear();
    _idsLoaded = false;
    try {
      await _client.deleteCollection(collection: _storeCol);
    } catch (_) {}
  }

  /// Diagnostic snapshot: everything known on disk, and the decoded subset.
  ({int files, int cached}) stats() =>
      (files: _knownFileIds.length, cached: _cache.length);

  void _touch(String fileId) {
    _accessOrder
      ..remove(fileId)
      ..add(fileId);
  }

  void _put(String fileId, FmState state) {
    _cache[fileId] = state;
    _touch(fileId);
    while (_accessOrder.length > cacheMax) {
      final oldest = _accessOrder.removeAt(0);
      _cache.remove(oldest);
    }
  }

  Future<void> _serialise(String fileId, Future<void> Function() work) {
    final prior = _inFlight[fileId] ?? Future<void>.value();
    final next = prior.then((_) => work()).catchError((_) {});
    _inFlight[fileId] = next;
    return next.whenComplete(() {
      if (identical(_inFlight[fileId], next)) _inFlight.remove(fileId);
    });
  }
}
