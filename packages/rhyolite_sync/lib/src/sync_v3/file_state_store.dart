import 'dart:async';

import 'package:convergent/convergent.dart' hide Dot;
import 'package:convergent/fugue.dart' show Dot, LamportClock;
import 'package:rpc_data/rpc_data.dart';
import 'package:uuid/uuid.dart';

import 'file_state.dart';
import 'file_state_codec.dart';

/// Persistent + in-memory file-state cache for Δ-state CRDT sync (doc §4.4).
///
/// In-memory:
/// - `_registers: Map<fileId, MvRegister<FileState>>` — the materialised
///   per-file CRDT register.
/// - `_lastSyncedBlobRef` — base ref for 3-way merge (unchanged).
/// - `_ownContext: CausalContext` — what this device has seen across all
///   pulled and own-written TaggedValues. Stamped on every local write
///   so the server's join can drop values this write dominates.
///
/// Persistence shape (per vault):
/// - collection `<vaultId>_state_store` — one row per fileId carrying the
///   serialised register (list of TaggedValues).
/// - collection `<vaultId>_state_meta` — single row with cursor, epoch,
///   deviceId, ownContext, lastSyncedBlobRef.
class FileStateStore {
  FileStateStore({required IDataClient client, required this.vaultId})
      : _client = client;

  final IDataClient _client;
  final String vaultId;

  String get _storeCol => '${vaultId}_state_store';
  String get _metaCol => '${vaultId}_state_meta';
  static const _metaId = 'meta';

  // ---------------------------------------------------------------------------
  // In-memory state
  // ---------------------------------------------------------------------------

  final Map<String, MvRegister<FileState>> _registers = {};
  final Map<String, String> _lastSyncedBlobRef = {};

  /// fileId → the max serverSeq at which this device has pulled a record for
  /// the file. The causal-stability boundary for tombstone GC: a tombstone is
  /// safe to drop only once every active device's pull cursor (headSeq) has
  /// passed its serverSeq. Persisted in meta alongside [_lastSyncedBlobRef].
  final Map<String, int> _serverSeq = {};

  CausalContext _ownContext = const CausalContext.empty();
  int _serverCursor = 0;
  int? _serverEpoch;

  /// Persistent per-install identifier. Also used as the HLC nodeId so
  /// every TaggedValue this device produces is unambiguously attributable.
  String? _deviceId;

  /// Latest local HLC millis-counter — used by [nextHlc] to advance.
  /// Not persisted: rebuilt on load from the max HLC across all registers
  /// with `nodeId == deviceId`.
  Hlc? _ownLatestHlc;

  /// One global, persistent Lamport clock per device for **Fugue element
  /// dots** (the text CRDT). Its [replica] is [deviceId], so every dot this
  /// device mints — `(counter, deviceId)` — is globally attributable and the
  /// GC frontier is a simple per-replica version vector.
  ///
  /// A logical counter (not an [Hlc]) is what lets a whole typed run share
  /// consecutive counters and coalesce into one Fugue block. Built in [load]
  /// once [deviceId] is known; null before then.
  ///
  /// The counter is persisted in meta ([fugueClockCounter]) best-effort, for
  /// coalescing quality and the GC frontier. **Correctness does not depend on
  /// it**: [observeDots] (called on the file's own dots before every edit
  /// batch) guarantees each freshly-minted dot's counter strictly exceeds
  /// every counter already in that file — so no dot is ever reused within a
  /// Fugue tree even if the persisted counter lags behind.
  LamportClock? _fugueClock;

  String get deviceId => _deviceId ?? (throw StateError(
        'FileStateStore.deviceId accessed before load()',
      ));

  CausalContext get ownContext => _ownContext;
  int get serverCursor => _serverCursor;
  int? get serverEpoch => _serverEpoch;

  Iterable<String> get fileIds => _registers.keys;
  int get count => _registers.length;

  /// All current single-value file states, skipping conflicting registers.
  /// Use [registerFor] when you need every concurrent value.
  Iterable<FileState> get singleValues => _registers.values
      .where((r) => !r.hasConflict && r.singleValue != null)
      .map((r) => r.singleValue!);

  /// Backward-compat alias for callers that don't need to distinguish
  /// conflict registers. Identical to [singleValues].
  Iterable<FileState> get all => singleValues;

  /// Flat iteration over EVERY concurrent value across all registers.
  /// Used by BlobJanitor to compute the live set across multi-value
  /// registers (doc §9).
  Iterable<FileState> get allValuesFlat sync* {
    for (final reg in _registers.values) {
      for (final tv in reg.values) {
        yield tv.value;
      }
    }
  }

