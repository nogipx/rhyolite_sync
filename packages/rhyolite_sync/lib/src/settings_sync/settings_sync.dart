import 'dart:convert';
import 'dart:typed_data';

import 'package:convergent/convergent.dart';
import 'package:uuid/uuid.dart';

import '../contract/state_sync_contract.dart';
import '../crypto/i_vault_cipher.dart';
import '../crypto/vault_cipher.dart';
import 'canonical_json.dart';
import 'resource_crdt_codec.dart';
import 'settings_store.dart';

/// Settings sync orchestrator for the `<vaultId>_config` keyspace.
///
/// Rides the generic state-sync transport ([IStateSyncContract]) — the same
/// interface implemented by both the RPC caller and the server responder, so
/// this can be integration-tested directly against an in-memory responder.
///
/// Two-layer CRDT: the server keyspace is an outer multi-value register that
/// delivers concurrent encrypted versions and compacts dominated ones via
/// `contextPacked`; the inner convergent CRDT (per [ResourceCrdtCodec]) merges
/// the *contents*. Conflict resolution is therefore fully client-side and
/// coordination-free — no OCC, no conflict copies.
///
/// Profiles are encoded by the caller into `resourceId` (e.g.
/// `"<profile>/appearance.json"`); this layer is profile-agnostic.
class SettingsSync {
  SettingsSync({
    required IStateSyncContract remote,
    required SettingsStore store,
    required IVaultCipher cipher,
    required this.vaultId,
    required SettingsCrdtKind? Function(String resourceId) kindOf,
    void Function(String message)? log,
  }) : _remote = remote,
       _store = store,
       _cipher = cipher,
       _kindOf = kindOf,
       // Keyed record ids close the path-enumeration oracle (see
       // VaultCipher.deriveRecordIdKey). Null for a non-VaultCipher fake (tests).
       _recordIdKey =
           cipher is VaultCipher ? cipher.deriveRecordIdKey() : null,
       _log = log;

  final IStateSyncContract _remote;
  final SettingsStore _store;
  final IVaultCipher _cipher;
  final Uint8List? _recordIdKey;
  final String vaultId;
  final void Function(String message)? _log;

  /// Maps a resourceId to its CRDT kind, or null when the resource is unknown
  /// or its category is disabled for this device (selective sync). Resources
  /// are dynamic (any plugin's `data.json`), so this is a classifier rather
  /// than a fixed map.
  final SettingsCrdtKind? Function(String resourceId) _kindOf;

  /// resourceId -> decoded convergent state.
  final Map<String, Object> _state = {};
  bool _started = false;

  static const _uuid = Uuid();

  /// Per-session id stamped on every push as `sourceClientId`. The server
  /// echoes it in the notify payload, so the config-sync notify handler can
  /// recognise and ignore the echo of its OWN push instead of pulling its
  /// own change back (a re-upload otherwise self-notified once per file).
  /// A fresh id per instance is enough: the push and its echo always share
  /// one live [SettingsSync].
  final String clientId = _uuid.v4();

  /// Server record key for [resourceId]. The raw `.obsidian` path must NEVER be
  /// the server key: `fileId` travels in cleartext, so a path key would leak the
  /// settings file structure (installed plugins, enabled features) to the
  /// server even though contents are e2e-encrypted. Mirrors the notes engine
  /// (`uuid.v5(vaultId, relPath)`); the path itself rides inside the encrypted
  /// payload envelope (see [_push] / [pull]) so it can be recovered on pull.
  String _fileIdFor(String resourceId) {
    final key = _recordIdKey;
    return key == null
        ? _uuid.v5(vaultId, resourceId)
        : VaultCipher.recordId(key, vaultId, resourceId);
  }

  /// Marker for our encrypted payload envelope `{t, path, s}`. Records lacking
  /// it are legacy path-keyed rows (pre-hashing) or foreign — ignored on pull;
  /// settings re-seed from disk under the hashed key, so nothing is lost.
  static const _envelopeTag = 'rh1';

  /// Load persisted state and do an initial pull. Returns resources whose
  /// merged state differs from disk (caller renders + writes them).
  Future<Set<String>> start() async {
    if (_started) return const {};
    _started = true;
    final sw = Stopwatch()..start();
    await _store.load();
    final loadMs = sw.elapsedMilliseconds;

    // Drop rows that should not be carried forward:
    // - orphans: resources no longer synced (former plugin-code records);
    // - bloated: a runaway CRDT state that has grown far beyond any sane
    //   settings file (concurrent-value accumulation). Decoding + diffing +
    //   re-encrypting such a state froze the UI for ~80s on an 8.5 MB
    //   appearance.json. Dropping it re-seeds a clean state from disk on the
    //   next scan; the file on disk is the source of truth, so nothing is lost.
    var purged = 0;
    var reset = 0;
    for (final id in _store.resourceIds.toList()) {
      if (_kindOf(id) == null) {
        await _store.delete(id);
        purged++;
        continue;
      }
      final enc = _store.encodedState(id);
      if (enc != null && jsonEncode(enc).length > _maxStateBytes) {
        _log?.call('settings: reset bloated state $id');
        await _store.delete(id);
        reset++;
      }
    }

    // Convergent states are decoded LAZILY (see [_stateOf]). Eagerly decoding
    // every persisted state here blocked the UI thread for tens of seconds on
    // large vaults; a normal open with no remote/local change now decodes
    // nothing — only resources actually touched by a pull or a changed file pay
    // the decode cost.
    sw.reset();
    final changed = await pull();
    _log?.call('settings start: rows=${_store.resourceIds.length} '
        'purged=$purged reset=$reset load=${loadMs}ms '
        'pull=${sw.elapsedMilliseconds}ms');
    return changed;
  }

