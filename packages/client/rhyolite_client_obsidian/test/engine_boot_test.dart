@TestOn('vm')
library;

import 'dart:async';

import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:rhyolite_client_obsidian/src/engine/boot/engine_boot.dart';
import 'package:rhyolite_client_obsidian/src/engine/plan_status.dart';
import 'package:rhyolite_client_obsidian/src/engine/plan_tracker.dart';
import 'package:rhyolite_client_obsidian/src/engine/session_contracts.dart';
import 'package:rhyolite_client_obsidian/src/settings/plugin_code_overview.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The engine the plugin builds, built from the same function.
//
// This is the wiring test the refactoring plan asks for, and the reason it has
// to call `buildSyncEngine` rather than construct a StateSyncEngine of its own:
// a test that reassembles the graph beside the real one checks its own copy and
// misses whatever the plugin actually does.
//
// Two callbacks here are worth more than the rest put together, because both
// decide something destructive and both are read long after boot:
//
//   * `maxFileSizeBytes` — the managed per-file cap. Applied to a BYO vault it
//     refuses uploads the plan has no say over, silently, for the session.
//   * `siblingLiveBlobIds` — the blob GC's view of what settings sync owns.
//     Answer empty when the store has not loaded and the next housekeeping pass
//     deletes every plugin and theme in the vault.
// ---------------------------------------------------------------------------

final _log = LogController(outputs: []).scope('test');

Future<EngineBoot> _build({
  VaultConfig? config,
  PlanTracker? plans,
  SessionConfigSync? Function()? configSync,
  bool settingsEnabled = false,
  bool isMobile = false,
  Set<String> Function()? excluded,
  PathScope Function()? scope,
}) async {
  final conn = await openInMemoryDb();
  addTearDown(conn.close);

  return buildSyncEngine(
    serverUrl: 'wss://sync.example',
    config: config ?? const VaultConfig(vaultId: 'vault-1', vaultName: 'Notes'),
    cipher: null,
    dataClient: IDataClient.repository(
      repository: SqliteDataRepository(
        storage: SqliteDataStorageAdapter.connection(conn),
      ),
    ),
    blobRepository: _NoBlobs(),
    io: _NoIo(),
    changeProvider: _NoChanges(),
    metaStorage: null,
    httpClient: null,
    scheduler: PriorityTaskScheduler(),
    logger: _log,
    isMobile: isMobile,
    platformTag: isMobile ? 'mobile' : 'desktop',
    clientVersion: '3.16.4',
    selfHost: false,
    plans: plans ?? PlanTracker(),
    configSync: configSync ?? () => null,
    settingsSyncEnabled: () => settingsEnabled,
    excludedExtensions: excluded ?? () => const {},
    pathScope: scope ?? () => PathScope.everything,
  );
}

PlanTracker _planWith({int? maxFileSizeBytes}) =>
    PlanTracker()
      ..current = PlanSnapshot(
        status: SubscriptionStatus.active,
        capabilities: PlanCapabilities(
          canUseManagedStorage: true,
          canUseExternalStorage: true,
          maxFileSizeBytes: maxFileSizeBytes,
        ),
      );