  bool contains(String fileId) => _registers.containsKey(fileId);

  MvRegister<FileState>? registerFor(String fileId) => _registers[fileId];

  /// Returns the unique [FileState] when the register is collapsed (1 value).
  /// Returns null on missing fileId AND on multi-value (conflict).
  FileState? get(String fileId) {
    final reg = _registers[fileId];
    if (reg == null) return null;
    return reg.singleValue;
  }

  bool hasConflict(String fileId) =>
      _registers[fileId]?.hasConflict ?? false;

  /// All concurrent values for a fileId. Empty when the file is missing.
  List<FileState> currentValues(String fileId) =>
      _registers[fileId]?.allValues ?? const [];

  String? lastSyncedBlobRefFor(String fileId) => _lastSyncedBlobRef[fileId];

  /// The max serverSeq this device has pulled for [fileId], or null if it has
  /// never pulled a record for it (e.g. a locally-created tombstone not yet
  /// echoed back). Tombstone GC treats null as "not yet stable" (skip).
  int? serverSeqFor(String fileId) => _serverSeq[fileId];

  /// Record the server seq at which [fileId] was pulled — monotonic, only
  /// advances. Set by the applier from each pulled record's serverSeq.
  void recordServerSeq(String fileId, int seq) {
    final cur = _serverSeq[fileId];
    if (cur == null || seq > cur) _serverSeq[fileId] = seq;
  }

  /// fileIds whose collapsed (single-value) register is a tombstone. The
  /// causal-stability GC scans these for prunable deletes; conflicting
  /// (multi-value) registers are skipped until they collapse.
  Iterable<String> get tombstoneFileIds sync* {
    for (final e in _registers.entries) {
      final v = e.value.singleValue;
      if (v != null && v.tombstone) yield e.key;
    }
  }

  // ---------------------------------------------------------------------------
  // HLC + context helpers
  // ---------------------------------------------------------------------------

  /// Advance the device's local HLC to the next value, ensuring strict
  /// monotonicity even if wall clock goes backward.
  Hlc nextHlc({int? wallMs}) {
    final ms = wallMs ?? DateTime.now().millisecondsSinceEpoch;
    final base = _ownLatestHlc ?? Hlc(ms, 0, deviceId);
    final next = base.increment(ms);
    _ownLatestHlc = next;
    return next;
  }

  /// Fold an OBSERVED hlc (authored by any device, possibly ahead of this
  /// device's wall clock) into the local clock so the next [nextHlc]
  /// strictly dominates it.
  ///
  /// Call this before authoring edits against content that was pulled from
  /// peers: it guarantees freshly-minted edit dots causally dominate the
  /// content they edit. That invariant matters for the Fugue position
  /// tree — an insert stamped with a SMALLER hlc than an adjacent existing
  /// character can be misordered across a tombstoned gap when a peer's
  /// wall clock ran ahead of ours. Keeping our clock dominant makes every
  /// edit sort after existing content, sidestepping that ordering.
  ///
  /// Clamped by [maxClockSkewMs] (same bound as [applyRemote], via
  /// [Hlc.receive]) so a wildly-future observed hlc cannot poison the
  /// local clock — a char authored beyond the skew window is distrusted
  /// exactly as an out-of-window register write would be.
  void witness(Hlc observed, {int? maxClockSkewMs = defaultMaxClockSkewMs}) {
    final wall = DateTime.now().millisecondsSinceEpoch;
    final base = _ownLatestHlc ?? Hlc(wall, 0, deviceId);
    _ownLatestHlc = base.receive(observed, wall, maxSkewMs: maxClockSkewMs);
  }

  // ---------------------------------------------------------------------------
  // Fugue clock (text CRDT dots)
  // ---------------------------------------------------------------------------

  LamportClock get _clock => _fugueClock ??= LamportClock(deviceId);

  /// The device's Fugue [LamportClock]. Pass this to `Fugue.applyOps` so the
  /// batch mints consecutive dots (one coalesced block per reconcile).
  LamportClock get fugueClock => _clock;

  /// Mint the next Fugue element [Dot] for a local edit.
  Dot nextDot() => _clock.tick();

  /// Fold every observed Fugue [Dot] into the clock so the next [nextDot]
  /// strictly dominates them (Lamport receive rule). **Replaces [witness]**
  /// on the text path: call `observeDots(oldFugue.dots)` before authoring an
  /// edit batch. This is what keeps a fresh edit's dot above every counter
  /// already in the file — the skew-safety property, now for free and
  /// independent of the (possibly stale) persisted counter.
  void observeDots(Iterable<Dot> dots) => _clock.observeAll(dots);

