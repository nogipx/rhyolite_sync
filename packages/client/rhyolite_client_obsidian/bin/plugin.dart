// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_client_account/rhyolite_client_account.dart'
    hide VaultInfo;
import 'package:rhyolite_client_obsidian/rhyolite_client_obsidian.dart';
import 'package:rhyolite_client_obsidian/src/engine/build_env.dart';
import 'package:rhyolite_client_obsidian/src/engine/db_recovery.dart';
import 'package:rhyolite_client_obsidian/src/engine/diagnostics_logging.dart';
import 'package:rhyolite_client_obsidian/src/engine/device_management_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/file_version_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/modal_lock.dart';
import 'package:rhyolite_client_obsidian/src/engine/orphan_sweep_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/self_host_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/server_rejections.dart';
import 'package:rhyolite_client_obsidian/src/engine/storage_cleanup_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/storage_overview_modal.dart';
import 'package:rhyolite_client_obsidian/src/engine/sync_panel.dart';
import 'package:rhyolite_client_obsidian/src/engine/sync_status_indicator.dart';
import 'package:rhyolite_client_obsidian/src/engine/vault_picker_modal.dart';
import 'package:rhyolite_client_obsidian/src/platform/obsidian_http_client.dart';
import 'package:rhyolite_client_obsidian/src/vault/managed_vault_directory.dart';
import 'package:rpc_blob_sqlite/rpc_blob_sqlite.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_compression/rpc_dart_compression.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:rpc_dart_log/rpc_dart_log.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';

// Silent baseline level: dev builds stream everything; release builds sit at
// warning. When the user enables remote diagnostics, [DiagnosticsLogging] drops
// the level to debug and restores this on disable.
const _baselineLogLevel = kDebug ? RpcLogLevel.debug : RpcLogLevel.warning;

// Release builds start with NO outputs — nothing is written anywhere until the
// user explicitly enables remote diagnostics (see [DiagnosticsLogging]). Dev
// builds (RHYOLITE_DEBUG=true) keep the console for local debugging.
final _logController = LogController(
  outputs: kDebug ? [ConsoleOutput()] : [],
  minLevel: _baselineLogLevel,
);
final _log = _logController.scope('plugin');

/// Manages the optional remote log sink. Off until the user opts in; installed
/// during boot from the persisted [DiagnosticsPrefs] and re-applied live from
/// the settings tab.
DiagnosticsLogging? _diagnostics;

ISyncEngine? _engine;
DatabaseConnection? _dbConn;
SyncStatusIndicator? _syncIndicator;
SyncPanel? _syncPanel;

/// User-requested sync pause (toggled from the side panel, persisted in
/// data.json). When true, every incidental start path is skipped — sync stays
/// off until an explicit resume (the "Start Sync" command or the panel's Resume
/// button), which is the only thing that clears it.
bool _syncPaused = false;

/// Starts the engine unless the user paused sync. ALL non-explicit start paths
/// (boot, reconnect, token refresh, config/vault change, subscription) route
/// through this so a persisted pause is honoured everywhere — otherwise the
/// flag desyncs from reality (engine running while "paused"). The pause flag is
/// cleared only by an explicit resume (`setSyncPaused(false)` in boot).
Future<void> _guardedStart(ISyncEngine engine) async {
  if (_syncPaused) {
    _log.info('Engine start skipped — sync paused by user.');
    return;
  }
  await engine.start();
}

/// Best-effort OS label for [DeviceInfo] on the log collector: `desktop`, or
/// `iOS`/`Android` sniffed from the user agent on mobile (Obsidian doesn't
/// expose the OS directly). The bug this diagnostics feature exists to debug is
/// iOS-specific, so telling iPhone from Android in the collector matters.
String _diagnosticsOs(bool isMobile) {
  if (!isMobile) return 'desktop';
  try {
    final nav = jsu.getProperty<JSObject?>(jsu.globalThis, 'navigator');
    final ua = nav != null
        ? (jsu.getProperty<String?>(nav, 'userAgent') ?? '')
        : '';
    return ua.contains('Android') ? 'Android' : 'iOS';
  } catch (_) {
    return 'mobile';
  }
}

/// Fetches managed-storage usage over the sync connection. Returns null on
/// self-host / BYO (no managed quota, responder absent) or before connect.
Future<({int usedBytes, int quotaBytes})?> _fetchVaultUsage(
  ISyncEngine engine,
  String vaultId,
) async {
  if (engine is! StateSyncEngine || vaultId.isEmpty) return null;
  final ep = engine.endpoint;
  if (ep == null) return null;
  try {
    final res = await VaultUsageContractCaller(
      ep,
    ).getVaultUsage(GetVaultUsageRequest(vaultId: vaultId));
    return (usedBytes: res.usedBytes, quotaBytes: res.quotaBytes);
  } catch (e) {
    _log.warning('vault usage fetch failed: $e');
    return null;
  }
}

ObsidianConfigSync? _configSync;
StreamSubscription<SyncEngineEvent>? _configReconnectSub;

/// The auth/recovery event listener (session-expiry re-auth, blob-config
/// adopt, token refresh). Held so onUnload can cancel it — without this a
/// soft reload (unload + re-onload) leaks one listener bound to the prior
/// engine's event stream each cycle.
StreamSubscription<SyncEngineEvent>? _engineAuthEventsSub;

/// Watches for the connected vault being permanently deleted on another device
/// (its registry entry comes back tombstoned). Cancelled on unload like the
/// others to avoid leaking a listener across soft reloads.
StreamSubscription<SyncEngineEvent>? _deletedVaultWatchSub;

/// Latest known plan capabilities (managed edition). Populated from
/// getSubscription; the engine reads `maxFileSizeBytes` from it for the
/// per-file size gate. Null in self-host / before the first fetch → no limit.
PlanCapabilities? _capabilities;

/// Plugin-owned task lane. Created in onLoad, injected into the engine so the
/// engine's steady-state sync work (reconcile/pull/GC/settings) and the
/// plugin's lifecycle work (boot/restart) share one serialized,
/// connection-fair scheduler instead of racing the single WebSocket. Outlives
/// every engine session; disposed on unload. See [[engine_sync_scheduler_plan]].
PriorityTaskScheduler? _scheduler;

/// Priority for lifecycle (boot/restart) tasks. Above the engine's interactive
/// lane (100) so a restart is never blocked by the user-active typing gate.
const int _kBootPriority = 1000;

/// Runs [body] as the single coalesced `engine-lifecycle` task, so the restart
/// triggers (initial start, Start command, resume health-check, blob-config
/// adopt, token refresh) can't overlap or interleave their `engine.start()` —
/// the latest supersedes a still-pending one, and a running one is never
/// re-entered. Settings relaunch is deliberately NOT wrapped: it routes through
/// engine.scheduleBackground (lower priority) and awaiting it from inside this
/// task would deadlock the single slot, so callers relaunch settings AFTER
/// awaiting this. Runs [body] directly if the scheduler is gone (unloaded).
Future<void> _scheduleBoot(Future<void> Function() body) {
  final scheduler = _scheduler;
  if (scheduler == null) return body();
  return scheduler.schedule(
    key: 'engine-lifecycle',
    priority: _kBootPriority,
    run: (_) => body(),
  );
}

/// (Re)starts `.obsidian` settings sync. Idempotent — disposes any running
/// instance first. No-op when disabled, before the engine has an endpoint, or
/// before a vault key is available. The config caller reuses the engine's live
/// connection via a distinct service name.
/// Debounce for the "settings changed — reload" prompt: a burst of synced
/// resources coalesces into a single notice.
Timer? _settingsReloadDebounce;

void _scheduleSettingsReloadNotice(PluginHandle plugin) {
  _settingsReloadDebounce?.cancel();
  _settingsReloadDebounce = Timer(const Duration(seconds: 3), () {
    _showReloadNotice(
      plugin,
      'Settings synced from another device. Reload to apply them.',
    );
  });
}