  /// A persisted encoded state above this is treated as a runaway CRDT and
  /// reset (re-seeded from disk). Sane settings records are kilobytes; the
  /// largest legitimate ones stay well under this.
  static const _maxStateBytes = 1 << 20; // 1 MiB

  /// Lazily decodes (and caches) the convergent state for [resourceId].
  Object _stateOf(String resourceId, ResourceCrdtCodec codec) =>
      _state[resourceId] ??= switch (_store.encodedState(resourceId)) {
        null => codec.emptyState(),
        final enc => codec.decodeState(enc),
      };

  /// Last-synced source signature for [resourceId] (opaque to this layer), or
  /// null if never synced. The platform layer uses it to skip unchanged files.
  String? sourceSigOf(String resourceId) => _store.sigOf(resourceId);

  /// Record a source signature without a content change — e.g. after writing a
  /// pulled version to disk, so the next scan recognises it as already synced.
  Future<void> recordSourceSig(String resourceId, String sig) =>
      _store.setSig(resourceId, sig);

  /// True when [diskBytes] already represent the same content as the
  /// resource's current merged state, so writing our canonical render would
  /// only reformat the file (reorder keys, minify) without changing anything.
  ///
  /// Lets the pull-write leave Obsidian's own natural-order format in place
  /// when the content matches — otherwise every synced file was rewritten to
  /// canonical form on each pull, fought Obsidian's format, and churned.
  bool diskMatchesRendered(String resourceId, Uint8List diskBytes) {
    final rendered = renderResource(resourceId);
    if (rendered == null) return false;
    if (_bytesEqual(diskBytes, rendered)) return true;
    // Opaque whole-file resources (CSS) are compared byte for byte — their
    // exact formatting is meaningful and there is no canonical form. Everything
    // else (fieldMap, orSet, jsonWholeFile) has a canonical JSON form, so a
    // pure reformat / key-reorder is treated as equal.
    if (_kindOf(resourceId) == SettingsCrdtKind.wholeFile) return false;
    return jsonCanonicalEqual(diskBytes, rendered);
  }

  /// Canonical rendered bytes for a resource, or null if unknown/empty.
  Uint8List? renderResource(String resourceId) {
    final kind = _kindOf(resourceId);
    if (kind == null) return null;
    // Genuinely empty (nothing persisted, nothing in memory) → null.
    if (!_state.containsKey(resourceId) &&
        _store.encodedState(resourceId) == null) {
      return null;
    }
    final codec = ResourceCrdtCodec.forKind(kind);
    return codec.renderState(_stateOf(resourceId, codec));
  }

  /// A fresh local file snapshot was observed; diff it into the CRDT and push.
  /// [sourceSig] is the platform's opaque signature for this file version; it is
  /// recorded even when the snapshot yields no CRDT change, so the next scan can
  /// skip this already-processed version.
  Future<void> applyLocalChange(
    String resourceId,
    Uint8List bytes, {
    String? sourceSig,
  }) async {
    final kind = _kindOf(resourceId);
    if (kind == null) return;
    final codec = ResourceCrdtCodec.forKind(kind);
    final cur = _stateOf(resourceId, codec);
    final next = codec.diffApply(cur, bytes, _store.nextHlc);
    if (identical(next, cur)) {
      if (sourceSig != null) await _store.setSig(resourceId, sourceSig);
      return;
    }
    _state[resourceId] = next;
    await _persist(resourceId, sig: sourceSig);
    await _push([resourceId]);
  }