  /// Current Fugue clock high-water mark (0 before any local dot). Reported
  /// in the GC frontier as this device's `deviceId → counter` boundary.
  int get fugueClockCounter => _fugueClock?.value ?? 0;

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------

  /// Apply a write produced by THIS device. Stamps [value.hlc] under
  /// [ownContext], then advances the local context to include the new hlc.
  /// Returns the new register state for the file.
  MvRegister<FileState> applyLocal(FileState value) {
    final existing = _registers[value.fileId] ?? MvRegister<FileState>.empty();
    final updated = existing.set(value, value.hlc, _ownContext);
    _registers[value.fileId] = updated;
    _ownContext = _ownContext.advance(value.hlc);
    if (value.hlc.nodeId == _deviceId) {
      if (_ownLatestHlc == null || value.hlc > _ownLatestHlc!) {
        _ownLatestHlc = value.hlc;
      }
    }
    return updated;
  }

  /// Self-stabilization bound (paper §4): TaggedValues whose hlc.millis
  /// is more than this far in the future relative to the local wall
  /// clock are refused — they would otherwise poison the local clock
  /// and dominate every subsequent LWW comparison until physical time
  /// catches up. Five minutes is generous enough for normal NTP drift
  /// and timezone-related local-clock mistakes, but tight enough that a
  /// year-2099 bad write cannot pollute the vault.
  static const int defaultMaxClockSkewMs = 5 * 60 * 1000;