/// Persistent notice with a clickable "Reload" that runs Obsidian's reload
/// command. Falls back to a plain notice if the DOM/command wiring is
/// unavailable (e.g. mobile has no app:reload).
void _showReloadNotice(PluginHandle plugin, String message) {
  try {
    final obsidian = jsu.callMethod<Object?>(
      jsu.globalThis,
      'require',
      ['obsidian'],
    );
    final noticeCtor = jsu.getProperty<Object?>(obsidian!, 'Notice');
    // timeout 0 = stays until dismissed or the app reloads.
    final notice = jsu.callConstructor<Object?>(noticeCtor!, [message, 0])!;
    final el = jsu.getProperty<Object?>(notice, 'noticeEl');
    if (el == null) return;
    final btn = jsu.callMethod<Object?>(
      el,
      'createEl',
      ['button', jsu.jsify({'text': ' Reload', 'cls': 'mod-cta'})],
    )!;
    jsu.setProperty(btn, 'style', 'margin-left: 8px;');
    jsu.callMethod<void>(btn, 'addEventListener', [
      'click',
      jsu.allowInterop((_) {
        final commands = jsu.getProperty<Object?>(plugin.app.raw, 'commands');
        if (commands != null) {
          jsu.callMethod<void>(commands, 'executeCommandById', ['app:reload']);
        }
        jsu.callMethod<void>(notice, 'hide', []);
      }),
    ]);
  } catch (_) {
    showNotice(message);
  }
}

Future<void> _launchConfigSync({
  required ISyncEngine engine,
  required IDataClient dataClient,
  required IVaultCipher cipher,
  required String vaultId,
  required PluginHandle plugin,
  required SettingsSyncPrefs prefs,
}) async {
  _stopConfigSync();
  if (!prefs.enabled || engine is! StateSyncEngine) return;
  final endpoint = engine.endpoint;
  if (endpoint == null) return;

  final caller = StateSyncContractCaller(
    endpoint,
    serviceNameOverride: StateSyncContractNames.instance('config'),
  );
  final sync = SettingsSync(
    remote: caller,
    store: SettingsStore(client: dataClient, vaultId: vaultId),
    cipher: cipher,
    vaultId: vaultId,
    kindOf: ObsidianSettingsRegistry.kindOf(prefs.categories),
    log: _log.info,
  );
  final cs = ObsidianConfigSync(
    adapter: plugin.app.vault.adapter,
    sync: sync,
    enabledCategories: prefs.categories,
    // Event-driven remote->local: react to another device's settings push on
    // the config keyspace topic (same vault qualification the server uses).
    notifyEndpoint: endpoint,
    notifyTopic: 'vault:${vaultId}_config',
    onActivity: (active) => _syncIndicator?.setSettingsActivity(active),
    // Obsidian doesn't hot-apply config files from disk, so a settings change
    // synced from another device lands on disk but isn't live until a reload.
    // Prompt one (debounced, one notice per burst).
    onRemoteApplied: () => _scheduleSettingsReloadNotice(plugin),
    log: _log.info,
    // Share the note engine's connection-fair scheduler: settings sync runs
    // as low-priority background work that yields to interactive note sync
    // and pauses while the user is actively editing.
    runBackground: engine.scheduleBackground,
  );
  _configSync = cs;
  try {
    await cs.start();
    _log.info('Settings sync started (${prefs.categories.length} categories)');
  } catch (e, st) {
    _log.error('Settings sync start failed', error: e, stackTrace: st);
  }
}

void _stopConfigSync() {
  _configSync?.dispose();
  _configSync = null;
}

/// Updates the engine's reference to the auth-backed vault meta storage.
///
/// `metaStorage` is set once at engine construction; without this helper a
/// post-construction sign-in (session-expired refresh, manual re-auth,
/// onAuthChanged callback) would leave the engine with a stale null
/// `metaStorage` and `_checkExternalBlobConfig` would silently never
/// load the server-side external blob config.
void _setEngineAuth(ISyncEngine engine, RpcAccountClient? client) {
  if (engine is! StateSyncEngine) return;
  engine.metaStorage = client != null ? AccountVaultMetaStorage(client) : null;
}

/// Opens [url] in the user's real system browser, not Obsidian's in-app Web
/// Viewer. Browser-auth depends on this: the site's `obsidian://rhyolite-auth`
/// callback only reaches the protocol handler when login happens in the
/// external browser — inside the in-app WebView the redirect is swallowed and
/// Electron throws a detached-webview error ("getWebContentsId"). Uses
/// Electron's `shell.openExternal` on desktop, falling back to `window.open`
/// on mobile (no Electron), where that already opens the system browser.
void _openExternalUrl(String url) {
  try {
    final electron =
        jsu.callMethod<Object?>(jsu.globalThis, 'require', ['electron']);
    if (electron != null) {
      final shell = jsu.getProperty<Object?>(electron, 'shell');
      if (shell != null) {
        jsu.callMethod<void>(shell, 'openExternal', [url]);
        return;
      }
    }
  } catch (_) {
    // No Electron (mobile) or require unavailable — fall through.
  }
  jsu.callMethod<void>(jsu.globalThis, 'open', [url]);
}

/// Returns true if [error] indicates a corrupted or incompatible SQLite database.
bool _isSqliteCorrupt(Object error) {
  final msg = error.toString();
  // SqliteException(11) — SQLITE_CORRUPT
  if (msg.contains('SqliteException(11)') ||
      (msg.contains('SqliteException') && msg.contains('malformed'))) {
    return true;
  }
  // IndexedDB VFS failures — stale or incompatible DB layout:
  // 1. Chunk shorter than expected → negative typed array length.
  if (msg.contains('Invalid typed array length') && msg.contains('-')) {
    return true;
  }
  // 2. IDB cursor key is null when a number is expected (missing chunk).
  if (msg.contains('JSNull') && msg.contains('double')) {
    return true;
  }
  return false;
}

/// Returns a URI for the sqlite3mc wasm module.
/// The wasm is inlined as base64 in main.js by the build script — decoded here
/// and wrapped in a Blob URL so no separate file is needed.
Uri _resolveWasmUri() {
  final b64 =
      jsu.getProperty<String?>(jsu.globalThis, '__rhyoliteWasmB64') ?? '';
  final bytes = base64Decode(b64);
  final jsBytes = jsu.jsify(bytes);
  final blobConstructor = jsu.getProperty<Object>(jsu.globalThis, 'Blob');
  final blob = jsu.callConstructor<Object>(blobConstructor, [
    [jsBytes],
    jsu.jsify({'type': 'application/wasm'}),
  ]);
  final url = jsu.callMethod<String>(
    jsu.getProperty<Object>(jsu.globalThis, 'URL'),
    'createObjectURL',
    [blob],
  );
  return Uri.parse(url);
}