void main() {
  group('the per-file size cap', () {
    test('applies on managed storage', () async {
      final engine = await _build(plans: _planWith(maxFileSizeBytes: 100));
      addTearDown(engine.engine.dispose);

      expect(engine.maxFileSizeBytes(), 100);
    });

    test('never applies on BYO, whatever the plan says', () async {
      final engine = await _build(
        // The kind marker, not the credentials: those are never persisted, so
        // the boot-time config has `externalBlobConfig == null` even here.
        // Asking it is what applied the managed cap to storage the plan does
        // not govern.
        config: const VaultConfig(
          vaultId: 'vault-1',
          vaultName: 'Notes',
          externalStorageKind: 's3',
        ),
        plans: _planWith(maxFileSizeBytes: 100),
      );
      addTearDown(engine.engine.dispose);

      expect(
        engine.maxFileSizeBytes(),
        isNull,
        reason:
            'we never see the bytes on BYO, and refusing them costs the user '
            'uploads with no explanation anywhere',
      );
    });

    test('is read live, so a tier change needs no rebuild', () async {
      final plans = PlanTracker();
      final engine = await _build(plans: plans);
      addTearDown(engine.engine.dispose);

      expect(engine.maxFileSizeBytes(), isNull, reason: 'no answer yet');

      plans.current = PlanSnapshot(
        status: SubscriptionStatus.active,
        capabilities: const PlanCapabilities(
          canUseManagedStorage: true,
          canUseExternalStorage: true,
          maxFileSizeBytes: 4096,
        ),
      );
      expect(engine.maxFileSizeBytes(), 4096);
    });
  });

  group('the blob GC live set', () {
    test('is empty when settings sync is off', () async {
      final engine = await _build(settingsEnabled: false);
      addTearDown(engine.engine.dispose);

      expect(
        engine.siblingLiveBlobIds(),
        isEmpty,
        reason:
            'nothing of ours is worth keeping, including leftovers from when '
            'it was on — that is a real answer, not an absent one',
      );
      expect(engine.siblingLiveBlobIds(), isNotNull);
    });

    test('is NULL when it is on but cannot answer yet', () async {
      // Two ways to reach this: the store has not loaded, and settings sync
      // has not been launched at all. Both must refuse to answer.
      for (final cs in <SessionConfigSync?>[null, _NotLoadedConfigSync()]) {
        final engine = await _build(
          settingsEnabled: true,
          configSync: () => cs,
        );
        addTearDown(engine.engine.dispose);

        expect(
          engine.siblingLiveBlobIds(),
          isNull,
          reason:
              'empty here would have the next housekeeping pass delete every '
              'plugin and theme in the vault',
        );
      }
    });

    test('is the live set once it can answer', () async {
      final engine = await _build(
        settingsEnabled: true,
        configSync: () => _LoadedConfigSync({'blob-a', 'blob-b'}),
      );
      addTearDown(engine.engine.dispose);

      expect(engine.siblingLiveBlobIds(), {'blob-a', 'blob-b'});
    });

    test('is resolved per call, not captured at boot', () async {
      // Settings sync is rebuilt wholesale on every relaunch — a reconnect, a
      // storage change, a settings edit. A captured instance would keep
      // answering from the dead one.
      SessionConfigSync? live;
      final engine = await _build(
        settingsEnabled: true,
        configSync: () => live,
      );
      addTearDown(engine.engine.dispose);

      expect(engine.siblingLiveBlobIds(), isNull);
      live = _LoadedConfigSync({'blob-a'});
      expect(engine.siblingLiveBlobIds(), {'blob-a'});
    });
  });

  group('the rest of the graph', () {
    test('mobile uploads fewer files at once', () {
      // StartupDiff holds N x file_bytes while uploading, and four attachments
      // in the megabyte range can take an iOS host process down.
      expect(startupUploadConcurrency(isMobile: true), 2);
      expect(startupUploadConcurrency(isMobile: false), 4);
    });

    test('the config carries who this client is', () async {
      final engine = await _build(isMobile: true);
      addTearDown(engine.engine.dispose);

      expect(engine.engine.config.clientName, 'Obsidian/mobile');
      expect(engine.engine.config.clientVersion, '3.16.4');
      expect(engine.engine.config.clientKind, 'obsidian');
      expect(
        engine.engine.config.vaultId,
        'vault-1',
        reason: 'stamping the client must not disturb the vault it is for',
      );
    });

    test('self-host is a different client kind', () async {
      final conn = await openInMemoryDb();
      addTearDown(conn.close);
      final engine = buildSyncEngine(
        serverUrl: 'wss://self.example',
        config: const VaultConfig(vaultId: 'v', vaultName: 'n'),
        cipher: null,
        dataClient: IDataClient.repository(
          repository: SqliteDataRepository(
            storage: SqliteDataStorageAdapter.connection(conn),
          ),
        ),
        blobRepository: _NoBlobs(),
        io: _NoIo(),
        changeProvider: _NoChanges(),
        metaStorage: null,
        httpClient: null,
        scheduler: PriorityTaskScheduler(),
        logger: _log,
        isMobile: false,
        platformTag: 'desktop',
        clientVersion: '3.16.4',
        selfHost: true,
        plans: PlanTracker(),
        configSync: () => null,
        settingsSyncEnabled: () => false,
        excludedExtensions: () => const {},
        pathScope: () => PathScope.everything,
      );
      addTearDown(engine.engine.dispose);

      expect(
        engine.engine.config.clientKind,
        'obsidian-selfhost',
        reason: 'device management shows editions apart by this',
      );
    });

    // The per-device filters (excludedExtensions, pathScope) are passed
    // straight through and the engine exposes neither, so there is nothing here
    // to assert that is not a restatement of the call. They are covered where
    // they are decided, in the harness package's policy tests.
  });
}

class _NotLoadedConfigSync implements SessionConfigSync {
  @override
  Set<String>? liveBlobIds() => null;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName}');
}

class _LoadedConfigSync implements SessionConfigSync {
  _LoadedConfigSync(this._ids);
  final Set<String> _ids;

  @override
  Set<String>? liveBlobIds() => _ids;

  @override
  Future<PluginCodeOverview> pluginOverview() async => PluginCodeOverview.empty;

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName}');
}

class _NoIo implements IPlatformIO {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnsupportedError(
    'the engine is never started here: ${i.memberName}',
  );
}

class _NoChanges implements IChangeProvider {
  @override
  Stream<FileChangeEvent> get changes => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation i) => throw UnsupportedError(
    'the engine is never started here: ${i.memberName}',
  );
}

class _NoBlobs implements IBlobRepository {
  @override
  Future<void> ensureCollection(String collection) async {}

  @override
  Future<BlobReadResult?> readBlob(BlobReadRequest request) async => null;

  @override
  Future<Map<String, BlobDescriptor>> headMany(
    String collection,
    List<String> ids,
  ) async => const {};

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation i) => throw UnsupportedError(
    'the engine is never started here: ${i.memberName}',
  );
}
