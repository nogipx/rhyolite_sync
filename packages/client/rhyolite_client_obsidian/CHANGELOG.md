## [3.0.2] - 2026-07-06

### Fixed

- Filenames whose characters have more than one Unicode form — accented Latin or Cyrillic letters like «й»/«ё» — no longer sync as phantom duplicates between macOS/iOS and other platforms. Paths are normalized (NFC) so the same file keeps a single identity across devices instead of churning forever (core).


## [3.0.1] - 2026-07-06

### Changed

- Repository and container image URLs moved to the project's standalone account (obsidian, deploy).


## [2.7.0] - 2026-07-04

### Features

- keyed blob ids + persistent startup change-detection (core)

### Other

- bump version to 2.7.0 (obsidian)


## [2.6.0] - 2026-07-02

### Features

- map external_storage_unavailable rejection (obsidian)
- enable External Storage (BYO) for self-host (obsidian)
- gate External Storage to managed Pro tier (obsidian)
- self-host UX in settings tab (obsidian)
- self-host mode in the plugin (obsidian)
- IVaultDirectory seam (managed + self-host) (obsidian)
- vault registry contract (core)

### Bug Fixes

- bound self-host registry connect + reset vault on edition switch (obsidian)
- keep self-host token on config rebuild + fix offref crash (obsidian)
- apply self-host without manual reload + never prompt account (obsidian)

### Refactoring

- move shared auth surface into engine (core)

### Other

- bump version to 2.6.0 (obsidian)
- bump rpc_dart to d5a665e (core)


## [2.5.0] - 2026-06-22

### Features

- own the task scheduler, serialize engine restarts (obsidian)
- host-owned task scheduler behind ITaskScheduler (core)
- route settings sync through the engine background scheduler (obsidian)
- expose scheduleBackground hook for sibling subsystems (core)
- run GC + blob-verify as preemptible background tasks (core)
- add universal PriorityTaskScheduler (scheduler foundation) (core)

### Bug Fixes

- re-arm notify on resume when the socket is alive (obsidian)
- self-healing notify + explicit reissue hook (core)
- drain startup edits synchronously so notes sync before settings (core)
- capture file edits made during engine startup (core)
- keep both versions on divergent text conflict via CRDT line-union (core)

### Refactoring

- route engine sync work through PriorityTaskScheduler (core)
- decompose StateSyncEngine into testable collaborators (core)

### Other

- bump version to 2.5.0 (obsidian)
- pin that engine.stop() spares the host-owned scheduler (core)


## [2.4.0] - 2026-06-21

### Features

- re-upload / download buttons for settings sync (obsidian)
- notify-driven settings sync + indicator activity (obsidian)

### Bug Fixes

- reissue notify subscription on reconnect (core)
- persist session on every refresh to survive token rotation (account)
- hash settings-sync fileId to stop leaking .obsidian paths (core)

### Other

- bump version to 2.4.0 (obsidian)
- rename secret keys to rhyolite-vault-key / rhyolite-auth-token (obsidian)


## [2.3.0] - 2026-06-20

### Features

- verify blob durability with ack-check + bulkExists, auto-heal orphans (core)
- retry transient RPC failures with backoff (rate limit, unavailable) (core)
- VaultCipher to AES-256-GCM (WebCrypto/hardware-accelerated) (core)
- move settings-sync section to bottom, collapse behind <details> (obsidian)
- drop settings-sync polling timer, add manual sync command (obsidian)
- drop plugin-code sync entirely (installedPlugins category) (obsidian)
- .obsidian settings sync (opt-in, default off) (obsidian)
- settings sync CRDT engine for .obsidian config keyspace (core)

### Bug Fixes

- retry transient "First chunk must carry blobId" upload error (core)
- route text files through Fugue reconciler in StartupDiff (core)
- batch blob exists probe to avoid RPC call timeout on large vaults (core)
- drop runaway-bloated settings states on start (one-time heal) (core)
- skip large wholeFile settings (pure-Dart cipher freezes UI) (obsidian)
- relaunch settings sync after auth recovery restarts (obsidian)
- core-plugins.json is fieldMap, isolate per-resource push errors (obsidian)

### Other

- bump version to 2.3.0 (obsidian)
- lazy-decode settings states + purge orphan rows (fixes 81s open freeze) (core)
- timing logs for settings-sync startup phases (core)


