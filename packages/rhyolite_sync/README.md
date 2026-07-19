# rhyolite_sync

Δ-state CRDT file synchronization engine for Dart. Designed for
single-user multi-device file sync (notes, vaults, settings) with
end-to-end encryption and formal convergence guarantees.

Not a real-time collaboration framework (use Yjs/Automerge for that).
Not a generic database (use rpc_data directly). This is a focused
library for the **file-sync** problem: keep a tree of files in sync
across N devices owned by one user, survive offline edits and
network partitions, and prove mathematically that no data is lost.

---

## Table of contents

- [Why](#why)
- [What you get](#what-you-get)
- [What you must provide](#what-you-must-provide)
- [Architecture in one diagram](#architecture-in-one-diagram)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Required interfaces — one section each](#required-interfaces)
- [Bundled defaults](#bundled-defaults)
- [Public API surface](#public-api-surface)
- [CRDT semantics in 60 seconds](#crdt-semantics-in-60-seconds)
- [Conflict resolution](#conflict-resolution)
- [Wire protocol](#wire-protocol)
- [Server side](#server-side)
- [Limitations](#limitations)
- [Comparison with alternatives](#comparison-with-alternatives)
- [Testing & validation](#testing--validation)
- [Schema versioning](#schema-versioning)
- [Design documents](#design-documents)
- [License](#license)

---

## Why

Existing options for E2EE file sync each have a sharp edge:

- **Obsidian Sync**: closed-source, vendor-locked, conflict resolution
  is undocumented and produces conflict-copy files on overlap.
- **Syncthing**: P2P, but no E2EE between trusted devices, and conflict
  is just "keep both files with timestamp suffix".
- **WebDAV-based plugins**: file-by-file LWW, no merge, no chunking,
  bandwidth pain.
- **CouchDB-based LiveSync**: real-time but no real E2EE; the
  conflict story is CouchDB-revision-tree which leaks at scale.

`rhyolite_sync` is opinionated for the niche: single user, multiple
devices, you trust nobody (including your own server), and you want
provable convergence — not just "it usually works".

## What you get

- **Δ-state CRDT at file granularity** (see `docs/architecture/delta-state-crdt.md`).
  Per-file `MvRegister<FileState>` on the server; coordination-free
  writes; concurrent edits both survive until the resolver decides.
- **3-way text merge** layered on top of the CRDT — when two devices
  write the same file independently and resolver gets called, it
  attempts a real merge using `lastSyncedBlobRef` as base.
- **Content-defined chunking** (~1 MiB target). A 50 MB file with a
  small edit transfers only the changed ~1 MB chunk. Chunk dedup
  works across files within a vault.
- **End-to-end encryption** — server stores `encryptedState` opaque,
  per-vault key derived from the user's passphrase. The server can
  perform CRDT merges on plain metadata (HLC + CausalContext) without
  ever decrypting payload.
- **Per-device history heads** for safe history pruning (a device
  offline for a month never loses events it hasn't pulled yet).
- **HLC with self-stabilization** (Buffalo 2014 paper + §4 defence)
  so one device with broken clock can't poison the vault's ordering.
- **Schema versioning** in persistent format — future breaking
  migrations fail loudly with a clear error, not silent corruption.
- **OCP extension points** — events, use cases, strategy interfaces.
  UI features go in your plugin code without ever editing sync internals.

## What you must provide

The library is opinionated wherever it can be — it picks one CRDT, one
wire protocol, one transport (WebSocket), one cipher (Argon2id +
ChaCha20-Poly1305). The only points consumers fill in are the ones
that fundamentally differ per platform:

| Interface | Why platform-specific | Bundled default |
|---|---|---|
| `IPlatformIO` | Filesystem access (Obsidian JS / `dart:io` / Browser FS API) | none |
| `IChangeProvider` | File change events (FSEvents / inotify / Obsidian) | none |
| `IDataClient` (rpc_data) | Local persistence (SQLite / IndexedDB / in-memory) | rpc_data_sqlite, rpc_data_postgres |
| `BlobRepository` (rpc_blob) | Local blob cache (SQLite / FS / IndexedDB) | rpc_blob_sqlite |
| `IBlobStorage` | Remote blob backend | `RemoteBlobStorage`, `HttpBlobStorage`, `S3BlobStorage` |
| `IVaultMetaStorage` | Where to store external-blob-config blob (account server / user-side) | none (optional feature) |
| `IVaultCipher` | E2EE primitive | `VaultCipher` (Argon2id + XChaCha20-Poly1305) |
| `IStateConflictResolver` | Conflict semantics (you almost certainly want the default) | `StateConflictResolver` |
| `ITokenProvider` | Auth token (your auth server) | `StaticTokenProvider` (for tests/server-to-server) |

## Architecture in one diagram

```
                 ┌──────────────────────────────────────────┐
                 │              YOUR APPLICATION            │
                 │  (Obsidian plugin / CLI / Flutter app)   │
                 └──────────────────┬───────────────────────┘
                                    │
                                    │ creates + drives
                                    ▼
       ┌──────────────────────────────────────────────────┐
       │                StateSyncEngine                   │
       │  start() ─► pull ─► push ─► watch FS events      │
       │  events: Stream<SyncEngineEvent>                 │
       │  triggerPull / triggerReset / triggerRestore     │
       └────┬──────────────────────────────────────┬──────┘
            │                                      │
   ┌────────┴─────────┐                  ┌─────────┴───────────┐
   │  FileStateStore  │                  │  StateSyncContract  │
   │ Map<fileId,      │                  │  + HistoryContract  │
   │ MvRegister<FS>>  │                  │  + BlobContract     │
   │ + ownContext     │                  │ over RpcCallerEnd-  │
   │ + nextHlc()      │                  │ point (WebSocket)   │
   └────────┬─────────┘                  └─────────┬───────────┘
            │                                      │
   ┌────────┴─────────┐                            │
   │   IDataClient    │                            │
   │   (rpc_data)     │                            │
   │  any backend     │                            │
   └──────────────────┘                            │
                                                   ▼
                                  ┌──────────────────────────────┐
                                  │      rhyolite_sync_server    │
                                  │ StateSyncResponder           │
                                  │ HistoryResponder             │
                                  │ RhyoliteBlobResponder        │
                                  └──────────────────────────────┘
```

## Installation

Not on pub.dev yet. Use as a git dependency:

```yaml
dependencies:
  rhyolite_sync:
    git:
      url: https://github.com/nogipx/rhyolite_sync.git
      ref: <commit_sha>
      path: packages/rhyolite_sync

  # rhyolite_sync needs these (you'll get them transitively, but pin
  # them so dart pub get doesn't ride latest):
  replicated_state:
    git:
      url: https://github.com/nogipx/rhyolite_sync.git
      ref: <commit_sha>
      path: packages/replicated_state
```

For local development inside the rhyolite_sync workspace, use:

```yaml
dependencies:
  rhyolite_sync: any
```

with workspace resolution.

## Quick start

Minimal working example. This sketch leaves the platform adapters as
stubs — fill them in for your target.

```dart
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:rpc_blob_sqlite/rpc_blob_sqlite.dart';

Future<void> main() async {
  // 1. Local persistence (SQLite via rpc_data_sqlite adapter).
  final dataClient = IDataClient.repository(
    repository: SqliteDataRepository('/var/lib/myapp/state.db'),
  );

  // 2. Local blob cache.
  final blobRepo = SqliteBlobRepository('/var/lib/myapp/blobs.db');

  // 3. Crypto. Derive a key from the user's passphrase, or load saved.
  final cipher = await VaultCipher.fromPassphrase(
    passphrase: 'correct-horse-battery-staple',
    salt: existingSalt ?? VaultCipher.generateSalt(),
  );

  // 4. Wire everything up.
  final engine = StateSyncEngine(
    vaultPath: '/path/to/local/vault',
    serverUrl: 'wss://sync.yourdomain.com',
    config: VaultConfig(
      vaultId: 'b1d6cd5e-3f3a-4b2e-bd5a-fdf9a3c1b7f4',
      vaultName: 'My Notes',
      tokenProvider: StaticTokenProvider('your-bearer-token'),
      clientName: 'desktop/macos',
    ),
    cipher: cipher,
    dataClient: dataClient,
    blobStore: LocalBlobStore(blobRepo),
    io: MyPlatformIO(),
    changeProvider: MyChangeProvider(),
  );

  // 5. Listen to events.
  engine.events.listen((e) {
    print('sync event: $e');
  });

  // 6. Start.
  await engine.start();

  // ... the engine now syncs in the background.

  // Manual triggers (typically you don't need these — file watcher
  // + notify channel handle it):
  await engine.triggerPull();

  // On shutdown:
  await engine.dispose();
}
```

## Required interfaces

### `IPlatformIO` — filesystem access

Abstracts file reads, writes, listing, mtime. The default
implementations live outside this package:

- `ObsidianIO` (in `rhyolite_client_obsidian`) — wraps Obsidian's
  `app.vault` API
- `FilesystemIO` (in `rhyolite_client_filesystem`) — wraps `dart:io`

Implement this for your target. Minimum surface:

```dart
abstract interface class IPlatformIO {
  Future<Uint8List> readFile(String absPath);
  Future<void> writeFile(String absPath, Uint8List bytes);
  Future<bool> fileExists(String absPath);
  Future<void> deleteFile(String absPath);
  Future<List<String>> listFiles(String absRoot);
  Future<FileStat?> statFile(String absPath);
  // ... see src/platform/i_platform_io.dart
}
```

### `IChangeProvider` — file change events

Pushes a stream of `FileChangeEvent` (created/modified/deleted/moved)
that the engine subscribes to. Also has `suppress(relPath)` so the
engine can suppress its own writes from echoing back.

```dart
abstract interface class IChangeProvider {
  Stream<FileChangeEvent> get changes;
  void suppress(String relPath);
}
```

Implementations: `ObsidianChangeProvider` for Obsidian's event API,
`FilesystemChangeProvider` for `FileSystemEvent`-based watching on
desktops.

### `IDataClient` — local key-value persistence

The CRDT state is stored as JSON rows keyed by `fileId`. Use any
`IDataRepository` (the interface from rpc_data) via:

```dart
final dataClient = IDataClient.repository(
  repository: YourCustomDataRepo(),
);
```

Ready-made adapters: `rpc_data_sqlite`, `rpc_data_postgres`. For
Flutter web you'd write a `HiveDataRepository` or similar.

### `BlobRepository` — local blob cache

Chunked content is cached locally by sha256. Use any
`BlobRepository` from rpc_blob. Ready-made: `rpc_blob_sqlite`,
`InMemoryBlobRepository` (for tests).

### `IBlobStorage` — remote blob backend

How blobs get to and from the server. The default is
`RemoteBlobStorage` (uses the in-protocol BlobContract over the same
WebSocket). For bring-your-own-storage scenarios there's
`HttpBlobStorage` (WebDAV/HTTP) and `S3BlobStorage`.

### `IVaultMetaStorage` — opaque per-vault metadata

Optional. Used by `VaultMetaService` to persist the encrypted
external-blob-config so it survives reinstalls and travels to new
devices. Implement with whatever your platform offers:

```dart
abstract interface class IVaultMetaStorage {
  Future<String?> getEncryptedMeta(String vaultId);
  Future<void> setEncryptedMeta(String vaultId, String encryptedMeta);
}
```

If you don't ship external blob storage as a feature, pass `null`.

### `IVaultCipher` — E2EE primitive

`encrypt(bytes)` and `decrypt(bytes)`. Default
implementation: `VaultCipher` using Argon2id KDF + XChaCha20-Poly1305
AEAD. Implement your own if you want native libsodium / hardware-backed
keys / different KDF parameters.

### `IStateConflictResolver` — conflict policy

When `MvRegister<FileState>` ends up with > 1 surviving value,
the resolver collapses it to a single chosen FileState. The default
`StateConflictResolver` does:

1. All values share `blobRef` → max-HLC wins, no real conflict.
2. Tombstone vs edit → add-wins (edit survives, tombstone becomes a
   conflict-copy marker file).
3. Different text + base available → 3-way merge using
   `diff_match_patch`.
4. Otherwise → LWW by HLC + conflict-copy of the loser.

You can pass a custom factory via `resolverFactory` in the engine
constructor. Note: changing resolution semantics affects convergence
guarantees if peers use different resolvers — coordinate.

### `ITokenProvider` — auth token source

For your `BearerTokenInterceptor`. Implement to return the current
Bearer token for outgoing RPC calls. Refresh logic is yours.

## Bundled defaults

Things you get for free without writing adapter code:

| Default | When to use it |
|---|---|
| `VaultCipher` | Standard E2EE — Argon2id (m=64MiB, t=3, p=1) + XChaCha20-Poly1305 |
| `RemoteBlobStorage` | Blobs travel over the same WebSocket as state |
| `HttpBlobStorage` | Bring-your-own WebDAV / generic HTTP server |
| `S3BlobStorage` | Bring-your-own S3-compatible bucket |
| `EncryptedBlobStorage` | Wraps any `IBlobStorage` with encrypt-on-upload |
| `LocalBlobStore` | Generic wrapper around any `BlobRepository` |
| `ContentDefinedChunker` | Rabin-Karp fingerprint, configurable min/avg/max chunk size |
| `BearerTokenInterceptor` | RPC interceptor that injects Bearer header on every call |
| `StaticTokenProvider` | Test/server-to-server fixed token |
| `VaultMetaService` | Encrypt-wrap layer on top of any `IVaultMetaStorage` |

## Public API surface

What you actually call from your app code:

### Engine lifecycle

```dart
class StateSyncEngine {
  Future<void> start();
  Future<void> stop();
  Future<void> dispose();
  Future<void> triggerPull();
  Future<void> triggerReset();              // wipe server + re-upload
  Future<void> triggerRestoreFromServer();  // wipe local + re-pull
  Future<void> triggerRepair();             // same as triggerPull

  Stream<SyncEngineEvent> get events;

  // Builders for sub-features:
  FileVersionViewer? createFileVersionViewer();
  HistoryBrowser?    createHistoryBrowser();
  BlobJanitor?       createBlobJanitor();
}
```

### Events

The event taxonomy is **closed** for intrinsic sync concerns and
**open** for application policy via a single envelope. New business
rules (quota, rate limit, feature gates) never require editing
`rhyolite_sync` — they show up as new `code` values on
[`SyncServerRejected`](#syncserverrejected-envelope).

```dart
sealed class SyncEngineEvent {
  final DateTime timestamp;
}

// Lifecycle
class SyncStarted / SyncStopped / SyncConnecting / SyncConnected / SyncDisconnected

// File-level
class SyncFileCreated  { String path; }
class SyncFileModified { String path; }
class SyncFileDeleted  { String path; }
class SyncFileMoved    { String fromPath; String toPath; }
class SyncFilePushed   { String path; }
class SyncFilePulled   { String fileId; int nodeCount; String path; }

// CRDT layer
class SyncConflictAppeared  { String fileId; int valueCount; }
class SyncConflictResolved  { String fileId; String strategy; String winnerBlobRef; }
class SyncRecordSkipped     { String fileId; String hlcPacked; String reason; }
class SyncRegisterJoined    { String fileId; int incomingCount; int finalCardinality; }
class SyncCursorAdvanced    { int cursor; int recordCount; }
class SyncVaultReset        // server signalled a wipe

// Long-running operations
class SyncStartupBlobUploadProgress / SyncStartupBlobUploadDone
class SyncBlobDownloadProgress / SyncBlobDownloadDone

// Generic / failures
class SyncError(String message)
class SyncServerRejected(String code, String message, Map<String,dynamic> params)
class SyncLogMessage(String message)
```

#### `SyncServerRejected` envelope

This single event carries every server-side rejection that comes from
application policy or product-specific protocol extensions. Adding a
new code on the server requires zero edits to `rhyolite_sync`.

Standard codes (embedders may define more):

| Code | Meaning | `params` shape |
|---|---|---|
| `auth.session_expired` | Refresh token invalid; user must re-sign-in. Engine stops. | `{}` |
| `auth.permission_denied` | Caller does not own the vault. | `{}` |
| `app_policy.subscription_required` | No active subscription. Engine stops. | `{}` |
| `app_policy.quota.storage` | Vault storage quota exceeded | `{current, limit}` |
| `app_policy.quota.file_size` | File-size limit exceeded | `{current, limit}` |
| `app_policy.quota.vault_count` | Vault-count limit exceeded | `{current, limit}` |
| `app_policy.rate.push` | Push rate-limited | `{retry_after_ms}` |
| `feature.external_blob_config_discovered` | Server has a saved external blob config (engine already applied it) | `{kind: <string>}` (non-secret; no credentials) |

**Recommended:** define typed subclasses for the codes you care about
and pass a [`ServerRejectionFactory`](https://pub.dev/...) to the
engine constructor. The engine emits your typed instances; consumer
switches match on **types**, not on strings.

```dart
// In your app code (NOT in rhyolite_sync):
class SessionExpired extends SyncServerRejected {
  SessionExpired(String message)
      : super(code: 'auth.session_expired', message: message);
}

class StorageQuotaExceeded extends SyncServerRejected {
  StorageQuotaExceeded({
    required this.currentBytes,
    required this.limitBytes,
    required String message,
  }) : super(
          code: 'app_policy.quota.storage',
          message: message,
          params: {'current': '$currentBytes', 'limit': '$limitBytes'},
        );
  final int currentBytes;
  final int limitBytes;
}

// Wire the factory at engine creation:
final engine = StateSyncEngine(
  ...,
  rejectionFactory: (code, message, params) => switch (code) {
    'auth.session_expired' => SessionExpired(message),
    'app_policy.quota.storage' => StorageQuotaExceeded(
      currentBytes: int.parse(params['current'] ?? '0'),
      limitBytes: int.parse(params['limit'] ?? '0'),
      message: message,
    ),
    _ => null,  // unknown → engine emits raw SyncServerRejected
  },
);

// Pattern-match on types:
engine.events.listen((event) {
  switch (event) {
    case StorageQuotaExceeded(:final currentBytes, :final limitBytes):
      showStorageDialog(currentBytes, limitBytes);   // typed fields
    case SessionExpired():
      refreshTokenAndRestart();
    case SyncServerRejected(:final code):
      log.info('unhandled rejection: $code');         // fallback
    // … other event types
  }
});
```

**Server-side**, emit a rejection via `RpcException` using the
`app_policy.<dimension>:k1=v1,k2=v2` shape; the engine parses it,
calls your factory, and emits a typed instance:

```dart
throw RpcException(
  'app_policy.quota.storage:current=5368709120,limit=5368709120',
);
```

Adding a new policy on the server now requires:
- a new `RpcException` code (server)
- a new subclass + factory entry (consumer)
- zero edits to `rhyolite_sync`

### Use cases (call them from your UI)

```dart
// Stats: file count, tombstones, conflicting, unique blobs, total size.
final stats = VaultStatsUseCase(engine.store)();

// All fileIds currently in multi-value register state.
final conflicts = ConflictListUseCase(engine.store)();

// Escape hatch — decrypt vault into a target directory.
final report = await ExportVaultUseCase(
  store: engine.store,
  chunkedBlobIO: chunkedIO,
  targetIO: targetPlatformIO,
  targetRoot: '/tmp/my-export',
  localBlobStore: blobStore,
  vaultId: config.vaultId,
)(onProgress: (done, total) {
  print('exported $done / $total');
});
```

### Direct store access (read-only)

```dart
final store = engine.store;
store.fileIds                    // every fileId in local register set
store.get(fileId)                // single-value FileState, null if conflict
store.registerFor(fileId)        // MvRegister<FileState>?
store.hasConflict(fileId)        // bool
store.currentValues(fileId)      // List<FileState> — all concurrent values
store.singleValues               // Iterable<FileState> — skip conflicts
store.allValuesFlat              // Iterable<FileState> — flatten every register
store.lastSyncedBlobRefFor(fid)  // String? — 3-way merge base
```

## CRDT semantics in 60 seconds

Each file on the server is an **MvRegister of FileState** — a
multi-value register CRDT. The server keeps every concurrent write
that no other write has causally dominated, and drops anything that
has been dominated.

Properties (formally tested in `replicated_state/test/`):

- **Strong eventual consistency.** All replicas that have seen the
  same set of pushes produce identical state, regardless of order.
- **Coordination-free writes.** No CAS, no expectedVersion, no
  rejected pushes. A push is `register := register ⊔ {newValue}`.
- **Concurrent-edit preservation.** Two devices editing the same file
  concurrently produce a 2-value register; the resolver makes the
  call when collapsing it.
- **Causal ordering** via Hybrid Logical Clocks (Buffalo 2014 paper).

When does the resolver actually run? Only when there's true
divergence — concurrent edits that aren't causally related. Sequential
edits (`A writes → B pulls → B writes`) collapse automatically via
HLC + CausalContext.

See `docs/architecture/delta-state-crdt.md` (in this repo) for the
formal model.

## Conflict resolution

Triggered when `MvRegister<FileState>` has more than one value after
`applyRemote`. The default `StateConflictResolver` works pairwise on
the sorted list of concurrent FileStates:

1. **Same blob, same tombstone** → max-HLC wins. Pseudo-conflict.
2. **Tombstone vs edit** → edit wins (add-wins). The deleter's
   intent surfaces as a conflict-copy marker file.
3. **Different content, base available** → 3-way text merge via
   `diff_match_patch`. Base ref comes from `lastSyncedBlobRefFor` or
   `findHistoryBaseRef` callback (history service fallback).
4. **3-way merge couldn't apply cleanly** → LWW by HLC. Loser's
   content goes to `<path> (conflict 2026-06-01T12-34-56 from
   <nodeId>).<ext>` as a visible side-by-side file.

After collapse, the engine calls `store.applyLocal(merged)`, which
stamps the new TaggedValue with `ownContext` that strictly dominates
all losing HLCs. On next push the server sees a single value and
drops the losing ones — the conflict is "sealed by causal
dominance, not by deleting data" (doc §6).

## Wire protocol

Three contracts, defined under `lib/src/contract/`:

### `IStateSyncContract` — file state push/pull
- `putStates(vaultId, items[], expectedEpoch)` → results + cursor
- `getStates(vaultId, sinceCursor)` → records[] + cursor + epoch
- `wipeVault(vaultId)` → new epoch

### `IHistoryContract` — append-only history log
- `getHistory(vaultId, fileId?, fromHlc?, beforeHlc?, limit)`
- `deleteEvents(vaultId, eventIds[])` — user-triggered cleanup
- `reportHistoryHead(vaultId, deviceId, headSeq)` — for safe pruning
- `getHistoryHeads(vaultId)` → per-device last-seen seq

### `IBlobContract` — chunk storage
Standard rpc_blob contract over the same endpoint.

### Wire types

```dart
StatePutItem {
  String fileId;
  String encryptedState;      // opaque to server
  String blobRef;             // plain — sha256 manifest hash
  String hlcPacked;           // plain — HLC of writer
  String contextPacked;       // plain — CausalContext of writer
  bool   tombstone;
  List<String> chunks;        // plain — chunk hashes for GC
}

StateRecord {
  // same fields + serverSeq (assigned at write time)
}
```

The server's MvRegister.join algorithm runs entirely on plain
metadata (hlc + context). `encryptedState` is opaque — the server
never decrypts.

## Server side

The runnable server lives in `rhyolite_sync_daemon` (this repo). The
pure responder library is `rhyolite_sync_server`. To run your own:

```dart
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync_server/rhyolite_sync_server.dart';

final stateResp = StateSyncResponder(
  client: dataClient,          // your IDataClient
  blobClient: blobClient,      // optional, for blob GC
  vaultAuthRepository: ...,    // optional, for ACL
  subscriptionRepository: ..., // optional, for billing
  notifyRepository: ...,       // optional, for push notify
);

final historyResp = HistoryResponder(client: dataClient, ...);
final blobResp = RhyoliteBlobResponder(blobClient: blobClient, ...);

// Register with rpc_dart endpoint, expose over WebSocket.
```

Or just use the bundled daemon (`rhyolite_sync_daemon`) which wires
Postgres + MinIO + auth.

## Limitations

Honest list of what this library does NOT do:

- **No real-time intra-document collab.** Two devices editing the
  same paragraph at the same second will conflict-copy or 3-way
  merge. For sub-second character-level convergence use Yjs / Y-Dart.
- **No multi-user vaults.** The protocol is single-user, multi-device.
  Multi-user permissions and access control are explicitly out of
  scope (§13 of the design doc — compatible with the model, not
  implemented).
- **No selective sync.** Every device pulls the full vault. Partial
  sync (only some folders) requires protocol changes.
- **No native push notifications.** The library uses
  WebSocket-pinned notify; for true mobile push (FCM/APNS) you'd
  layer that on top.
- **Initial pull is not paginated.** A first sync on a 10k-file
  vault is one big RPC. Add `limit` to `StateGetRequest` if you hit
  this.
- **HLC drift detection** is bounded at 5 minutes by default
  (`FileStateStore.defaultMaxClockSkewMs`). A device with broken
  wall clock beyond that window will be ignored. Tune at your risk.
- **The wire protocol is not stable across major versions.** Schema
  versioning catches mismatches but does not migrate data — a major
  bump is "wipe + restore".

## Comparison with alternatives

| | rhyolite_sync | Obsidian Sync | Syncthing | WebDAV plugins | LiveSync (CouchDB) |
|---|---|---|---|---|---|
| Granularity | File | File | File | File | Document |
| Algorithm | Δ-state CRDT | LWW (undocumented) | LWW | LWW + rename | CouchDB rev-tree |
| Provable convergence | ✓ | ✗ | ✗ | ✗ | partial |
| 3-way text merge | ✓ | ✗ | ✗ | ✗ | partial |
| E2EE | server-blind | claimed | TLS-only | optional | weakened |
| Chunk dedup | CDC ~1 MiB | unknown | ~128 KiB | none | none |
| Real-time | near (notify) | near (notify) | LAN-fast (P2P) | poll | yes (CouchDB feed) |
| Selective sync | ✗ | folders | ✓ | partial | ✓ |
| Multi-user | ✗ | tier paid | trusted devices | depends | depends |
| Open source | yes (this) | no | yes | mixed | yes |

## Testing & validation

The library ships with 74 unit + integration tests plus 35 server-side
responder tests, plus 68 property tests on the CRDT primitives. Run:

```bash
fvm dart test                        # in packages/rhyolite_sync
fvm dart test                        # in packages/rhyolite_sync_server
fvm dart test                        # in packages/replicated_state
```

Property tests on `MvRegister.join` verify (in
`replicated_state/test/mv_register_test.dart`):

- commutativity: `a.join(b) == b.join(a)`
- associativity: `a.join(b).join(c) == a.join(b.join(c))`
- idempotency: `a.join(a) == a`
- monotonicity: `a.join(b) ⊇ a` in dominance order
- causal correctness: dominated values dropped, concurrent ones kept
- any-order convergence on permutations

Two-client integration smoke
(`rhyolite_sync_server/test/two_client_convergence_test.dart`)
simulates two devices with one in-memory server, covering causal
flow, concurrent edits, tombstone vs edit, and burst convergence.

## Schema versioning

Persistent and wire formats carry a `'v': N` field. Bumping it makes
all consumers reject older data with `FormatException` instead of
silently corrupting:

- `FileState.schemaVersion` = 1 (persistent + wire payload)
- `FileStateStore.registerSchemaVersion` = 1 (per-fileId row)

A breaking change to either is a major version of this library AND a
forced wipe for all deployed devices. Don't bump lightly.

## Design documents

In this repo:

- `docs/architecture/delta-state-crdt.md` — the formal Δ-state CRDT
  model, 14 sections covering motivation, properties, data model,
  wire protocol, server/client algorithms, conflict resolution, math
  invariants, GC, migration, trade-offs, implementation phases,
  deferred items, acceptance criteria.
- `docs/architecture/production-readiness.md` — verified-against-code
  audit with concrete triggers for the deferred items.
- `docs/architecture/crdt-audit.md` — historical notes from the
  pre-CRDT era.

External references:

- HLC paper: Kulkarni et al., "Logical Physical Clocks and Consistent
  Snapshots in Globally Distributed Databases", Buffalo TR 2014-04.
  https://cse.buffalo.edu/tech-reports/2014-04.pdf
- Δ-state CRDTs: Almeida, Shoker, Baquero, "Efficient State-based
  CRDTs by Delta-Mutation", arXiv:1410.2803.

## License

To be decided. Currently all-rights-reserved as part of the rhyolite
suite. If you need to use this in production before a public license
lands, open an issue.
