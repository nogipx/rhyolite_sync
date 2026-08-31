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
  FileStateStore({
    required IDataClient client,
    required this.vaultId,
    String? deviceId,
  }) : _client = client,
       _configuredDeviceId = deviceId;

  final IDataClient _client;
  final String vaultId;

  /// Identity supplied by the host, which stores it somewhere this database
  /// cannot take with it when it goes.
  ///
  /// The id used to live only in the meta row here, and every event that
  /// recreates the database — a reset, a restore, a recovery from corruption —
  /// therefore minted a new one. The server saw a new device each time, and
  /// each phantom head pinned `min(headSeq)` down, freezing tombstone GC for
  /// the full stale window. When the host supplies an id, none of that can
  /// happen: the database is disposable, the identity is not.
  final String? _configuredDeviceId;

  String get _storeCol => '${vaultId}_state_store';
  String get _metaCol => '${vaultId}_state_meta';
  static const _metaId = 'meta';

  // ---------------------------------------------------------------------------
  // In-memory state
  // ---------------------------------------------------------------------------

  final Map<String, MvRegister<FileState>> _registers = {};
  final Map<String, String> _lastSyncedBlobRef = {};

  /// Signature of the record this device last got the server to accept, per
  /// file. Answers "does the server already hold this?", which is a DIFFERENT
  /// question from [_lastSyncedBlobRef]'s "what is the convergence point with
  /// other devices" — conflating them is what made every startup re-push every
  /// file this device had authored.
  ///
  /// Push cannot advance the LCA (two devices pushing concurrently would each
  /// seed their own blob as the merge base and diverge), so a file authored
  /// here and never pulled back had no record of having been sent. The server
  /// skips the insert when the HLC already matches, so nothing came back to
  /// apply, and the loop had no exit.
  ///
  /// Lives on the per-file row rather than in the meta row: it is per-file
  /// data, [persistOne] already writes that row right after a successful push,
  /// and `wipeAll` drops the whole collection — so a vault reset clears these
  /// without any separate bookkeeping.
  final Map<String, String> _lastPushedSignature = {};

  /// Files whose per-file row already carries the LCA and serverSeq.
  ///
  /// The migration is lazy and self-healing: a row is rewritten by the
  /// persistOne that already follows every write of these values, and the id
  /// then leaves this set, so the meta row shrinks on its own. Nothing
  /// enumerates the vault to convert it, and there is no version flag —
  /// correct at every intermediate point, because a value is read from the row
  /// when the row has it and from meta otherwise.
  ///
  /// Order matters and is enforced in [_persistOneInner]: the row is written
  /// FIRST, the id leaves this set after. A crash in between leaves the value
  /// in both places, and the row wins — harmless. The reverse order would lose
  /// it.
  final Set<String> _migratedIds = {};

  /// fileId → the max serverSeq at which this device has pulled a record for
  /// the file. The causal-stability boundary for tombstone GC: a tombstone is
  /// safe to drop only once every active device's pull cursor (headSeq) has
  /// passed its serverSeq. Persisted in meta alongside [_lastSyncedBlobRef].
  final Map<String, int> _serverSeq = {};

  CausalContext _ownContext = const CausalContext.empty();
  int _serverCursor = 0;
  int? _serverEpoch;

  /// Whether this vault has ever received a DEFINITE answer about where its
  /// blobs belong — managed, or a specific external backend.
  ///
  /// Absence of a BYO marker used to mean two different things at once: "the
  /// server told us there is no external storage" and "we have never managed
  /// to ask". The second was treated as the first, so a vault whose config
  /// lookup timed out uploaded to the managed backend by default. One user
  /// filled a gigabyte of our storage that way, having asked for their own.
  ///
  /// Kept here rather than in [VaultConfig] because losing it is the SAFE
  /// direction: a reset database re-asks, and until it has an answer it
  /// refuses rather than guesses. The BYO marker itself stays in the config,
  /// where it survives a reset, because losing THAT is the unsafe direction.
  bool _storageResolved = false;
  bool get storageResolved => _storageResolved;

  /// Records that the backend question has been answered. Call [persistMeta]
  /// to write it down.
  void markStorageResolved() => _storageResolved = true;

  bool _loadedEmpty = false;

  /// [load] found NOTHING persisted: no meta row and no register rows.
  ///
  /// True on a genuinely first run — and equally true when a database that
  /// once held state is gone (evicted browser storage, a failed open that fell
  /// back to an in-memory VFS, a manual reset). This store cannot tell those
  /// apart; only the host can, by comparing against an identity it persists
  /// OUTSIDE this database (see [VaultConfig.deviceId]). The engine does that
  /// comparison and emits [SyncLocalStateLost].
  bool get loadedEmpty => _loadedEmpty;

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

  /// The identity, or null before [load] has run. Hosts read this once after
  /// start to adopt the id a pre-existing database already carries, instead of
  /// minting a second one for the same install.
  String? get deviceIdOrNull => _deviceId;

  String get deviceId =>
      _deviceId ??
      (throw StateError('FileStateStore.deviceId accessed before load()'));

  CausalContext get ownContext => _ownContext;
  int get serverCursor => _serverCursor;
  int? get serverEpoch => _serverEpoch;

  Iterable<String> get fileIds => _registers.keys;

  /// Files whose current value the server may not have yet.
  ///
  /// A CONSERVATIVE SUPERSET, and deliberately so: it is grown by every write
  /// to a register and shrunk only when a push is acknowledged or the pusher
  /// classifies a member as owing nothing. Over-inclusion costs one extra
  /// comparison; under-inclusion loses a file, so the set is never asked to be
  /// clever about what "dirty" means. That judgement stays in `_collectDirty`,
  /// which is the only place it has ever lived.
  ///
  /// It exists because the push path had no cheap way to answer "what does the
  /// server not know about" and so re-derived it by walking every file, every
  /// time. On a 9121-file vault that ran on each interactive edit — one file
  /// changes, nine thousand are examined, and the code marking that one file
  /// pending sits on the line above.
  Iterable<String> get owedFileIds => _owed;

  /// Drops ids the pusher has determined owe the server nothing.
  void clearOwed(Iterable<String> fileIds) => _owed.removeAll(fileIds);

  final Set<String> _owed = {};
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

  bool hasConflict(String fileId) => _registers[fileId]?.hasConflict ?? false;

  /// All concurrent values for a fileId. Empty when the file is missing.
  List<FileState> currentValues(String fileId) =>
      _registers[fileId]?.allValues ?? const [];

  String? lastSyncedBlobRefFor(String fileId) => _lastSyncedBlobRef[fileId];

  /// The record this device last got the server to accept for [fileId], or
  /// null if it has never had one accepted.
  String? lastPushedSignatureFor(String fileId) => _lastPushedSignature[fileId];

  /// Records that the server accepted [signature] for [fileId]. Call before
  /// [persistOne], which is what writes it down.
  void recordPushedSignature(String fileId, String signature) {
    _lastPushedSignature[fileId] = signature;
    // The server has this exact value. A later write re-adds it.
    _owed.remove(fileId);
  }

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
    _owed.add(value.fileId);
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
    // A remote value usually owes nothing — the server is where it came from.
    // But the join can leave OUR concurrent value unpublished beside it, and
    // that one is owed. Cheaper to include and let the classifier decide than
    // to reason about it here.
    _owed.add(fileId);
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
      _owed.remove(fileId);
    } else {
      _registers[fileId] = register;
      // The resolver seals a NEW value here; nobody has it but us.
      _owed.add(fileId);
    }
  }

  void remove(String fileId) {
    _registers.remove(fileId);
    _lastSyncedBlobRef.remove(fileId);
    _serverSeq.remove(fileId);
    _lastPushedSignature.remove(fileId);
    _migratedIds.remove(fileId);
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
    _owed.clear();
    _ownLatestHlc = null;
    for (final r in records) {
      try {
        final reg = _decodeRegister(r.payload);
        if (reg.values.isEmpty) continue;
        final fileId = reg.values.first.value.fileId;
        _registers[fileId] = reg;
        // Absent on rows written before this existed: the file is then treated
        // as never pushed, costing one redundant push apiece, once.
        final signature = r.payload[_pushedSignatureKey];
        if (signature is String) _lastPushedSignature[fileId] = signature;

        // A row carrying the LCA key has been migrated, and is authoritative
        // even when the value is empty — empty means "no LCA", not "unknown".
        final lca = r.payload[_lcaKey];
        if (lca is String) {
          _migratedIds.add(fileId);
          if (lca.isNotEmpty) _lastSyncedBlobRef[fileId] = lca;
          final seq = r.payload[_serverSeqKey];
          if (seq is int) _serverSeq[fileId] = seq;
        }
      } catch (_) {
        // Skip corrupt rows; they get rewritten on next put for that file.
      }
    }

    final meta = await _client.get(collection: _metaCol, id: _metaId);
    // Captured BEFORE the branches below mint a deviceId and write meta back:
    // after that the store looks initialised and the distinction is gone.
    _loadedEmpty = meta == null && _registers.isEmpty;
    if (meta != null) {
      _serverCursor = (meta.payload['cursor'] as int?) ?? 0;
      _serverEpoch = meta.payload['epoch'] as int?;
      _deviceId = meta.payload['deviceId'] as String?;
      _storageResolved = (meta.payload['storageResolved'] as bool?) ?? false;
      final ctxStr = meta.payload['ownContext'] as String?;
      _ownContext = ctxStr == null
          ? const CausalContext.empty()
          : CausalContext.unpack(ctxStr);
      // Whatever has not migrated yet. A row that carries the values already
      // supplied them above and wins, so meta is consulted only for the rest —
      // which is what lets the two coexist while the vault drains.
      final lsbr = meta.payload['lastSyncedBlobRef'] as Map?;
      if (lsbr != null) {
        for (final e in lsbr.entries) {
          final id = e.key as String;
          if (_migratedIds.contains(id)) continue;
          final v = e.value;
          if (v is String && v.isNotEmpty) _lastSyncedBlobRef[id] = v;
        }
      }
      final ss = meta.payload['serverSeq'] as Map?;
      if (ss != null) {
        for (final e in ss.entries) {
          final id = e.key as String;
          if (_migratedIds.contains(id)) continue;
          final v = e.value;
          if (v is int) _serverSeq[id] = v;
        }
      }
    } else {
      _serverCursor = 0;
      _serverEpoch = null;
      _ownContext = const CausalContext.empty();
    }
    // Host-supplied identity wins over whatever this database remembers, and
    // is written back so the two agree. A mismatch is normal exactly once:
    // on the first run after the host adopts the id this store already had.
    final configured = _configuredDeviceId;
    if (configured != null && configured != _deviceId) {
      _deviceId = configured;
      await persistMeta();
    } else if (_deviceId == null) {
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
    // Everything is a candidate after a load, and it has to be: nothing else
    // survives a restart. The host's pending set is memory-only, and the
    // startup diff writes states without telling anyone — so if this set began
    // empty, a vault with unsent files would upload nothing and report nothing
    // wrong, which is the failure this set exists to make impossible.
    //
    // The first push then classifies them and drops what owes nothing. That is
    // one full pass per load, which is what every push used to cost.
    _owed.addAll(_registers.keys);
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
    final signature = _lastPushedSignature[fileId];
    final seq = _serverSeq[fileId];
    await _writeWithRetry(
      collection: _storeCol,
      id: fileId,
      payload: {
        ..._encodeRegister(reg),
        // Siblings of the register's own keys. MvRegisterCodec.decode reads
        // `v` and `values` and ignores the rest, so these ride along without a
        // format change or extra rows to keep in step.
        if (signature != null) _pushedSignatureKey: signature,
        // Always written, empty included — see [_lcaKey].
        _lcaKey: _lastSyncedBlobRef[fileId] ?? '',
        if (seq != null) _serverSeqKey: seq,
      },
    );
    // Only after the row is safely written. Until then meta must keep its copy,
    // or a crash here would lose the value entirely.
    _migratedIds.add(fileId);
  }

  Future<void> persistMeta() => _serialise('meta', () => _persistMetaInner());

  Future<void> _persistMetaInner() async {
    final payload = {
      'cursor': _serverCursor,
      if (_serverEpoch != null) 'epoch': _serverEpoch,
      if (_deviceId != null) 'deviceId': _deviceId,
      'ownContext': _ownContext.pack(),
      'fugueCounter': _fugueClock?.value ?? 0,
      if (_storageResolved) 'storageResolved': true,
      // Only what has not moved to a per-file row yet. This shrinks to nothing
      // as the vault is touched, which is the point: it used to hold every
      // file's entry and was re-read and rewritten whole on every call.
      'lastSyncedBlobRef': {
        for (final e in _lastSyncedBlobRef.entries)
          if (!_migratedIds.contains(e.key)) e.key: e.value,
      },
      'serverSeq': {
        for (final e in _serverSeq.entries)
          if (!_migratedIds.contains(e.key)) e.key: e.value,
      },
    };
    await _writeWithRetry(collection: _metaCol, id: _metaId, payload: payload);
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

  /// Wipe everything: in-memory + persisted. deviceId survives (server
  /// continues to recognise this install across resets).
  ///
  /// That promise is the whole point of this method's shape. Dropping the meta
  /// collection wholesale would take `deviceId` with it, and the loss is
  /// invisible until the NEXT load: this instance keeps the id in memory, so
  /// the running session looks fine, and only after a restart does [load]
  /// find no meta row and mint a fresh uuid. The server then sees a brand-new
  /// device — one more head per reset, per install, accumulating until the
  /// stale-head sweep 90 days later.
  Future<void> wipeAll() async {
    // The engine wipes through a freshly constructed store (see
    // StateSyncEngine.triggerReset), which has never loaded and therefore has
    // no id in memory. Recover it from storage before the row is rewritten.
    _deviceId ??= _configuredDeviceId;
    if (_deviceId == null) {
      try {
        final meta = await _client.get(collection: _metaCol, id: _metaId);
        _deviceId = meta?.payload['deviceId'] as String?;
      } catch (_) {
        // Unreadable meta means there is no id to preserve; load() will mint
        // one, which is the same outcome as before this guard existed.
      }
    }

    _registers.clear();
    _lastSyncedBlobRef.clear();
    _serverSeq.clear();
    _lastPushedSignature.clear();
    _migratedIds.clear();
    _serverCursor = 0;
    _serverEpoch = null;
    _ownContext = const CausalContext.empty();
    _ownLatestHlc = null;
    try {
      await _client.deleteCollection(collection: _storeCol);
    } catch (_) {}
    // Rewrite meta rather than dropping it — same reset semantics (cursor 0,
    // no epoch, empty context), but the identity of this install stays.
    await persistMeta();
  }

  // ---------------------------------------------------------------------------
  // Register serialisation
  // ---------------------------------------------------------------------------

  /// Codec for the per-fileId register row. Schema versioning is owned
  /// by `convergent` (envelope `"v"`); payload-level `FileState`
  /// versioning lives in [FileState.toJson] / [FileState.fromJson].
  /// Key for [_lastPushedSignature] inside a per-file row.
  static const _pushedSignatureKey = 'pushedSig';

  /// Keys for the two per-file facts that used to live in the meta row.
  ///
  /// [_lcaKey] is written on EVERY persistOne, empty string included, because
  /// its presence is what marks a row as migrated. Without that marker a file
  /// that simply has no LCA would be indistinguishable from one not yet moved,
  /// and the meta fallback would keep resurrecting a value the row had
  /// deliberately cleared.
  static const _lcaKey = 'lca';
  static const _serverSeqKey = 'srvSeq';

  static const _registerCodec = MvRegisterCodec<FileState>(FileStateCodec());

  Map<String, dynamic> _encodeRegister(MvRegister<FileState> reg) =>
      _registerCodec.encode(reg)! as Map<String, dynamic>;

  MvRegister<FileState> _decodeRegister(Map<String, dynamic> payload) =>
      _registerCodec.decode(payload);
}