## [2.2.1] - 2026-06-15

### Bug Fixes

- defer auto sign-in modal instead of stacking on resume (obsidian)

### Refactoring

- remove dead Migrate-blobs button from settings (obsidian)

### Other

- bump version to 2.2.1 (obsidian)


## [2.2.0] - 2026-06-15

### Features

- gzip blob compression decorator (core)
- blob transfer hub, parallel startup upload, disconnect wipe (core)
- include PlanCapabilities in SubscriptionDto (account)
- extend refresh TTL to 180d, retry once on unauthenticated (account)

### Other

- bump version to 2.2.0 (obsidian)


## [2.1.1] - 2026-06-12

### Other

- bump version to 2.1.1 (obsidian)


## [2.1.0] - 2026-06-12

### Bug Fixes

- wipe local blob cache on triggerRestoreFromServer too (core)
- wipe local blob cache on triggerReset (core)

### Refactoring

- replace PASETO v4.local with raw XChaCha20-Poly1305 in VaultCipher (core)

### Other

- bump version to 2.1.0 (obsidian)
- interleave blob prefetch with apply in _pull (batch=8) (core)


## [2.0.14] - 2026-06-10

### Features

- switch text reconcile to Sequence.applyOps batch (core)

### Other

- bump version to 2.0.14 (obsidian)


## [2.0.13] - 2026-06-07

### Features

- amber idle dot when there are unsynced local edits (obsidian)
- SyncPending event + incremental dirty tracking (core)

### Bug Fixes

- drop _seedPendingFromStore — caused permanent amber on start (core)
- mark pending immediately on text disk event (core)

### Other

- bump version to 2.0.13 (obsidian)
- hide progress counter when total <= 1 (obsidian)
- drop bare status labels, keep only progress counters (obsidian)
- unify push/pull dot color (both blue) (obsidian)


## [2.0.12] - 2026-06-07

_No client-facing changes._


## [2.0.11] - 2026-06-07

### Features

- resume-aware health check + push/pull color split (obsidian)
- healthCheck + RPC deadlines + pushing/pulling events (core)
- promo code input + live preview in payment modal (obsidian)
- expose discountCode in createPayment + previewDiscount client (account)

### Bug Fixes

- emit terminal SyncFilePulled so indicator can leave pulling (core)
- use awaiter-level timeout, not RpcContext deadline (core)

### Other

- bump version to 2.0.11 (obsidian)
- text edit debounce 5s -> 3s (core)


## [2.0.10] - 2026-06-06

_No client-facing changes._


## [2.0.9] - 2026-06-06

### Other

- bump version to 2.0.9 (obsidian)


## [2.0.8] - 2026-06-06

### Other

- bump version to 2.0.8 (obsidian)
- minLevel=warning in release builds + tidy CONTRIBUTING (obsidian)
- clarify CONTRIBUTING — main.js is a release artifact, not committed (obsidian)
- repo layout + README + CONTRIBUTING for plugin scorecard (obsidian)
- gate dev log collector behind RHYOLITE_DEBUG (obsidian)


## [2.0.7] - 2026-06-06

### Other

- bump version to 2.0.7 (obsidian)
- StartupDiff fast-path for empty + multi-chunk files (core)
- diagnostic log for StartupDiff pending files (core)


## [2.0.6] - 2026-06-06

### Other

- bump version to 2.0.6 (obsidian)
- lazy-decode FugueStore with LRU cache (core)
- fix applyTextSnapshot hang — checklines + cost cap (core)
- log sub-phases of text reconcile (seed/diff/upload) (core)
- per-fileId logs in apply loop + preReconcile begin/end (core)
- instrument _pull phases — getStates and prefetch timings (core)
- yield + log phases during StartupDiff scan (core)
- skip pre-reconcile when disk stat is unchanged (core)


## [2.0.5] - 2026-06-06

### Features

- cancellable sync — typing aborts in-flight reconcile + push (core)

### Bug Fixes

- expand text-file extensions to include .fountain and friends (core)

### Other

- bump version to 2.0.5 (obsidian)


## [2.0.4] - 2026-06-05

### Bug Fixes

- release editor-change handler on engine stop (obsidian)
- defer push until typing pauses (obsidian)