void main() {
  RpcGzipCodec.register();
  bootstrapPlugin(
    extraCss: '''
      .rhyolite-setting-desc { color: var(--text-muted); font-size: 0.85em; }
      .rhyolite-vault-label { font-weight: 500; }
    ''',
    onLoad: (plugin) async {
      String dbFileName = '';
      String dbName = '';
      bool handlingCorruption = false;

      void onCorruptDb() {
        if (handlingCorruption) return;
        handlingCorruption = true;
        () async {
          try {
            await _engine?.stop();
            await _dbConn?.close();
            _engine = null;
            _dbConn = null;
          } catch (_) {}
          await showDbCorruptionModal(
            plugin,
            dbFileName: dbFileName,
            dbName: dbName,
          );
          handlingCorruption = false;
        }();
      }

      await runZonedGuarded(
        () async {
          final configStorage = ObsidianConfigStorage(plugin);

          // -----------------------------------------------------------------------
          // Self-host mode: point the plugin at a self-hosted sync server with a
          // static bearer token, bypassing the managed account service entirely.
          // -----------------------------------------------------------------------
          final selfHost = await configStorage.loadSelfHost();
          final selfHostToken = selfHost.enabled
              ? (await configStorage.loadSelfHostToken() ?? '')
              : '';
          final selfHostActive =
              selfHost.enabled &&
              selfHost.syncUrl.isNotEmpty &&
              selfHostToken.isNotEmpty;

          // Server URL: self-host overrides the compile-time managed sync URL.
          final syncServerUrl = selfHostActive
              ? selfHost.syncUrl
              : kEnv.syncServiceUrl;

          // Shared session bindings, filled by whichever edition is active.
          IVaultDirectory? directory; // drives the vault picker
          ITokenProvider? sessionTokenProvider; // engine bearer
          IVaultMetaStorage? sessionMetaStorage; // external-blob config store
          WebSocketSyncConnection? registryConn; // self-host: kept alive

          // -----------------------------------------------------------------------
          // Auth — account service URL comes from compile-time dart-define only.
          // -----------------------------------------------------------------------
          final authConfig = AuthConfig(
            accountServiceUrl: kEnv.accountServiceUrl,
          );

          final accountTransport = RpcHttpCallerTransport(
            baseUrl: authConfig.accountServiceUrl,
          );
          final accountEndpoint = RpcCallerEndpoint(
            transport: accountTransport,
          );
          final accountClient = RpcAccountClient(accountEndpoint);
          // Persist every server-issued session (sign-in + every background
          // refresh). The server rotates the refresh token on each refresh, so
          // without this the on-disk token goes stale within ~15 min and the
          // next cold start is forced to re-login with a revoked token.
          accountClient.onSessionPersist = configStorage.saveAuthSession;

          RpcAccountClient? authClient;

          if (!selfHostActive && authConfig.isConfigured) {
            final savedSession = await configStorage.loadAuthSession();
            if (savedSession != null) {
              if (!savedSession.isExpired) {
                accountClient.useSession(savedSession);
                authClient = accountClient;
              } else {
                // Token expired — try to refresh.
                try {
                  accountClient.useSession(savedSession);
                  await accountClient.refreshSession();
                  final newSession = accountClient.session;
                  if (newSession != null) {
                    await configStorage.saveAuthSession(newSession);
                  }
                  authClient = accountClient;
                } catch (e) {
                  final msg = e.toString();
                  if (msg.contains('(400)') || msg.contains('(401)')) {
                    await configStorage.clearAuthSession();
                  } else {
                    accountClient.useSession(savedSession);
                    authClient = accountClient;
                  }
                }
              }
            }
          }

          // Bind the vault directory + engine auth to the active edition.
          if (selfHostActive) {
            sessionTokenProvider = StaticTokenProvider(selfHostToken);
            registryConn = WebSocketSyncConnection(
              serverUrl: syncServerUrl,
              tokenProvider: sessionTokenProvider,
              logger: _logController.scope('registry'),
            );
            try {
              // Bounded: onLoad must never hang on a stalled connect, or the
              // rest of onLoad (settings tab, commands, engine) never runs and
              // the settings page shows up blank.
              await registryConn.connect().timeout(const Duration(seconds: 10));
              final regCaller = VaultRegistryContractCaller(
                registryConn.endpoint,
              );
              directory = SelfHostVaultDirectory(regCaller);
              sessionMetaStorage = SelfHostVaultMetaStorage(regCaller);
            } catch (e) {
              _log.warning('Self-host registry connect failed: $e');
            }
          } else if (authClient != null) {
            directory = ManagedVaultDirectory(authClient);
            sessionTokenProvider = RpcAccountClientTokenProvider(authClient);
            sessionMetaStorage = AccountVaultMetaStorage(authClient);
          }

          // -----------------------------------------------------------------------
          // Vault
          // -----------------------------------------------------------------------
          var config = await configStorage.tryLoad();
          // One-time migration: older installs stored the BYO storage secret
          // (S3/WebDAV keys) in cleartext in data.json. VaultConfig.toJson no
          // longer serialises it, so re-saving strips the cleartext; the secret
          // is re-fetched from the E2EE server config each session, and only
          // the non-secret kind marker (derived in fromJson) is persisted.
          if (config != null && config.externalBlobConfig != null) {
            await configStorage.save(config);
            _log.info('Migrated external storage credentials out of data.json');
          }
          VaultCipher? cipher;

          if (directory != null) {
            final dir = directory;
            if (config == null) {
              final result = await withModalLock(
                () => showVaultPickerModal(plugin, dir, configStorage),
              );
              if (result != null) {
                config = result.$1;
                cipher = result.$2;
              }
            } else if (config.verificationToken == null ||
                config.verificationToken!.isEmpty) {
              final result = await withModalLock(
                () => showVaultPickerModal(plugin, dir, configStorage),
              );
              if (result != null) {
                config = result.$1;
                cipher = result.$2;
              }
            } else {
              final snapshot = config;
              cipher =
                  await configStorage.tryUnlockFromStorage(
                    snapshot.verificationToken!,
                  ) ??
                  await withModalLock(
                    () => showPassphraseModal(
                      plugin,
                      configStorage,
                      vaultId: snapshot.vaultId,
                      verificationToken: snapshot.verificationToken!,
                    ),
                  );
            }
          }

          final cfg = config ?? const VaultConfig(vaultId: '', vaultName: '');

          // Single config builder for every (re)build — initial boot AND the
          // settings callbacks (onVaultChanged/onConfigChanged/onAuthChanged).
          // Self-host always uses the static token provider (no account client,
          // so the managed branch would otherwise drop the token and the engine
          // would connect unauthenticated). Managed uses the passed client.
          VaultConfig buildConfig(VaultConfig base, RpcAccountClient? client) {
            if (selfHostActive) {
              return sessionTokenProvider != null
                  ? base.copyWith(tokenProvider: sessionTokenProvider)
                  : base;
            }
            if (client == null) return base;
            return base.copyWith(
              tokenProvider: RpcAccountClientTokenProvider(client),
            );
          }

          final activeConfig = buildConfig(cfg, authClient);

          final wasmUri = _resolveWasmUri();

          final vaultId = cfg.vaultId;

          final bootSw = Stopwatch()..start();
          final raw = await plugin.loadData();
          _log.info('boot: loadData ${bootSw.elapsedMilliseconds}ms');
          final dbSuffix =
              (raw as Map<Object?, Object?>?)?['dbSuffix'] as String? ?? '';
          final suffix = dbSuffix.isNotEmpty ? '-$dbSuffix' : '';
          dbFileName = '$vaultId$suffix.db';
          dbName = 'rhyolite-$vaultId$suffix';

          // .obsidian settings sync preferences (opt-in; default off).
          var settingsPrefs = SettingsSyncPrefs.fromData(raw);

          // Remote diagnostics logging (opt-in; default off). The sink itself is
          // installed after platform detection below so DeviceInfo can carry the
          // OS — but it's still early enough to capture the whole engine boot.
          var diagnosticsPrefs = DiagnosticsPrefs.fromData(raw);

          // Per-device file-type sync filter (opt-in; default empty = sync all).
          // A denylist of extensions this device skips both uploading and
          // downloading. Device-local (data.json is not synced). Read live by
          // the engine through the callback below so a settings change takes
          // effect on the next reconcile without reconstructing the engine.
          var fileFilterPrefs = FileFilterPrefs.fromData(raw);

          // User-requested sync pause (from the side panel). Gates the boot
          // start below; the panel toggles it live.
          _syncPaused = raw is Map && raw['syncPaused'] == true;

          final dbConn = await openFileDb(
            options: SqliteConnectionOptions(
              webDatabaseName: dbName,
              webFileName: dbFileName,
              webSqliteWasmUri: wasmUri,
            ),
          );
          _dbConn = dbConn;
          _log.info('boot: openFileDb ${bootSw.elapsedMilliseconds}ms');

          // Set up database logger
          final dataRepository = SqliteDataRepository(
            storage: SqliteDataStorageAdapter.connection(dbConn),
          );
          final dataClient = IDataClient.repository(repository: dataRepository);
          // Database logging removed during logger migration

          final blobRepo = SqliteBlobRepository.db(
            dbConn.database,
            enableWal: false,
          );

          String platformTag;
          bool isMobile = false;
          try {
            isMobile = jsu.getProperty<bool>(plugin.app.raw, 'isMobile');
            platformTag = isMobile ? 'mobile' : 'desktop';
          } catch (_) {
            platformTag = 'unknown';
          }

          // Install the remote diagnostics sink now that DeviceInfo can carry
          // the OS (iOS/Android/desktop) so the collector can tell devices
          // apart — the bug this exists to debug is device-specific. Off unless
          // the user enabled it; re-applied live from the settings tab.
          _diagnostics = DiagnosticsLogging(
            controller: _logController,
            baselineLevel: _baselineLogLevel,
            log: _log,
            device: () => DeviceInfo(
              name: cfg.vaultName.isNotEmpty ? cfg.vaultName : 'Obsidian',
              app: 'rhyolite_sync',
              os: _diagnosticsOs(isMobile),
            ),
          );
          _diagnostics!.apply(diagnosticsPrefs);

          // On mobile (Obsidian iOS/Android) RAM is tight. StartupDiff
          // holds N × file_bytes in memory while uploading; with large
          // attachments (PDFs, attachments in MB range) concurrency=4
          // can OOM the host process. Cap to 2 on mobile.
          final startupUploadConcurrency = isMobile ? 2 : 4;

          // Plugin version (from the Obsidian manifest) + client kind, reported
          // with this device's head so the device-management UI and support can
          // tell devices/versions apart. Best-effort — empty on any failure.
          String pluginVersion = '';
          try {
            final manifest = jsu.getProperty<JSObject?>(plugin.raw, 'manifest');
            if (manifest != null) {
              pluginVersion = jsu.getProperty<String?>(manifest, 'version') ?? '';
            }
          } catch (_) {}
          final clientKind = selfHostActive ? 'obsidian-selfhost' : 'obsidian';

          // One scheduler for the whole plugin: the engine's sync work and the
          // lifecycle boot/restart work below share it (see [_scheduleBoot]).
          final scheduler = PriorityTaskScheduler(
            onError: (e, _) => _log.warning('scheduler task error: $e'),
          );
          _scheduler = scheduler;

          final ISyncEngine engine = StateSyncEngine(
            vaultPath: '',
            serverUrl: syncServerUrl,
            config: activeConfig.copyWith(
              clientName: 'Obsidian/$platformTag',
              clientVersion: pluginVersion,
              clientKind: clientKind,
            ),
            cipher: cipher,
            dataClient: dataClient,
            blobStore: LocalBlobStore(blobRepo),
            io: ObsidianIO(plugin.app.vault),
            changeProvider: ObsidianChangeProvider(
              plugin,
              logger: _logController.scope('engine'),
            ),
            metaStorage: sessionMetaStorage,
            httpClient: ObsidianHttpClient(),
            logger: _logController.scope('engine'),
            rejectionFactory: pluginRejectionFactory,
            startupUploadConcurrency: startupUploadConcurrency,
            scheduler: scheduler,
            // The managed per-file size limit only applies to managed storage —
            // not BYO/external, where we never see the bytes. Callback so a
            // tier change is picked up without reconstructing the engine.
            maxFileSizeBytes: () => activeConfig.externalBlobConfig != null
                ? null
                : _capabilities?.maxFileSizeBytes,
            // Per-device denylist, read live so a settings change is picked up
            // on the next reconcile without reconstructing the engine.
            excludedExtensions: () => fileFilterPrefs.excludedExtensions,
          );
          _engine = engine;
          _log.info('boot: engine ctor ${bootSw.elapsedMilliseconds}ms');

          // Starts a full sync session: cache plan caps (the size gate needs
          // the tier BEFORE StartupDiff, which runs inside start()), start the
          // engine, then launch settings-sync. Shared by the boot start below
          // and the panel's Resume action so both take the identical path.
          Future<void> startSyncSession() async {
            try {
              final sub = await accountClient.getSubscription().timeout(
                const Duration(seconds: 5),
              );
              _capabilities = sub.capabilities;
            } catch (_) {}
            await _scheduleBoot(() => _guardedStart(engine));
            if (cipher != null) {
              await _launchConfigSync(
                engine: engine,
                dataClient: dataClient,
                cipher: cipher!,
                vaultId: vaultId,
                plugin: plugin,
                prefs: settingsPrefs,
              );
            }
          }

          // Single source of truth for the pause toggle — shared by the panel
          // Pause/Resume button and the "Pause sync"/"Resume sync" commands so
          // the two surfaces are the same action. Pausing persists + stops;
          // resuming persists + runs the full start session.
          Future<void> setSyncPaused(bool paused) async {
            _syncPaused = paused;
            await configStorage.savePaused(paused);
            if (paused) {
              _stopConfigSync();
              await engine.stop();
            } else {
              await startSyncSession();
            }
          }

          // Backend/tier labels for the panel — stable at construction, so
          // derived from the connection mode rather than (later-fetched) caps.
          final byo = activeConfig.externalBlobConfig != null;
          final String backendLabel;
          if (selfHostActive) {
            final host = Uri.tryParse(selfHost.syncUrl)?.host;
            backendLabel = (host != null && host.isNotEmpty)
                ? 'Self-host · $host'
                : 'Self-host';
          } else if (byo) {
            backendLabel = 'Bring-your-own storage';
          } else {
            backendLabel = 'Managed';
          }
          final planLabel = selfHostActive
              ? 'Self-host'
              : (byo ? 'BYO' : 'Managed');

          // Docked right-side panel: live status, one-tap sync, and the
          // over-time warnings (size-blocked files, lossy conflicts) that
          // don't fit the status-bar dot. The indicator's tap reveals it.
          // A soft restart re-runs this boot; drop the prior instance's engine
          // subscription first (registerView itself is idempotent, see below).
          _syncPanel?.dispose();
          final syncPanel = SyncPanel(
            plugin: plugin,
            engine: engine,
            vaultName: cfg.vaultName,
            encrypted: cipher != null,
            backendLabel: backendLabel,
            planLabel: planLabel,
            logger: _logController.scope('plugin'),
            onOpenSettings: () {
              final setting = jsu.getProperty<Object?>(
                plugin.app.raw,
                'setting',
              );
              if (setting == null) return;
              jsu.callMethod<void>(setting, 'open', []);
              jsu.callMethod<void>(setting, 'openTabById', ['rhyolite-sync']);
            },
            onBrowseVersions: () => showFileVersionModal(plugin, engine),
            isPaused: () => _syncPaused,
            onSetPaused: setSyncPaused,
            // Managed-only usage meter; self-host/BYO have no managed quota.
            onFetchUsage: (selfHostActive || byo)
                ? null
                : () => _fetchVaultUsage(engine, vaultId),
            onSettingsSize: () =>
                SettingsStore(client: dataClient, vaultId: vaultId)
                    .approxTotalBytes(),
            onStorageDetails: () => showStorageOverviewModal(plugin, engine),
          )..register();
          _syncPanel = syncPanel;

          // Single indicator, surface picks itself by platform:
          // status bar on desktop, floating pill on mobile. Tap reveals
          // the docked panel.
          _syncIndicator = SyncStatusIndicator(
            plugin: plugin,
            engine: engine,
            logger: _logController.scope('plugin'),
            onTap: () => unawaited(syncPanel.reveal()),
          )..init();

          // The settings notify subscription is an in-flight call too, so it
          // dies on a transport reconnect. The engine emits SyncConnected on
          // every (re)connect; reissue the config notify + catch-up pull. The
          // first SyncConnected fires before config sync is launched, so the
          // null-guard makes it a no-op then and a real reissue on reconnects.
          _configReconnectSub = engine.events.listen((e) {
            if (e is SyncConnected) _configSync?.handleReconnect();
          });

          // Permanent-delete propagation. When another device permanently
          // deletes the vault this device is connected to, its registry entry
          // comes back tombstoned (deletedAt set). On (re)connect, pull the
          // vault list and, if our vault is tombstoned, drop it locally:
          // disconnect + wipe local sync state. Files on disk are left
          // untouched (matches the initiating device). We act only on an
          // explicit tombstone, never on mere absence (which could be a
          // transient list failure or an access change).
          _deletedVaultWatchSub = engine.events.listen((e) async {
            if (e is! SyncConnected) return;
            final connectedVaultId = engine.config.vaultId;
            final d = directory;
            if (connectedVaultId.isEmpty || d == null) return;
            final List<VaultInfo> vaults;
            try {
              vaults = await d.listVaults();
            } catch (_) {
              return; // transient — don't forget on a failed list
            }
            final matches = vaults.where((v) => v.vaultId == connectedVaultId);
            if (matches.isEmpty || !matches.first.isDeleted) return;
            _log.info(
              'Vault $connectedVaultId permanently deleted on another device '
              '— dropping it locally (files on disk untouched)',
            );
            engine.cipher = null;
            await _scheduleBoot(() async {
              await engine.stop();
              try {
                await engine.wipeLocalState();
              } catch (_) {}
            });
            await configStorage.disconnectVault();
          });

          // Permanently delete a vault. Order: (1) tombstone the registration
          // so the vault is marked deleted (other devices see it via listVaults
          // and drop it locally); (2) purge sync data for BOTH keyspaces —
          // notes AND settings/config — from the sync server. Tombstone-first
          // means a failed purge only leaks server data (recoverable by retry —
          // both steps are idempotent), while the user-facing outcome (vault
          // gone everywhere) is already correct.
          //
          // The account/self-host token authorizes deleting any of the user's
          // own vaults, so a short-lived connection works from the picker even
          // with no vault connected. Local note files on disk are never touched;
          // external (BYO) blobs stay in the user's own bucket (the confirmation
          // warns to clear it separately).
          Future<void> deleteVaultClosure(VaultInfo vault) async {
            final dir = directory;
            final tp = sessionTokenProvider;
            if (dir == null || tp == null) {
              throw StateError('Not signed in — cannot delete a vault.');
            }
            final vaultId = vault.vaultId;

            // 1. Tombstone first (intent). Idempotent.
            await dir.deleteVault(vaultId: vaultId);

            // 2. Purge sync data for both keyspaces over one short-lived socket.
            final conn = WebSocketSyncConnection(
              serverUrl: syncServerUrl,
              tokenProvider: tp,
              logger: _logController.scope('delete'),
            );
            try {
              await conn.connect().timeout(const Duration(seconds: 15));
              final purge = StatePurgeRequest(
                vaultId: vaultId,
                sourceClientId: cfg.clientName,
              );
              // Notes keyspace (default) + settings keyspace ('config'), which
              // lives as a sibling StateSync service on the same socket.
              await conn.stateCaller.purgeVault(purge);
              final configCaller = StateSyncContractCaller(
                conn.endpoint,
                serviceNameOverride: StateSyncContractNames.instance('config'),
              );
              await configCaller.purgeVault(purge);
            } finally {
              await conn.dispose();
            }

            // If this device had that vault connected, clear its local state.
            if (engine.config.vaultId == vaultId) {
              engine.cipher = null;
              await _scheduleBoot(() async {
                await engine.stop();
                try {
                  await engine.wipeLocalState();
                } catch (_) {}
              });
              await configStorage.disconnectVault();
            }
            _log.info('Vault deleted: $vaultId');
          }

          late final void Function() refreshSettings;
          refreshSettings = _registerSettings(
            plugin: plugin,
            configStorage: configStorage,
            config: cfg,
            authConfig: authConfig,
            authClient: authClient,
            accountClient: accountClient,
            engine: engine,
            buildConfig: buildConfig,
            settingsSyncPrefs: () => settingsPrefs,
            onDeleteVault: deleteVaultClosure,
            selfHostEnabled: selfHostActive,
            selfHostUrl: selfHost.syncUrl,
            selfHostDirectory: selfHostActive ? directory : null,
            onSettingsSyncChanged: (next) async {
              settingsPrefs = next;
              await configStorage.saveSettingsSync(next.toJson());
              if (cipher != null) {
                await _launchConfigSync(
                  engine: engine,
                  dataClient: dataClient,
                  cipher: cipher!,
                  vaultId: vaultId,
                  plugin: plugin,
                  prefs: settingsPrefs,
                );
              }
              refreshSettings();
            },
            diagnosticsPrefs: () => diagnosticsPrefs,
            onDiagnosticsChanged: (next) async {
              // Persist + apply live; deliberately NO refreshSettings() — the
              // URL text field's onChange fires per keystroke and a tab rebuild
              // would drop the caret. Obsidian's own widgets hold their state.
              diagnosticsPrefs = next;
              await configStorage.saveDiagnostics(next.toJson());
              _diagnostics?.apply(next);
            },
            fileFilterPrefs: () => fileFilterPrefs,
            onFileFilterChanged: (next) async {
              // Persist + swap the live var; the engine reads the denylist
              // through its callback, so uploads/downloads for changed types
              // take effect on the next reconcile/pull. Re-including a type
              // that was previously skipped re-fetches its files on the next
              // server notify (or via the panel's Download-from-server action).
              // No refreshSettings() — the extensions text field fires per
              // keystroke and a tab rebuild would drop the caret.
              fileFilterPrefs = next;
              await configStorage.saveFileFilter(next.toJson());
              engine.triggerPull();
            },
          );

          // Resume/Pause commands mirror the panel buttons — same persisted
          // pause flag, same code path (setSyncPaused). "Resume" first ensures
          // a vault key, then clears the pause and starts the session.
          plugin.addCommand(
            id: 'rhyolite-sync-start',
            name: 'Resume sync',
            callback: () async {
              if (cipher == null) {
                final verificationToken = config?.verificationToken;
                if (verificationToken != null && verificationToken.isNotEmpty) {
                  cipher = await withModalLock(
                    () => showPassphraseModal(
                      plugin,
                      configStorage,
                      vaultId: cfg.vaultId,
                      verificationToken: verificationToken,
                    ),
                  );
                }
                if (cipher == null) return;
                engine.cipher = cipher;
              }
              await setSyncPaused(false);
            },
          );
          plugin.addCommand(
            id: 'rhyolite-sync-stop',
            name: 'Pause sync',
            callback: () => setSyncPaused(true),
          );
          plugin.addCommand(
            id: 'rhyolite-sync-now',
            name: 'Sync Now',
            callback: () async {
              await engine.triggerPull();
              _log.info('Manual sync triggered');
            },
          );
          plugin.addCommand(
            id: 'rhyolite-sync-config-now',
            name: 'Sync settings now (.obsidian)',
            callback: () async {
              final cs = _configSync;
              if (cs == null) {
                _log.info('Settings sync is off');
                return;
              }
              await cs.sync();
              _log.info('Manual settings sync triggered');
            },
          );
          plugin.addCommand(
            id: 'rhyolite-cleanup-storage',
            name: 'Clean up storage (history + blobs)',
            callback: () {
              showStorageCleanupModal(plugin, engine);
            },
          );
          plugin.addCommand(
            id: 'rhyolite-manage-devices',
            name: 'Manage sync devices',
            callback: () {
              showDeviceManagementModal(plugin, engine);
            },
          );
          plugin.addCommand(
            id: 'rhyolite-storage-overview',
            name: 'Storage overview',
            callback: () {
              showStorageOverviewModal(plugin, engine);
            },
          );
          plugin.addCommand(
            id: 'rhyolite-reclaim-orphans',
            name: 'Reclaim orphaned blobs',
            callback: () {
              showOrphanSweepModal(plugin, engine);
            },
          );
          plugin.addCommand(
            id: 'rhyolite-configure-selfhost',
            name: 'Configure self-host server',
            callback: () async {
              final changed = await withModalLock(
                () => showSelfHostModal(plugin, configStorage),
              );
              if (changed) {
                // Re-run onLoad so the new mode takes effect immediately.
                reloadPlugin(plugin);
              }
            },
          );
          plugin.addCommand(
            id: 'rhyolite-show-file-history',
            name: 'Show version history for current file',
            callback: () {
              showFileVersionModal(plugin, engine);
            },
          );

          if (cipher == null) {
            _log.info(
              'No vault key — sync disabled. Sign in and connect a vault.',
            );
          } else if (syncServerUrl.isEmpty) {
            _log.info('Server URL not set — sync disabled.');
          } else if (_syncPaused) {
            _log.info(
              'Sync paused by user — skipping start. Resume from the '
              'sync panel.',
            );
          } else {
            // Defer start so plugin onload returns immediately and Obsidian
            // UI stays responsive while sync warms up. If start blocks the
            // event loop later, the user can still reach Stop Sync / Disable.
            // Caps are cached BEFORE start() inside startSyncSession — the
            // startup size gate needs the tier before StartupDiff runs.
            Future<void>.delayed(Duration.zero, () async {
              try {
                await startSyncSession();
              } catch (e, st) {
                _log.error('Engine start failed', error: e, stackTrace: st);
              }
            });
          }

          // Resume-from-background recovery. When Obsidian is backgrounded
          // — mobile multitasking, desktop sleep, OS suspending the
          // WebView — the WebSocket can die silently: client-side state
          // says "Online" but every send hangs. The user returns, edits,
          // nothing syncs, until they manually run Start Sync (which
          // tears down and rebuilds the engine).
          //
          // Hook visibilitychange: when the tab becomes visible, run a
          // cheap healthCheck. If it fails, the transport is stale —
          // restart the engine. `registerDomEvent` ensures the listener
          // is removed on plugin unload (community-plugin requirement).
          {
            var recoverInFlight = false;
            final documentJs = jsu.getProperty<JSObject?>(
              jsu.globalThis,
              'document',
            );

            // Shared recovery: cheap healthCheck; if the transport is stale
            // restart the engine, otherwise re-arm notify + opportunistically
            // pull so anything missed while offline/backgrounded lands.
            // [requireVisible] gates the resume path (visibilitychange) on the
            // tab actually being visible; the network path (online) fires
            // regardless.
            Future<void> recoverConnection({required bool requireVisible}) async {
              if (recoverInFlight || _syncPaused) return;
              if (requireVisible && documentJs != null) {
                final visible =
                    jsu.getProperty<String?>(documentJs, 'visibilityState') ==
                    'visible';
                if (!visible) return;
              }
              if (_engine == null) return;
              recoverInFlight = true;
              try {
                final ok = await _engine!.healthCheck(
                  timeout: const Duration(seconds: 5),
                );
                if (!ok) {
                  _log.warning('Health check failed — restarting engine');
                  try {
                    await _scheduleBoot(() async {
                      await _engine!.stop();
                      await _guardedStart(_engine!);
                    });
                    if (cipher != null) {
                      await _launchConfigSync(
                        engine: _engine!,
                        dataClient: dataClient,
                        cipher: cipher!,
                        vaultId: vaultId,
                        plugin: plugin,
                        prefs: settingsPrefs,
                      );
                    }
                  } catch (e) {
                    _log.error('Engine restart on recover failed: $e');
                  }
                } else {
                  await _engine!.reissueNotify();
                  await _engine!.triggerPull();
                  _configSync?.handleReconnect();
                  await _configSync?.sync();
                }
              } finally {
                recoverInFlight = false;
              }
            }

            // Resume-from-background: WebSocket can die silently while the WebView
            // is suspended; check on return to visibility. Leaving (hidden) is
            // also a settings sync point: `.obsidian` has no vault events, so
            // push any pending local settings the moment the user switches away
            // — other devices then get them via notify before the user arrives,
            // instead of only on the next return-to-visible.
            if (documentJs != null) {
              jsu.callMethod<void>(plugin.raw, 'registerDomEvent', [
                documentJs,
                'visibilitychange',
                jsu.allowInterop((JSAny? _) {
                  final visible = jsu.getProperty<String?>(
                        documentJs,
                        'visibilityState',
                      ) ==
                      'visible';
                  if (visible) {
                    recoverConnection(requireVisible: true);
                  } else if (!_syncPaused) {
                    // Best-effort, no delay: the WebView can suspend right after
                    // 'hidden' (mobile), so fire immediately. sync() is _busy-safe
                    // and a no-op when nothing changed (signature guard).
                    final cs = _configSync;
                    if (cs != null) unawaited(cs.sync());
                  }
                }),
              ]);
            }
            // Network restored: reconnect immediately instead of waiting out the
            // transport's reconnect backoff.
            jsu.callMethod<void>(plugin.raw, 'registerDomEvent', [
              jsu.globalThis,
              'online',
              jsu.allowInterop(
                (JSAny? _) => recoverConnection(requireVisible: false),
              ),
            ]);
          }

          // Settings-dialog close is a cross-platform "settings changed" signal.
          // Obsidian emits no vault event for `.obsidian`, but nearly every
          // settings edit happens inside this dialog, so pushing on its close
          // propagates changes immediately (still on this device) instead of
          // only on the next resume. We wrap `app.setting.close`; a short settle
          // delay lets settings that flush their file write on close land before
          // the scan. Restored on unload via plugin.register so a reloaded plugin
          // neither stacks wrappers nor pins a disposed engine.
          {
            final setting = jsu.getProperty<Object?>(plugin.app.raw, 'setting');
            final originalClose = setting == null
                ? null
                : jsu.getProperty<Object?>(setting, 'close');
            if (setting != null && originalClose != null) {
              jsu.setProperty(
                setting,
                'close',
                jsu.allowInterop(() {
                  jsu.callMethod<void>(originalClose, 'call', [setting]);
                  if (_syncPaused) return;
                  Timer(const Duration(milliseconds: 400), () {
                    final cs = _configSync;
                    if (cs != null) unawaited(cs.sync());
                  });
                }),
              );
              jsu.callMethod<void>(plugin.raw, 'register', [
                jsu.allowInterop(
                  () => jsu.setProperty(setting, 'close', originalClose),
                ),
              ]);
            }
          }

          // Listen for session expiry and prompt re-authentication.
          // `_autoSignInInFlight` dedupes overlapping SessionExpired
          // events while the auto sign-in flow is mid-wait or mid-modal.
          var _autoSignInInFlight = false;
          _engineAuthEventsSub = engine.events.listen((event) async {
            // Every engine (re)start in this listener (blob-config adopt,
            // token refresh, re-auth) must also relaunch settings sync —
            // otherwise .obsidian config stops syncing after any auth recovery.
            Future<void> relaunchConfigSync() async {
              if (cipher == null) return;
              await _launchConfigSync(
                engine: engine,
                dataClient: dataClient,
                cipher: cipher!,
                vaultId: vaultId,
                plugin: plugin,
                prefs: settingsPrefs,
              );
            }

            switch (event) {
              case ExternalBlobConfigDiscovered(:final configJson):
                _log.info('External blob config discovered from server');
                final extConfig = ExternalBlobConfig.fromJson(configJson);
                if (extConfig != null) {
                  // Build on top of the *current* config, not the initial
                  // load-time snapshot — `cfg` is `final` and misses any
                  // post-load edits (verification token rotation, vault
                  // rename, etc.). Persist only the non-secret kind marker
                  // (VaultConfig.toJson drops the secret); the secret stays in
                  // memory + on the E2EE server.
                  final base = config ?? cfg;
                  final updated = base.copyWith(
                    externalBlobConfig: extConfig,
                    externalStorageKind: extConfig.kind,
                  );
                  config = updated;
                  await configStorage.save(updated);
                  if (engine.config.externalBlobConfig == null) {
                    // Runtime discovery — the engine wasn't started with the
                    // secret, so adopt it and restart to pick up the backend.
                    engine.config = buildConfig(updated, authClient);
                    await _scheduleBoot(() async {
                      await engine.stop();
                      await _guardedStart(engine);
                    });
                    await relaunchConfigSync();
                    _log.info('Restarted with external blob storage');
                  }
                  // Otherwise the engine already self-applied the secret in
                  // _checkExternalBlobConfig during this start() — no restart.
                  // Re-render the settings tab so it shows "Connected: ..."
                  // instead of the snapshot's "Configure" buttons.
                  refreshSettings();
                }
                return;
              case SubscriptionRequired():
                return;
              case SessionExpired():
                // Self-host has no account session — never prompt for sign-in.
                if (selfHostActive) return;
                break; // fall through to refresh handler below
              // Catch-all for every other policy/auth rejection (managed
              // storage unavailable, quota exceeded, permission denied,
              // unrecognised app_policy code, etc.). Engine has already
              // stopped via its own fatal-rejection handler; we just log
              // and let the sync indicator surface the state. Crucially:
              // no auto-restart — that's what was creating the per-record
              // grind loop that froze Obsidian.
              case SyncServerRejected(:final code, :final message)
                  when code.startsWith('auth.') ||
                      code.startsWith('app_policy.'):
                _log.warning('Sync paused — server refused ($code): $message');
                return;
              default:
                return;
            }
            _log.warning('Auth rejected — attempting token refresh');

            final client = authClient;
            if (client != null) {
              try {
                final session = await client.refreshSession();
                await configStorage.saveAuthSession(session);
                _setEngineAuth(engine, client);
                engine.config = buildConfig(cfg, client);
                await _scheduleBoot(() => _guardedStart(engine));
                await relaunchConfigSync();
                _log.info('Token refreshed — restarted');
                return;
              } catch (_) {
                _log.warning('Refresh failed — prompting re-authentication');
              }
            }

            await configStorage.clearAuthSession();
            authClient = null;
            _setEngineAuth(engine, null);
            engine.config = cfg;

            if (!authConfig.isConfigured) return;

            // Dedupe: multiple SessionExpired events can fire in
            // quick succession (notify reconnect, pending RPCs all
            // failing). Without this flag every one of them would
            // queue its own awaitModalClose + showSignInModal.
            if (_autoSignInInFlight) return;
            _autoSignInInFlight = true;
            try {
              if (isModalOpen) {
                _log.info(
                  'Session expired — waiting for current modal '
                  'to close before prompting re-auth',
                );
                await awaitModalClose();
                // World may have moved on while we waited (user might
                // have signed in via Settings, or refreshed the token
                // through another flow). Try refresh once more; if it
                // succeeds no prompt is needed.
                try {
                  final session = await accountClient.refreshSession();
                  await configStorage.saveAuthSession(session);
                  authClient = accountClient;
                  _setEngineAuth(engine, accountClient);
                  engine.config = buildConfig(cfg, accountClient);
                  await _guardedStart(engine);
                  await relaunchConfigSync();
                  _log.info(
                    'Token refreshed after modal closed — no prompt needed',
                  );
                  return;
                } catch (_) {
                  // Still bad — fall through and prompt.
                }
              }
              // Browser-auth is the only sign-in method, so there is no
              // credential modal to pop here. Point the user at Settings,
              // where the "Sign in" button starts the browser handoff; its
              // protocol handler re-auths the engine on return.
              showNotice(
                'Rhyolite: session expired. Open Settings → Rhyolite Sync '
                'and press Sign In.',
              );
              final setting = jsu.getProperty<Object?>(
                plugin.app.raw,
                'setting',
              );
              if (setting != null) {
                jsu.callMethod<void>(setting, 'open', []);
                jsu.callMethod<void>(setting, 'openTabById', ['rhyolite-sync']);
              }
            } finally {
              _autoSignInInFlight = false;
            }
          });
        },
        (error, stack) {
          if (_isSqliteCorrupt(error)) {
            onCorruptDb();
          } else {
            _log.error('Unhandled error', error: error, stackTrace: stack);
          }
        },
      );
    },
    onUnload: (_) async {
      _stopConfigSync();
      await _configReconnectSub?.cancel();
      _configReconnectSub = null;
      await _engineAuthEventsSub?.cancel();
      _engineAuthEventsSub = null;
      await _deletedVaultWatchSub?.cancel();
      _deletedVaultWatchSub = null;
      _syncIndicator?.dispose();
      _syncIndicator = null;
      _syncPanel?.closeLeaves();
      _syncPanel?.dispose();
      _syncPanel = null;
      // Close the remote log sink's WebSocket, if the user had it on.
      _diagnostics?.dispose();
      _diagnostics = null;
      await _engine?.stop();
      _engine = null;
      await _scheduler?.dispose();
      _scheduler = null;
      await _dbConn?.close();
      _dbConn = null;
    },
  );
}

