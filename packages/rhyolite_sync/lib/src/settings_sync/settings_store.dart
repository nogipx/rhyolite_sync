import 'package:convergent/convergent.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:uuid/uuid.dart';

/// One persisted settings resource: its encoded convergent state plus the
/// causal context of outer record-HLCs this device has already incorporated
/// (`seen`). `seen` is what gets sent as `contextPacked` on push so the
/// server drops the concurrent versions we already merged.
class StoredResource {
  StoredResource({required this.encodedState, required this.seen, this.sig});
  final Object? encodedState;
  CausalContext seen;

  /// Opaque last-synced source signature (the platform layer's cheap
  /// change-detection token, e.g. `mtime:size`). Lets a scan skip reading and
  /// diffing a file whose on-disk signature is unchanged since the last sync.
  String? sig;
}

/// SQLite-backed persistence for [SettingsSync], mirroring `FileStateStore`
/// but for the `<vaultId>_config` keyspace. Stores one row per resource plus
/// a meta row (cursor, deviceId, own latest HLC).
///
/// The HLC `nodeId` is a stable per-device UUID — independent from the notes
/// engine's deviceId (settings is a separate keyspace; uniqueness, not
/// sharing, is what convergence requires).
class SettingsStore {
  SettingsStore({required IDataClient client, required this.vaultId})
      : _client = client;

  final IDataClient _client;
  final String vaultId;

  String get _storeCol => '${vaultId}_settings_store';
  String get _metaCol => '${vaultId}_settings_meta';
  static const _metaId = 'meta';

  final Map<String, StoredResource> _rows = {};
  String? _deviceId;
  int _cursor = 0;
  Hlc? _ownLatestHlc;

  String get deviceId => _deviceId!;
  int get cursor => _cursor;
  set cursor(int value) => _cursor = value;

  Iterable<String> get resourceIds => _rows.keys;
  Object? encodedState(String resourceId) => _rows[resourceId]?.encodedState;
  CausalContext seenOf(String resourceId) =>
      _rows[resourceId]?.seen ?? const CausalContext.empty();

  /// Last-synced source signature for [resourceId], or null if never synced.
  String? sigOf(String resourceId) => _rows[resourceId]?.sig;

  /// Mint a fresh local HLC for a write.
  Hlc nextHlc({int? wallMs}) {
    final ms = wallMs ?? DateTime.now().millisecondsSinceEpoch;
    final base = _ownLatestHlc ?? Hlc(ms, 0, deviceId);
    final next = base.increment(ms);
    _ownLatestHlc = next;
    return next;
  }

  /// Advance the local clock past a remote HLC seen on pull.
  void observeHlc(Hlc remote, {int? wallMs}) {
    final ms = wallMs ?? DateTime.now().millisecondsSinceEpoch;
    final base = _ownLatestHlc ?? Hlc(ms, 0, deviceId);
    _ownLatestHlc = base.receive(remote, ms);
  }

  Future<void> load() async {
    final records = await _client.listAllRecords(collection: _storeCol);
    _rows.clear();
    for (final r in records) {
      _rows[r.id] = StoredResource(
        encodedState: r.payload['state'],
        seen: CausalContext.unpack((r.payload['seen'] as String?) ?? ''),
        sig: r.payload['sig'] as String?,
      );
    }

    final meta = await _client.get(collection: _metaCol, id: _metaId);
    if (meta != null) {
      _cursor = (meta.payload['cursor'] as int?) ?? 0;
      _deviceId = meta.payload['deviceId'] as String?;
      final ownHlc = meta.payload['ownHlc'] as String?;
      _ownLatestHlc = ownHlc == null ? null : Hlc.unpack(ownHlc);
    }
    _deviceId ??= const Uuid().v4();
    if (meta == null) await persistMeta();
  }

  Future<void> putResource(
    String resourceId,
    Object? encodedState,
    CausalContext seen, {
    String? sig,
  }) async {
    // A null sig preserves the existing one — pulls update state without a
    // local file signature, so they must not clobber it.
    final effectiveSig = sig ?? _rows[resourceId]?.sig;
    _rows[resourceId] =
        StoredResource(encodedState: encodedState, seen: seen, sig: effectiveSig);
    await _writeWithRetry(
      collection: _storeCol,
      id: resourceId,
      payload: {
        'state': encodedState,
        'seen': seen.pack(),
        if (effectiveSig != null) 'sig': effectiveSig,
      },
    );
  }

  /// Persist only the source signature for [resourceId] — used when a scanned
  /// file produced no CRDT change, or after a pull-write, so the next scan
  /// recognises the on-disk version as already synced.
  Future<void> setSig(String resourceId, String sig) async {
    final row = _rows[resourceId] ??=
        StoredResource(encodedState: null, seen: const CausalContext.empty());
    row.sig = sig;
    await _writeWithRetry(
      collection: _storeCol,
      id: resourceId,
      payload: {
        'state': row.encodedState,
        'seen': row.seen.pack(),
        'sig': sig,
      },
    );
  }

  /// Remove a resource row entirely (e.g. a resource that is no longer synced).
  /// Best-effort: a failed delete just leaves a harmless dead row.
  Future<void> delete(String resourceId) async {
    _rows.remove(resourceId);
    try {
      await _client.delete(collection: _storeCol, id: resourceId);
    } catch (_) {}
  }

  void setSeen(String resourceId, CausalContext seen) {
    final row = _rows[resourceId];
    if (row != null) row.seen = seen;
  }

  /// Wipe local settings state: drop every resource row and reset the pull
  /// cursor to 0. Keeps [deviceId] and the HLC clock so writes made after a
  /// wipe stay strictly newer than anything still on other devices. Used by
  /// the settings reset (re-upload) and restore (re-download) flows.
  Future<void> wipeAll() async {
    _rows.clear();
    _cursor = 0;
    try {
      await _client.deleteCollection(collection: _storeCol);
    } catch (_) {}
    await persistMeta();
  }

  Future<void> persistMeta() async {
    await _writeWithRetry(
      collection: _metaCol,
      id: _metaId,
      payload: {
        'cursor': _cursor,
        if (_deviceId != null) 'deviceId': _deviceId,
        if (_ownLatestHlc != null) 'ownHlc': _ownLatestHlc!.pack(),
      },
    );
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
        final transient = msg.contains('not newer') ||
            msg.contains('conflict') ||
            msg.contains('expected version') ||
            msg.contains('already exists') ||
            msg.contains('version');
        if (!transient || attempt == 4) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 5 * (1 << attempt)));
      }
    }
  }
}