### Other

- bump version to 2.0.4 (obsidian)


## [2.0.3] - 2026-06-05

### Features

- surface Repair progress in the status indicator + truthful button copy (obsidian)
- real triggerRepair — reseed text files from disk and re-upload (core)

### Other

- bump version to 2.0.3 (obsidian)


## [2.0.2] - 2026-06-04

### Bug Fixes

- surface external-storage save errors, refresh settings on discovery (obsidian)
- discover external blob config before pull + require cipher in VaultMetaService (core)

### Other

- bump version to 2.0.2 (obsidian)


## [2.0.1] - 2026-06-04

### Bug Fixes

- defer engine.start, refresh metaStorage on auth, surface fatal rejections (obsidian)
- converge first-seed across devices, keep UI responsive, stop on fatal rejections (core)

### Other

- bump version to 2.0.1 (obsidian)


## [2.0.0] - 2026-06-04

### Features

- replace ribbon with floating indicator dot (obsidian)
- ribbon sync indicator + drop per-file pushed/pulled toasts (obsidian)
- TTL stale device frontiers out of causal-stability min (core)
- tombstone GC via causal stability frontier (Phase 5) (core)
- route text files through Fugue end-to-end (Phase 3.2) (core)
- FugueTextSync — plain-text snapshot → CRDT ops translator (core)
- plumb FugueStore + isText detector into StateSyncEngine (Phase 3.0) (core)
- FugueStore — per-file Sequence cache + persistence (Phase 2) (core)
- Sequence backed by HAMT IMap with O(log N) append/prepend (convergent)
- Phase C — Δ-state Sequence (Fugue list CRDT) (convergent)
- Phase B — Pruneable interface + OrSet causal-stability GC (convergent)
- Phase A — delta extraction, Mutator, DotSet for OrSet (convergent)
- Δ-state OrSet refactor, public Dot, JSON codecs (convergent)
- OCP extension points — events, use cases, resolver strategy (core)
- per-record poison isolation + schema version field (core)
- HLC self-stabilization defence (paper §4) (core)
- FileStateStore on MvRegister<FileState> (doc §4.4) (core)
- wire contract for Δ-state CRDT (doc §2/§5) (core)
- MvRegister.join + Δ-state CRDT property tests (core)
- BlobJanitor — user-triggered cleanup orchestration (core)
- local blob cache GC at engine startup (core)
- switch plugin to StateSyncEngine (obsidian)
- StateSyncEngine — pull/push/merge over the state-based protocol (core)
- FileState + FileStateStore for state-based sync (core)
- switch plugin to CrdtSyncEngine (obsidian)
- CrdtSyncEngine -- drop-in replacement for SyncEngine (core)
- sync_v2 integration layer with replicated_state (core)
- add comprehensive logging across sync pipeline (core)
- add vault storage usage API and display in plugin settings (core)
- introduce GraphBloc as central graph controller (core)
- add statusbar (obsidian)
- add IncomingUpdatesBloc and wire into SyncEngine lifecycle (core)

### Bug Fixes

- apply ribbon state via inline cssText, not CSS classes (obsidian)
- make ribbon indicator state changes actually visible (obsidian)
- seedFromPlainText O(1) via fromRaw instead of N appends (core)
- only record LCA at convergence points, not on local push (core)
- stop clobbering 3-way-merge base on local push (core)
- reconcile disk into local register before joining remote (core)
- resolve blobRef through ChunkedBlobIO in conflict paths (core)
- surface conflict-copy data loss as explicit SyncDataLoss event (core)
- parallelise HTTP blob upload/delete + progress log in StartupDiff (core)
- serialise FileStateStore persist + retry on version race (core)
- clean re-upload uploads blobs and wipes server first (core)
- poison op isolation and cursor persist order in CrdtSyncEngine (core)
- proper reset and restore in CrdtSyncEngine (core)
- use RemoteBlobStorage as default, WebDAV as override (core)
- reset local cursor when server cursor is behind (server data reset) (core)
- reuse endpoint for notify, add notify debug logging (core)
- persist server cursor, push only local ops (core)
- unstub external blob config save/clear in settings (obsidian)
- cast JSArray to List<bool> in conflict resolver for dart2js (core)
- add auth interceptor to notify endpoint in CrdtSyncEngine (core)
- skip duplicate ops in DataOperationStore.saveOps (core)
- wait for WebSocket online before calling pull (core)
- use WebSocket transport for CrdtSyncEngine (core)
- pull-first startup — defer reconciler until after server sync (core)
- skip missing blobs during restore instead of aborting (core)
- dual-mode HTTP client (Node.js on desktop, requestUrl on mobile) (obsidian)
- address 4 latent bugs in sync engine (core)
- prevent cleanBrokenFiles from deleting valid records with missing parents (core)
- remove file-exists-on-disk filter that blocked pull updates (core)
- skip discovery disk write for files with local unsynced edits (core)
- bloc-managed reconnect with exponential backoff (core)
- use discovery in _restoreFromServer instead of pull with empty cursor (core)
- use adapter.writeBinary fallback to fix FILE_NOTCREATED on mobile (obsidian)
- remove lock/release/renew synchronization mechanism (core)