  /// Pull remote records, fold via convergent join, and write back a
  /// dominating merge for any resource that had concurrent versions (so the
  /// server collapses them). Returns resources whose rendered bytes changed.
  Future<Set<String>> pull() async {
    final resp = await _remote.getStates(
      StateGetRequest(vaultId: vaultId, sinceCursor: _store.cursor),
    );

    // Records are keyed on the server by an opaque uuid — the path lives inside
    // the ciphertext, never on the wire. Decrypt first, recover the resourceId
    // from the envelope, then group by it. Records without our envelope marker
    // are legacy path-keyed rows (pre-hashing) or foreign: abandon them (the
    // resource re-seeds from disk under the hashed key, so nothing is lost).
    final byResource =
        <String, List<({Object? state, Hlc hlc, CausalContext ctx})>>{};
    for (final rec in resp.records) {
      final Object? decoded;
      try {
        final plain = await _cipher.decrypt(base64Decode(rec.encryptedState));
        decoded = jsonDecode(utf8.decode(plain));
      } catch (_) {
        continue; // undecryptable / foreign payload
      }
      if (decoded is! Map || decoded['t'] != _envelopeTag) continue;
      final resourceId = decoded['path'];
      if (resourceId is! String) continue;
      (byResource[resourceId] ??= []).add((
        state: decoded['s'],
        hlc: Hlc.unpack(rec.hlcPacked),
        ctx: CausalContext.unpack(rec.contextPacked),
      ));
    }

    final changed = <String>{};
    final needCompaction = <String>[];
    for (final entry in byResource.entries) {
      final resourceId = entry.key;
      final kind = _kindOf(resourceId);
      if (kind == null) continue; // unknown/disabled resource — leave on server
      final codec = ResourceCrdtCodec.forKind(kind);

      final before = _stateOf(resourceId, codec);
      final beforeBytes = codec.renderState(before);

      var state = before;
      var seen = _store.seenOf(resourceId);
      for (final item in entry.value) {
        final incoming = codec.decodeState(item.state);
        state = codec.joinStates(state, incoming);
        seen = seen.advance(item.hlc).merge(item.ctx);
        _store.observeHlc(item.hlc);
      }
      _state[resourceId] = state;
      _store.setSeen(resourceId, seen);
      await _persist(resourceId);

      if (!_bytesEqual(beforeBytes, codec.renderState(state))) {
        changed.add(resourceId);
      }
      if (entry.value.length > 1) needCompaction.add(resourceId);
    }

    _store.cursor = resp.cursor;
    await _store.persistMeta();

    if (needCompaction.isNotEmpty) {
      await _push(needCompaction);
    }
    return changed;
  }

  /// Re-upload: wipe the server config keyspace AND the local store so this
  /// device becomes the authoritative source. The caller then re-scans disk
  /// and pushes every enabled resource from scratch (see
  /// `ObsidianConfigSync.resetFromThisDevice`). Mirrors the notes "re-upload".
  Future<void> wipeServerAndLocal() async {
    await _remote.wipeVault(
      StateWipeRequest(vaultId: vaultId, sourceClientId: clientId),
    );
    _state.clear();
    await _store.wipeAll();
    _log?.call('settings: wiped server keyspace + local store');
  }

  /// Restore: discard local state and re-pull EVERYTHING from the server
  /// (cursor reset to 0), returning the resources to (over)write to disk.
  /// Mirrors the notes "download from server".
  Future<Set<String>> restoreFromServer() async {
    _state.clear();
    await _store.wipeAll(); // cursor -> 0, so the next pull re-reads all records
    return pull();
  }

  Future<void> _push(List<String> resourceIds) async {
    final items = <StatePutItem>[];
    for (final resourceId in resourceIds) {
      final kind = _kindOf(resourceId);
      final state = _state[resourceId];
      if (kind == null || state == null) continue;
      final codec = ResourceCrdtCodec.forKind(kind);
      // The resourceId (the `.obsidian` path) goes INSIDE the ciphertext; the
      // server key is an opaque uuid, so the settings file structure never
      // leaks in cleartext. The path is recovered from this envelope on pull.
      final payload = utf8.encode(jsonEncode({
        't': _envelopeTag,
        'path': resourceId,
        's': codec.encodeState(state),
      }));
      final enc = await _cipher.encrypt(Uint8List.fromList(payload));
      final outHlc = _store.nextHlc();
      final seen = _store.seenOf(resourceId);
      items.add(
        StatePutItem(
          fileId: _fileIdFor(resourceId),
          encryptedState: base64Encode(enc),
          blobRef: '',
          hlcPacked: outHlc.pack(),
          tombstone: false,
          contextPacked: seen.pack(),
        ),
      );
      // Our own write now belongs to what we've seen.
      _store.setSeen(resourceId, seen.advance(outHlc));
      await _persist(resourceId);
    }
    if (items.isEmpty) return;
    // Cursor is intentionally NOT advanced here — the next pull re-reads our
    // own write idempotently and advances the cursor then. [clientId] lets the
    // server-echoed notify be recognised as our own (skipped, not pulled).
    await _remote.putStates(
      StatePutRequest(vaultId: vaultId, items: items, sourceClientId: clientId),
    );
  }

  Future<void> _persist(String resourceId, {String? sig}) async {
    final kind = _kindOf(resourceId)!;
    final codec = ResourceCrdtCodec.forKind(kind);
    await _store.putResource(
      resourceId,
      codec.encodeState(_state[resourceId]!),
      _store.seenOf(resourceId),
      sig: sig,
    );
  }

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