// Returns the `refreshSettings` callback so the caller can re-render the
// settings tab in response to events that update vault config from
// outside the tab itself (notably ExternalBlobConfigDiscovered).
/// Resolves the external-blob meta store for the active edition: the self-host
/// registry when connected, otherwise the account service (managed).
IVaultMetaStorage? _sessionMetaStorage(
  IVaultDirectory? selfHostDirectory,
  RpcAccountClient? authClient,
) {
  if (selfHostDirectory != null) return selfHostDirectory.metaStorage;
  if (authClient != null) return AccountVaultMetaStorage(authClient);
  return null;
}

void Function() _registerSettings({
  required PluginHandle plugin,
  required ObsidianConfigStorage configStorage,
  required VaultConfig config,
  required AuthConfig authConfig,
  required RpcAccountClient? authClient,
  required RpcAccountClient accountClient,
  required ISyncEngine engine,
  required VaultConfig Function(VaultConfig, RpcAccountClient?) buildConfig,
  required SettingsSyncPrefs Function() settingsSyncPrefs,
  required Future<void> Function(SettingsSyncPrefs next) onSettingsSyncChanged,
  required DiagnosticsPrefs Function() diagnosticsPrefs,
  required Future<void> Function(DiagnosticsPrefs next) onDiagnosticsChanged,
  required FileFilterPrefs Function() fileFilterPrefs,
  required Future<void> Function(FileFilterPrefs next) onFileFilterChanged,
  required Future<void> Function(VaultInfo vault) onDeleteVault,
  required bool selfHostEnabled,
  required String selfHostUrl,
  IVaultDirectory? selfHostDirectory,
}) {
  late final void Function() refreshSettings;
  refreshSettings = registerSettingsTab(
    plugin: plugin,
    configStorage: configStorage,
    config: config,
    authConfig: authConfig,
    authClient: authClient,
    accountClient: accountClient,
    onFetchUsage: (selfHostEnabled || config.externalBlobConfig != null)
        ? () async =>
              null // no managed quota on self-host / BYO
        : () => _fetchVaultUsage(engine, config.vaultId),
    openUrl: _openExternalUrl,
    authWebUrl: kEnv.siteUrl,
    onConfigChanged: (updated) async {
      engine.config = buildConfig(updated, authClient);
      // Route the restart through the lifecycle lane so it can't overlap a
      // queued reconnect / token-refresh boot on the single WebSocket.
      await _scheduleBoot(() async {
        await engine.stop();
        await _guardedStart(engine);
      });
    },
    onAuthChanged: (newAuthConfig, client) async {
      authClient = client;
      _setEngineAuth(engine, client);
      engine.config = buildConfig(config, client);
      _log.info('Signed in');
    },
    onSignOut: () async {
      authClient = null;
      _setEngineAuth(engine, null);
      engine.config = config;
      await _scheduleBoot(() => engine.stop());
      _log.info('Signed out');
    },
    onDisconnectVault: () async {
      // Order matters: stop the engine BEFORE wiping the local stores
      // so no in-flight reconcile/push can resurrect rows mid-wipe.
      // wipeLocalState reads config.vaultId, which stays in memory on
      // the engine even after configStorage.disconnectVault() has
      // cleared the on-disk vault config. Runs on the lifecycle lane so a
      // queued boot can't start the engine mid-wipe.
      engine.cipher = null;
      await _scheduleBoot(() async {
        await engine.stop();
        try {
          await engine.wipeLocalState();
        } catch (e) {
          _log.error('Vault disconnect: local wipe failed', error: e);
        }
      });
      _log.info('Vault disconnected (local state wiped)');
    },
    onVaultChanged: (newConfig, newCipher) async {
      engine.config = buildConfig(newConfig, authClient);
      engine.cipher = newCipher;
      await _scheduleBoot(() async {
        await engine.stop();
        await _guardedStart(engine);
      });
      _log.info('Switched to vault ${newConfig.vaultId}');
    },
    onDeleteVault: onDeleteVault,
    onSubscribed: () => _waitForSubscriptionAndStart(
      plugin: plugin,
      engine: engine,
      accountClient: accountClient,
      onDone: refreshSettings,
    ),
    onResetVault: () async {
      await engine.triggerReset();
      _log.info('Vault re-upload initiated');
    },
    onRestoreFromServer: () async {
      await engine.triggerRestoreFromServer();
      _log.info('Vault restore from server initiated');
    },
    onRepairVault: () async {
      await engine.triggerRepair();
      _log.info('Vault repair initiated');
    },
    onSaveExternalBlobConfig: (extConfig) async {
      // Fail loudly. Silent skips here mean the user ticked Configure,
      // saw the modal close, but the encrypted config never reached the
      // server — so other devices never adopt it, and a local-DB wipe
      // on this device loses it forever. The settings tab catches these
      // throws and surfaces them as a Notice.
      final store = _sessionMetaStorage(selfHostDirectory, authClient);
      if (store == null) {
        throw StateError(
          'Connect a vault before configuring external storage.',
        );
      }
      // Read the LIVE cipher/vaultId off the engine, not the values captured
      // when the settings tab was registered — after a vault switch those
      // are stale, and the config would be encrypted with the old vault's
      // key and stored under its id.
      final c = engine.cipher;
      if (c == null) {
        throw StateError('Vault is locked — enter your passphrase first.');
      }
      final metaService = VaultMetaService(
        storage: store,
        vaultId: engine.config.vaultId,
        cipher: c,
      );
      await metaService.saveExternalBlobConfig(extConfig);
      _log.info('External blob config saved');
    },
    onClearExternalBlobConfig: () async {
      final store = _sessionMetaStorage(selfHostDirectory, authClient);
      if (store == null) {
        throw StateError('Connect a vault before clearing external storage.');
      }
      // Live engine values, not the registration-time snapshot (see save).
      final c = engine.cipher;
      if (c == null) {
        throw StateError('Vault is locked — enter your passphrase first.');
      }
      final metaService = VaultMetaService(
        storage: store,
        vaultId: engine.config.vaultId,
        cipher: c,
      );
      await metaService.clearExternalBlobConfig();
      _log.info('External blob config cleared');
    },
    settingsSyncPrefs: settingsSyncPrefs,
    onSettingsSyncChanged: onSettingsSyncChanged,
    diagnosticsPrefs: diagnosticsPrefs,
    onDiagnosticsChanged: onDiagnosticsChanged,
    fileFilterPrefs: fileFilterPrefs,
    onFileFilterChanged: onFileFilterChanged,
    onResetSettings: () async {
      final cs = _configSync;
      if (cs == null) {
        throw StateError('Settings sync is off.');
      }
      await cs.resetFromThisDevice();
      _log.info('Settings re-upload finished');
    },
    onRestoreSettings: () async {
      final cs = _configSync;
      if (cs == null) {
        throw StateError('Settings sync is off.');
      }
      await cs.restoreFromServer();
      _log.info('Settings download finished');
    },
    selfHostEnabled: selfHostEnabled,
    selfHostUrl: selfHostUrl,
    selfHostDirectory: selfHostDirectory,
  );
  return refreshSettings;
}