### Refactoring

- unified SyncStatusIndicator (dot + progress label) (obsidian)
- migrate FileStateStore register encoding to convergent codecs (core)
- extract ISyncEngine interface (core)
- replace SqliteOperationStore with DataOperationStore (core)
- decouple DiskApplier from IGraphView (core)
- remove reset epoch mechanism from client (core)
- typed bus payloads and sealed SyncPhase states (core)
- extract workflows and sync_ops from SyncBloc (core)

### Other

- bump version to 2.0.0 (obsidian)
- comply with Community Plugins guidelines (obsidian)
- gate post-freeze diagnostic logs to only-when-interesting (core)
- compact wire format — SequenceCodec v3 + CBOR transport (core)
- debounce text-file reconciles to coalesce burst saves (core)
- instrument Fugue hot paths with timing logs (core)
- release 0.3.0 (convergent)
- release 0.2.0 (convergent)
- pubspec topics + runnable example (convergent)
- OSS-prep — README, LICENSE, CHANGELOG, SPDX, strict lints (convergent)
- Δ-state CRDT design document (core)
- CRDT audit and production-readiness checklist (core)
- add pull debug logging for empty response (core)
- add SyncBloc orchestration and LocalGC chunk cleanup tests (core)
- add integration tests for sync conflict scenarios (core)
- add regression tests for discovery skip on local unsynced edits (core)
- add tests for extracted sync_ops and workflows (core)
- skip ChangeRecord blob downloads in discovery phase of pull (core)
- reduce startup latency and memory usage (core)


## [1.2.1] - 2026-04-13

### Features

- storage quota + streaming blob upload/download (core)


## [1.2.0] - 2026-04-10

### Features

- add vault repair flow (obsidian)
- add server timestamp for deterministic leaf ordering (graph)
- add deleteNodes RPC to remove orphaned nodes from server (core)
- prune side branches on startup for all files (core)
- rewrite sync client as three BLoCs with in-process bus (core)

### Bug Fixes

- notify and retry when vault lock is released (core)
- add lease lock to sync flow (core)
- prune all file nodes from graph on startup, not just registry (core)
- push delete record before removing from file registry (core)
- two-pass apply to handle out-of-order records from server (graph)
- two-pass graph build to handle out-of-order records (core)
- in-process notify bus calls (core)
- handle missing blobs gracefully instead of null crash (core)

### Refactoring

- replace SyncEngine internals with BLoC facade (core)
- file change event merge files (core)
- make use cases pure — graph mutated only via apply/markSynced (graph)

### Other

- add token bucket rate limiter for outbound RPC calls (core)
- optimize large vault startup and sync (core)


## [1.1.1] - 2026-04-07

### Other

- add section about bundled sqlite3mc (obsidian)


## [1.1.0] - 2026-04-07

### Features

- inline sqlite3mc.wasm as base64 in main.js (obsidian)


## [1.0.0] - 2026-04-05

### Features

- add logging and message field to RestoreSubscriptionResponse (account)
- block disposable email providers on signup (account)
- normalize email on signup to prevent trial abuse via aliases (account)

### Refactoring

- replace print logs with RpcLogger, disable in production (obsidian)
- replace inline styles with CSS classes via bootstrapPlugin extraCss (obsidian)
- centralize collection names and improve restore subscription UX (account)