  /// Apply TaggedValues received from the server for a fileId. Performs
  /// `localRegister.join(remoteRegister)` and folds every incoming hlc +
  /// context into the local [ownContext].
  ///
  /// [maxClockSkewMs] is the self-stabilization bound (paper §4): any
  /// TaggedValue with `hlc.millis > now + maxClockSkewMs` is skipped
  /// entirely. Defaults to [defaultMaxClockSkewMs]; pass `null` to
  /// disable the defence (tests / replays).
  ///
  /// Returns the number of skipped (rejected) values via the [onSkip]
  /// callback — useful for surfacing warnings without coupling the
  /// store to a logger.
  MvRegister<FileState> applyRemote(
    String fileId,
    Iterable<TaggedValue<FileState>> incoming, {
    int? maxClockSkewMs = defaultMaxClockSkewMs,
    void Function(TaggedValue<FileState> rejected, int wallMs)? onSkip,
  }) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final remoteSet = <TaggedValue<FileState>>{};
    for (final tv in incoming) {
      if (maxClockSkewMs != null && tv.hlc.millis > nowMs + maxClockSkewMs) {
        onSkip?.call(tv, nowMs);
        continue;
      }
      remoteSet.add(tv);
    }
    if (remoteSet.isEmpty) {
      return _registers[fileId] ?? MvRegister<FileState>.empty();
    }
    final remote = MvRegister<FileState>.fromValues(remoteSet);
    final local = _registers[fileId] ?? MvRegister<FileState>.empty();
    final joined = local.join(remote);
    _registers[fileId] = joined;
    for (final tv in remoteSet) {
      _ownContext = _ownContext.advance(tv.hlc).merge(tv.context);
    }
    return joined;
  }

  /// Backward-compat shim. Treats [s] as a freshly-written local value
  /// produced by THIS device under the current [ownContext], collapsing
  /// any prior register entries that the writer's context dominates.
  /// Use [applyLocal] in new code.
  void upsert(FileState s) => applyLocal(s);

  /// Forcibly replace a register (used by the resolver after collapsing
  /// a multi-value register into a single dominating value).
  void replaceRegister(String fileId, MvRegister<FileState> register) {
    if (register.values.isEmpty) {
      _registers.remove(fileId);
    } else {
      _registers[fileId] = register;
    }
  }

  void remove(String fileId) {
    _registers.remove(fileId);
    _lastSyncedBlobRef.remove(fileId);
    _serverSeq.remove(fileId);
  }

  void recordSyncedBlobRef(String fileId, String blobRef) {
    if (blobRef.isEmpty) {
      _lastSyncedBlobRef.remove(fileId);
    } else {
      _lastSyncedBlobRef[fileId] = blobRef;
    }
  }

  void setServerCursor(int cursor) => _serverCursor = cursor;
  void setServerEpoch(int? epoch) => _serverEpoch = epoch;

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  Future<void> load() async {
    final records = await _client.listAllRecords(collection: _storeCol);
    _registers.clear();
    _ownLatestHlc = null;
    for (final r in records) {
      try {
        final reg = _decodeRegister(r.payload);
        if (reg.values.isEmpty) continue;
        final fileId = reg.values.first.value.fileId;
        _registers[fileId] = reg;
      } catch (_) {
        // Skip corrupt rows; they get rewritten on next put for that file.
      }
    }

    final meta = await _client.get(collection: _metaCol, id: _metaId);
    if (meta != null) {
      _serverCursor = (meta.payload['cursor'] as int?) ?? 0;
      _serverEpoch = meta.payload['epoch'] as int?;
      _deviceId = meta.payload['deviceId'] as String?;
      final ctxStr = meta.payload['ownContext'] as String?;
      _ownContext = ctxStr == null
          ? const CausalContext.empty()
          : CausalContext.unpack(ctxStr);
      _lastSyncedBlobRef.clear();
      final lsbr = meta.payload['lastSyncedBlobRef'] as Map?;
      if (lsbr != null) {
        for (final e in lsbr.entries) {
          _lastSyncedBlobRef[e.key as String] = e.value as String;
        }
      }
      _serverSeq.clear();
      final ss = meta.payload['serverSeq'] as Map?;
      if (ss != null) {
        for (final e in ss.entries) {
          final v = e.value;
          if (v is int) _serverSeq[e.key as String] = v;
        }
      }
    } else {
      _serverCursor = 0;
      _serverEpoch = null;
      _ownContext = const CausalContext.empty();
    }
    if (_deviceId == null) {
      _deviceId = const Uuid().v4();
      await persistMeta();
    }
    // Resume the Fugue Lamport clock from its persisted counter (best-effort:
    // see [_fugueClock]). A missing/absent counter starts at 0 — safe, since
    // [observeDots] lifts it above each file's own dots before every edit.
    final fugueCounter = (meta?.payload['fugueCounter'] as int?) ?? 0;
    _fugueClock = LamportClock(_deviceId!, fugueCounter);
    // Rebuild the device's own latest HLC by scanning surviving TaggedValues.
    for (final reg in _registers.values) {
      for (final tv in reg.values) {
        if (tv.hlc.nodeId == _deviceId) {
          if (_ownLatestHlc == null || tv.hlc > _ownLatestHlc!) {
            _ownLatestHlc = tv.hlc;
          }
        }
      }
    }
  }

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
    final reg = _registers[fileId];
    if (reg == null || reg.values.isEmpty) {
      try {
        await _client.delete(collection: _storeCol, id: fileId);
      } catch (_) {}
      return;
    }
    await _writeWithRetry(
      collection: _storeCol,
      id: fileId,
      payload: _encodeRegister(reg),
    );
  }

  Future<void> persistMeta() =>
      _serialise('meta', () => _persistMetaInner());

  Future<void> _persistMetaInner() async {
    final payload = {
      'cursor': _serverCursor,
      if (_serverEpoch != null) 'epoch': _serverEpoch,
      if (_deviceId != null) 'deviceId': _deviceId,
      'ownContext': _ownContext.pack(),
      'fugueCounter': _fugueClock?.value ?? 0,
      'lastSyncedBlobRef': _lastSyncedBlobRef,
      'serverSeq': _serverSeq,
    };
    await _writeWithRetry(
      collection: _metaCol,
      id: _metaId,
      payload: payload,
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
            msg.contains('already exists');
        if (!transient || attempt == 4) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 5 * (1 << attempt)));
      }
    }
  }

  /// Wipe everything: in-memory + persisted. deviceId survives (server
  /// continues to recognise this install across resets).
  Future<void> wipeAll() async {
    _registers.clear();
    _lastSyncedBlobRef.clear();
    _serverSeq.clear();
    _serverCursor = 0;
    _serverEpoch = null;
    _ownContext = const CausalContext.empty();
    _ownLatestHlc = null;
    try {
      await _client.deleteCollection(collection: _storeCol);
    } catch (_) {}
    try {
      await _client.deleteCollection(collection: _metaCol);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Register serialisation
  // ---------------------------------------------------------------------------

  /// Codec for the per-fileId register row. Schema versioning is owned
  /// by `convergent` (envelope `"v"`); payload-level `FileState`
  /// versioning lives in [FileState.toJson] / [FileState.fromJson].
  static const _registerCodec =
      MvRegisterCodec<FileState>(FileStateCodec());

  Map<String, dynamic> _encodeRegister(MvRegister<FileState> reg) =>
      _registerCodec.encode(reg)! as Map<String, dynamic>;

  MvRegister<FileState> _decodeRegister(Map<String, dynamic> payload) =>
      _registerCodec.decode(payload);
}