/// Polls the account service's getSubscription endpoint every 10 seconds for up to 5 minutes.
/// Shows a modal with a spinner while waiting. Starts the engine on success.
Future<void> _waitForSubscriptionAndStart({
  required PluginHandle plugin,
  required ISyncEngine engine,
  required RpcAccountClient accountClient,
  void Function()? onDone,
}) async {
  const interval = Duration(seconds: 10);
  const timeout = Duration(minutes: 5);
  final deadline = DateTime.now().add(timeout);

  _log.info('Waiting for subscription activation...');

  ModalContext<void>? modalCtx;
  SpinnerRef? spinnerRef;

  // Open a modal with a spinner — the polling runs in the background.
  // We capture ctx/spinner via the build closure and close/update from below.
  unawaited(
    showModalWith<void>(
      plugin,
      build: (ctx) {
        modalCtx = ctx;
        ctx.h3('Activating subscription…');
        ctx.spaceVertical(px: 12);
        ctx.createEl('p', text: 'Please wait while we confirm your payment.');
        ctx.spaceVertical(px: 12);
        spinnerRef = ctx.spinner(label: 'Checking…');
        spinnerRef!.show();
        ctx.spaceVertical(px: 4);
        ctx.onEscape(() {}); // disable accidental close
      },
    ),
  );

  // Give the modal a moment to render before polling starts.
  await Future<void>.delayed(const Duration(milliseconds: 300));

  bool confirmed = false;

  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(interval);

    try {
      final subscription = await accountClient.getSubscription();
      _capabilities = subscription.capabilities;
      if (subscription.isActive) {
        confirmed = true;
        break;
      }
      _log.debug('Subscription not yet active, retrying...');
    } catch (e) {
      _log.error('checkAccess error', error: e);
    }
  }

  final ctx = modalCtx;
  if (ctx == null) return;

  if (confirmed) {
    _log.info('Subscription confirmed — starting engine');
    spinnerRef?.hide();
    // Replace modal content with success message.
    ctx.close(null);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await showModalWith<void>(
      plugin,
      build: (ctx2) {
        ctx2.h3('🎉 Subscription activated!');
        ctx2.spaceVertical(px: 12);
        ctx2.createEl(
          'p',
          text: 'Your subscription is now active. Sync will start shortly.',
        );
        ctx2.spaceVertical(px: 16);
        ctx2.buttonRow([
          ButtonSpec(
            'Got it',
            () => ctx2.close(null),
            variant: ButtonVariant.primary,
          ),
        ]);
        ctx2.onEscape(() => ctx2.close(null));
      },
    );
    onDone?.call();
    await _guardedStart(engine);
  } else {
    _log.warning('Subscription not activated within 5 minutes');
    spinnerRef?.hide();
    ctx.close(null);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await showModalWith<void>(
      plugin,
      build: (ctx2) {
        ctx2.h3('Payment not confirmed');
        ctx2.spaceVertical(px: 12);
        ctx2.createEl(
          'p',
          text:
              'We could not confirm your payment within 5 minutes. '
              'If you completed the payment, please restart Obsidian. '
              'If the issue persists, contact support.',
        );
        ctx2.spaceVertical(px: 16);
        ctx2.buttonRow([ButtonSpec('Close', () => ctx2.close(null))]);
        ctx2.onEscape(() => ctx2.close(null));
      },
    );
    onDone?.call();
  }
}
