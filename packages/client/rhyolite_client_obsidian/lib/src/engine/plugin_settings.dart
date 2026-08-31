// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_client_account/rhyolite_client_account.dart'
    hide VaultInfo;
import 'package:rhyolite_client_obsidian/src/engine/vault_picker_modal.dart';
import 'package:rhyolite_client_obsidian/src/vault/managed_vault_directory.dart';
import 'package:rhyolite_client_obsidian/src/vault/vault_directory.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:uuid/uuid.dart';

import '../i18n/i18n.dart';
import '../settings/diagnostics_prefs.dart';
import '../settings/file_filter_prefs.dart';
import '../settings/plugin_code_gate.dart';
import 'plan_status.dart';
import '../settings/settings_sync_prefs.dart';
import '../settings/settings_sync_settings_ui.dart';
import 'build_env.dart';
import 'db_recovery.dart';
import 'modal_lock.dart';
import 'obsidian_config_storage.dart';
import 'self_host_modal.dart';

/// Registers the settings tab. The tab rebuilds its UI on every open so that
/// auth and vault state are always up to date.
///
/// Returns:
///  * `refresh` — re-render the tab immediately (e.g. right after
///    sign-in/sign-out, without waiting for the user to reopen it);
///  * `beginSignIn` — start the browser sign-in flow. Handed out because the
///    state nonce and the `obsidian://rhyolite-auth` handler that redeems it
///    live in here, and the sync panel needs to offer the same one-click
///    sign-in without sending the user to the settings tab to find it.
({void Function() refresh, void Function() beginSignIn}) registerSettingsTab({
  required PluginHandle plugin,
  required ObsidianConfigStorage configStorage,
  required VaultConfig config,
  required AuthConfig authConfig,
  // Read LIVE, never snapshotted. The account client is replaced on every
  // sign-in and on every token refresh the recovery handler performs, and a
  // by-value copy here is precisely the bug [AuthSessionState] exists to
  // prevent: the tab kept reporting the session it was registered with and
  // offered "Sign in" to a user who already was.
  required RpcAccountClient? Function() authClient,
  required RpcAccountClient accountClient,
  required Future<({int usedBytes, int quotaBytes})?> Function() onFetchUsage,
  required void Function(String url) openUrl,
  // Public site base URL. Browser-auth ("Sign in") opens
  // `$authWebUrl/auth?client=plugin` and the site redirects back via the
  // obsidian://rhyolite-auth protocol handler.
  required String authWebUrl,
  required void Function(VaultConfig updated) onConfigChanged,
  required void Function(AuthConfig updated, RpcAccountClient client)
  onAuthChanged,
  required void Function() onSignOut,
  required void Function() onDisconnectVault,
  required void Function(VaultConfig config, VaultCipher cipher) onVaultChanged,
  // Permanently delete a vault's server data + registration. Shown as a
  // per-vault "Delete" button in the vault picker.
  required Future<void> Function(VaultInfo vault) onDeleteVault,
  required void Function() onSubscribed,
  required Future<void> Function() onResetVault,
  required Future<void> Function() onRestoreFromServer,
  required Future<void> Function() onRepairVault,
  required Future<void> Function(ExternalBlobConfig config)
  onSaveExternalBlobConfig,
  required Future<void> Function() onClearExternalBlobConfig,
  required SettingsSyncPrefs Function() settingsSyncPrefs,
  required Future<void> Function(SettingsSyncPrefs next) onSettingsSyncChanged,
  // Whether the storage backing this vault can hold a plugin set, and how much
  // the plugins installed on this device weigh (pre-formatted, null when not
  // measured yet). Together they turn the plugin-code row from a toggle the
  // user can trip into an informed choice.
  required PluginCodeAvailability Function() pluginCodeAvailability,
  required String? Function() pluginCodeSize,
  // The host's current plan alert, and a way to hand it a fresher answer. This
  // tab makes its own getSubscription call, so without the report-back the two
  // could disagree about whether a subscription has lapsed — and the host owns
  // the comparison that decides, since only it remembers the previous plan.
  required PlanNotice Function() planNotice,
  required void Function(SubscriptionDto sub) onSubscriptionFetched,
  // Opens the storage overview from the settings tab, so it is reachable
  // without going through the sync panel.
  required Future<void> Function() onShowStorageOverview,
  required Future<void> Function() onResetSettings,
  required Future<void> Function() onRestoreSettings,
  // Remote diagnostics logging (advanced, off by default). Lets a user stream
  // this device's debug logs to a collector URL for support/debugging.
  required DiagnosticsPrefs Function() diagnosticsPrefs,
  required Future<void> Function(DiagnosticsPrefs next) onDiagnosticsChanged,
  // Opens the bug-report flow. Also reachable from the command palette, which
  // is the path that still works when boot failed before this tab was built.
  required Future<void> Function() onCreateBugReport,
  // Erases the on-device diagnostic logs. Logging continues afterwards.
  required Future<void> Function() onClearLogs,
  // Per-device sync filters (folders + file types this device skips, both
  // uploading and downloading). Device-local; default empty (sync all).
  // Applying them restarts the engine — see [addDeviceFiltersSection].
  required FileFilterPrefs Function() fileFilterPrefs,
  required Future<void> Function(FileFilterPrefs next) onFileFilterChanged,
  // Vault-global force-binary list (synced across devices via the engine's
  // encrypted vault-meta). Getter reads the engine's currently-loaded policy;
  // the save callback persists it server-side and applies it live. Unlike the
  // per-device denylist above, this list is the SAME on every device.
  required Set<String> Function() forcedBinaryExtensions,
  required Future<void> Function(Set<String> next) onForcedBinaryChanged,
  // Self-host edition state. When [selfHostEnabled] the managed auth section
  // (sign-in / subscription) is replaced by a self-host vault section that
  // uses [selfHostDirectory] (the sync server's registry).
  required bool selfHostEnabled,
  required String selfHostUrl,
  IVaultDirectory? selfHostDirectory,
}) {
  // Mutable state captured by the builder closure — updated via callbacks.
  var currentConfig = config;
  var currentAuthConfig = authConfig;
  RpcAccountClient? currentAuthClient() => authClient();
  DateTime? subscriptionEnd; // cached per tab open, refreshed on display
  ({int usedBytes, int quotaBytes})? vaultUsage;
  // External (BYO) storage: always available on self-host (own server — lean
  // VPS + cheap external blobs is a real win). On managed it's a Pro-tier
  // feature: hidden for free (no capability), set from plan caps on display.
  var externalStorageAllowed = selfHostEnabled;
  // Owned-vault cap from the plan (managed only). null = no cap (self-host /
  // not yet fetched). Refreshed from getSubscription in buildAsync and passed
  // to the vault picker so a user at their limit isn't offered "+ Create".
  int? maxVaultCount;

  late PluginSettingsTab tab;

  // ---- Browser-auth (single sign-in method) --------------------------------
  // "Sign in" opens the web login; once authenticated the site redirects back
  // to obsidian://rhyolite-auth?code=...&state=.... We match the state nonce,
  // redeem the one-time code for a session, and light auth up exactly like a
  // modal sign-in did. The web/Telegram surface is only the channel — the
  // session belongs to the email account the code is bound to.
  String? pendingAuthState;

  void beginBrowserAuth() {
    final state = const Uuid().v4();
    pendingAuthState = state;
    openUrl(
      '$authWebUrl/auth?client=plugin&state=${Uri.encodeComponent(state)}',
    );
  }

  // Shared tail for every sign-in path (browser callback + hidden code modal):
  // the account client already holds a live session here — persist it, adopt
  // it, notify the engine, re-render.
  Future<void> applySignedIn() async {
    final session = accountClient.session;
    if (session != null) {
      await configStorage.saveAuthSession(session);
    }
    // onAuthChanged rebinds the shared AuthSessionState, which is what
    // currentAuthClient() reads — no local copy to keep in step.
    onAuthChanged(currentAuthConfig, accountClient);
    tab.show();
  }

  // Open the site's account page already signed in as the current user: mint a
  // one-time code and hand it to /auth/web, which sets the web session and
  // lands on /account. Subscription purchase + management live on the site's
  // proven flow, so the plugin just does this handoff.
  Future<void> openAccountOnSite() async {
    final client = currentAuthClient();
    if (client == null) return;
    try {
      final code = await client.issueSessionLoginCode();
      openUrl(
        '$authWebUrl/auth/web?code=${Uri.encodeComponent(code)}'
        '&next=${Uri.encodeComponent('/account')}',
      );
    } catch (e) {
      showNotice(S.couldNotOpenAccountPage(e));
    }
  }

  void build(PluginSettingsTab t) {
    void addSignOutButton(PluginSettingsTab t, String userEmail) => t.addButton(
      name: S.authStatus,
      description: S.signedInAs(userEmail),
      buttonText: S.signOut,
      onClick: () async {
        await currentAuthClient()?.signOut();
        await configStorage.clearAuthSession();
        await configStorage.disconnectVault();
        currentConfig = const VaultConfig(vaultId: '', vaultName: '');
        // Unbinds the shared state, so currentAuthClient() reads null below.
        onSignOut();
        tab.show();
      },
    );

    void addDisconnectVaultButton(PluginSettingsTab t) => t.addButton(
      name: S.disconnectVaultName,
      description: S.disconnectVaultDescription,
      buttonText: S.disconnect,
      onClick: () async {
        final vaultName = currentConfig.vaultName.isNotEmpty
            ? currentConfig.vaultName
            : currentConfig.vaultId;
        final confirmed = await _showDisconnectConfirmation(
          plugin,
          vaultName: vaultName,
        );
        if (!confirmed) return;
        await configStorage.disconnectVault();
        currentConfig = const VaultConfig(vaultId: '', vaultName: '');
        onDisconnectVault();
        tab.show();
      },
    );

    void addTroubleshootingSection(PluginSettingsTab t) {
      t.addSection(S.troubleshooting);

      t.addButton(
        name: S.reuploadName,
        description: S.reuploadDescription,
        buttonText: S.reupload,
        onClick: () async {
          final confirmed = await _showActionConfirmation(
            plugin,
            title: S.reuploadConfirmTitle,
            body: S.reuploadConfirmBody,
            confirmText: S.reupload,
            destructive: true,
          );
          if (!confirmed) return;
          await onResetVault();
        },
      );

      t.addButton(
        name: S.downloadServerName,
        description: S.downloadServerDescription,
        buttonText: S.download,
        onClick: () async {
          final confirmed = await _showActionConfirmation(
            plugin,
            title: S.downloadServerConfirmTitle,
            body: S.downloadServerConfirmBody,
            confirmText: S.download,
            destructive: true,
          );
          if (!confirmed) return;
          await onRestoreFromServer();
        },
      );

      t.addButton(
        name: S.repairName,
        description: S.repairDescription,
        buttonText: S.repairButton,
        onClick: () async {
          final confirmed = await _showActionConfirmation(
            plugin,
            title: S.repairConfirmTitle,
            body: S.repairConfirmBody,
            confirmText: S.repairButton,
            destructive: false,
          );
          if (!confirmed) return;
          try {
            await onRepairVault();
            showNotice(S.repairFinished);
          } catch (e) {
            showNotice(S.repairFailed(e));
          }
        },
      );
    }

    void addConnectVaultButton(PluginSettingsTab t) => t.addButton(
      name: S.connectVaultName,
      description: S.connectVaultDescription,
      buttonText: S.connectVaultButton,
      onClick: () async {
        final IVaultDirectory? dir;
        if (selfHostEnabled) {
          dir = selfHostDirectory;
        } else {
          // Session present is enough — the directory's first call refreshes
          // an expired access token by itself. Requiring a fresh one made this
          // button silently do nothing for the first seconds after a restart.
          final client = currentAuthClient();
          dir = (client != null && client.session != null)
              ? ManagedVaultDirectory(client)
              : null;
        }
        if (dir == null) return;
        if (currentConfig.vaultId.isNotEmpty) return;

        final result = await withModalLock(
          () => showVaultPickerModal(
            plugin,
            dir!,
            configStorage,
            onDeleteVault: onDeleteVault,
            maxVaultCount: selfHostEnabled ? null : maxVaultCount,
          ),
        );
        if (result != null) {
          currentConfig = result.$1;
          onVaultChanged(result.$1, result.$2);
          tab.show();
        }
      },
    );

    void addSelfHostSection(PluginSettingsTab t) {
      t.addSection(S.selfHostSection);
      t.addButton(
        name: selfHostEnabled ? S.selfHostEnabledName : S.selfHostName,
        description: selfHostEnabled
            ? S.selfHostServer(selfHostUrl)
            : S.selfHostDescription,
        buttonText: selfHostEnabled ? S.selfHostReconfigure : S.selfHostEnable,
        onClick: () async {
          final changed = await withModalLock(
            () => showSelfHostModal(plugin, configStorage),
          );
          if (changed) {
            // Apply immediately by re-running the plugin's onLoad (disable +
            // re-enable) — no manual reload, no account interaction.
            showNotice(S.applyingSelfHost);
            unawaited(reloadPlugin(plugin));
          }
        },
      );
    }

    // Single sign-in entry point: hand off to the web login and let the site
    // redirect back through the obsidian://rhyolite-auth protocol handler.
    // Both sign-in and account creation happen in the browser, so there is no
    // in-plugin email/password form to maintain (RF law also bars the site
    // from acting as anything but our own email/password authorizer).
    void addBrowserSignInButton(PluginSettingsTab t) => t.addButton(
      name: S.signIn,
      description: S.signInDescription,
      buttonText: S.signInButton,
      primary: true,
      onClick: () {
        if (!currentAuthConfig.isConfigured) return;
        beginBrowserAuth();
      },
    );

    void addSubscriptionSection(PluginSettingsTab t, DateTime? periodEnd) {
      t.addSection(S.subscriptionSection);
      if (periodEnd != null) {
        final day = periodEnd.day.toString().padLeft(2, '0');
        final month = periodEnd.month.toString().padLeft(2, '0');
        final year = periodEnd.year;
        t.addCustom((s) {
          s.setName(S.activeUntil('$day.$month.$year'));
          s.setDesc(S.subscriptionActive);
        });
        t.addButton(
          name: S.manageSubscription,
          description: S.manageSubscriptionDescription,
          buttonText: S.manageOnSite,
          onClick: openAccountOnSite,
        );
      } else {
        // A subscription that ended used to land in the same branch as one
        // that never existed — a bare "Subscribe" button, with nothing to say
        // that the plan lapsed or when. That is the branch a confused user
        // arrives at after their uploads start being refused for quota.
        final alert = planNotice();
        if (alert.alert == PlanAlert.ended) {
          t.addCustom((s) {
            s.setName(alert.date == null
                ? S.planEndedNoDate
                : S.endedOn(formatPlanDay(alert.date!)));
            s.setDesc(S.subscriptionEnded);
          });
        }
        t.addButton(
          name: S.subscribe,
          description: S.subscribeDescription,
          buttonText: S.subscribe,
          primary: true,
          onClick: openAccountOnSite,
        );
        t.addButton(
          name: S.alreadyPaid,
          description: S.alreadyPaidDescription,
          buttonText: S.restoreSubscription,
          onClick: () async {
            final client = currentAuthClient();
            if (client == null) return;
            await _showRestoreSubscriptionModal(
              plugin,
              onRestore: () async {
                final restored = await client.restoreSubscription();
                return restored;
              },
              onSubscribed: () {
                onSubscribed();
                tab.show();
              },
            );
          },
        );
      }
    }

    // Remote diagnostics — advanced, off by default. Set the URL first, then
    // flip the toggle: the URL field persists silently (no live reconnect
    // churn), and enabling reads the stored URL and starts streaming. Text
    // onChange never refreshes the tab, so typing the URL keeps the caret.
    void addDiagnosticsSection(PluginSettingsTab t) {
      final prefs = diagnosticsPrefs();
      t.addSection(S.diagnosticsSection);
      // First in the section, above the collector rows: this is the one thing
      // here an ordinary user is ever meant to press. The collector below it
      // is a developer tool that happens to live under the same heading.
      t.addButton(
        name: S.bugReportSettingName,
        description: S.bugReportSettingDescription,
        buttonText: S.bugReportCreate,
        onClick: onCreateBugReport,
      );
      // Next to the report button: the two are the same subject — the logs
      // this device keeps — seen from opposite ends.
      t.addButton(
        name: S.clearLogsName,
        description: S.clearLogsDescription,
        buttonText: S.clearLogsButton,
        onClick: onClearLogs,
      );
      t.addText(
        name: S.logCollectorUrl,
        description: S.logCollectorDescription,
        initialValue: prefs.url,
        placeholder: kDefaultLogUri.isNotEmpty
            ? kDefaultLogUri
            : 'wss://collector.example.com:9500',
        onChange: (v) => onDiagnosticsChanged(
          diagnosticsPrefs().copyWith(url: v.trim()),
        ),
      );
      t.addToggle(
        name: S.sendLogsToCollector,
        description: S.sendLogsDescription,
        initialValue: prefs.enabled,
        onChange: (v) => onDiagnosticsChanged(
          diagnosticsPrefs().copyWith(enabled: v),
        ),
      );
    }

    // Per-device filters: which folders and file types THIS device syncs.
    // One group, one Save — applying any of them restarts the engine, because
    // only a full startup scan re-evaluates every path and materialises what a
    // widened filter brought back into view. That rules out the per-keystroke
    // commit the extension field used to have.
    //
    // Typed, not picked. A folder picker shipped here briefly and earned
    // nothing: the complaint this feature answers was having to name every
    // folder you did NOT want, and an include list already reduces that to
    // one or two you do. What the picker did add was a list built from the
    // files on THIS device — which omits exactly the folders you excluded
    // earlier, making the filter one-way.
    void addDeviceFiltersSection(PluginSettingsTab t) {
      var include = fileFilterPrefs().pathScope.include;
      var exclude = fileFilterPrefs().pathScope.exclude;
      var extensions = fileFilterPrefs().excludedExtensions;

      Future<void> commit() async {
        try {
          await onFileFilterChanged(
            fileFilterPrefs().copyWith(
              excludedExtensions: extensions,
              pathScope: PathScope(include: include, exclude: exclude),
            ),
          );
          showNotice(S.deviceFiltersSaved);
          tab.show();
        } catch (e) {
          showNotice(S.filtersSaveFailed(e));
        }
      }

      _addGroupHeading(t, S.deviceSettingsSection, S.deviceSettingsNote);
      t.addText(
        name: S.syncOnlyPaths,
        description: S.syncOnlyPathsDescription,
        initialValue: PathScope.render(include),
        placeholder: 'Work, Personal/Journal',
        onChange: (v) => include = PathScope.parse(v),
      );
      t.addText(
        name: S.dontSyncPaths,
        description: S.dontSyncPathsDescription,
        initialValue: PathScope.render(exclude),
        placeholder: 'Work/scratch',
        onChange: (v) => exclude = PathScope.parse(v),
      );
      t.addText(
        name: S.dontSyncExtensions,
        description: S.dontSyncDescription,
        initialValue: FileFilterPrefs.render(extensions),
        placeholder: 'pdf, zip, mp4',
        onChange: (v) => extensions = FileFilterPrefs.parse(v),
      );
      t.addButton(
        name: '',
        description: '',
        buttonText: S.save,
        onClick: commit,
      );
    }

    // The other half of the pair: settings that belong to the VAULT, so every
    // device sees the same value. Currently just the force-binary list, which
    // has to match across devices — the classification picks the conflict
    // resolver, and a per-device mismatch would make two peers resolve one
    // divergence differently and never converge. Server round-trip, hence its
    // own Save.
    void addSharedFiltersSection(PluginSettingsTab t) {
      var buffer = forcedBinaryExtensions();
      _addGroupHeading(t, S.sharedSettingsSection, S.sharedSettingsNote);
      t.addText(
        name: S.forceBinaryExtensions,
        description: S.forceBinaryDescription,
        initialValue: FileFilterPrefs.render(forcedBinaryExtensions()),
        placeholder: 'excalidraw, drawio',
        onChange: (v) => buffer = FileFilterPrefs.parse(v),
      );
      t.addButton(
        name: '',
        description: '',
        buttonText: S.save,
        onClick: () async {
          try {
            await onForcedBinaryChanged(buffer);
            showNotice(S.forceBinarySaved);
            tab.show();
          } catch (e) {
            showNotice(S.filtersSaveFailed(e));
          }
        },
      );
    }

    // "Signed in" here means a session EXISTS — not that its access token is
    // fresh right now. Access tokens live 15 minutes, so `isSignedIn` (which
    // also requires an unexpired one) is false on essentially every cold start
    // until the boot refresh lands, and this tab would greet a perfectly
    // signed-in user with a Sign in button. The refresh token is what decides
    // whether the account is still ours, and every call refreshes on demand
    // through `ensureValidToken`.
    final isSignedIn = currentAuthClient()?.session != null;
    final userEmail = currentAuthClient()?.email ?? '';

    // Answers to what this sync does differently — the questions people bring
    // from other plugins, which is where most "is it broken?" reports start.
    //
    // First row, above every section and outside every condition: someone who
    // is not signed in, or whose vault will not connect, is exactly who needs
    // it, and that is the state in which most of this tab is hidden.
    t.addButton(
      name: S.faqSettingName,
      description: S.faqSettingDescription,
      buttonText: S.faqButton,
      onClick: () async => openUrl('$authWebUrl/faq'),
    );

    addSelfHostSection(t);

    if (selfHostEnabled) {
      // Self-host: no account service. Vault comes from the sync registry.
      t.addSection(S.vaultSection);
      if (currentConfig.vaultId.isNotEmpty) {
        _addStorageUsage(t, vaultUsage, onShowOverview: onShowStorageOverview);
        addDisconnectVaultButton(t);
        addTroubleshootingSection(t);
      } else {
        addConnectVaultButton(t);
      }
    } else {
      t.addSection(S.authentication);
      if (isSignedIn) {
        addSignOutButton(t, userEmail);
        if (currentConfig.vaultId.isNotEmpty) {
          _addStorageUsage(t, vaultUsage, onShowOverview: onShowStorageOverview);
          addDisconnectVaultButton(t);
          addTroubleshootingSection(t);
        } else {
          addConnectVaultButton(t);
        }
        addSubscriptionSection(t, subscriptionEnd);
      } else {
        addBrowserSignInButton(t);
      }
    }

    if (currentConfig.vaultId.isNotEmpty && externalStorageAllowed) {
      _addExternalStorageSection(
        t,
        config: currentConfig,
        onSave: (updated) async {
          // Save server-side FIRST. If it fails (not signed in, vault
          // locked, RPC error), nothing local changes — the user keeps
          // the previous state instead of ending up with local-only
          // config that other devices will never adopt. Errors propagate
          // to the modal click handler in _addExternalStorageSection,
          // which surfaces them as a Notice.
          if (updated.externalBlobConfig != null) {
            await onSaveExternalBlobConfig(updated.externalBlobConfig!);
          }
          currentConfig = updated;
          await configStorage.save(updated);
          onConfigChanged(updated);
          // Re-render so the user sees the new "Connected: ..." summary
          // instead of the unchanged "Configure" buttons.
          tab.show();
        },
        onClear: () async {
          // Server clear FIRST. If it fails, we keep local config so
          // the user can retry instead of being stuck in a state where
          // local says "no external storage" but server still has the
          // old one (other devices would re-adopt it on next pull).
          await onClearExternalBlobConfig();
          // copyWith doesn't support nulling fields, rebuild manually.
          final cleared = VaultConfig(
            vaultId: currentConfig.vaultId,
            vaultName: currentConfig.vaultName,
            verificationToken: currentConfig.verificationToken,
            pullIntervalSeconds: currentConfig.pullIntervalSeconds,
            tokenProvider: currentConfig.tokenProvider,
            clientName: currentConfig.clientName,
          );
          currentConfig = cleared;
          await configStorage.save(cleared);
          onConfigChanged(cleared);
          tab.show();
        },
      );
    }

    // Sync filters, split by who they apply to — only meaningful once a vault
    // is connected. The split is the point: the two groups used to share one
    // "File types" heading, which put a device-local denylist and a
    // vault-global list side by side with nothing to tell them apart.
    if (currentConfig.vaultId.isNotEmpty) {
      addDeviceFiltersSection(t);
      addSharedFiltersSection(t);
    }

    // Settings sync (.obsidian) — placed below "File types" as a normal open
    // section.
    if (currentConfig.vaultId.isNotEmpty) {
      addSettingsSyncSection(
        t,
        prefs: settingsSyncPrefs(),
        onChanged: onSettingsSyncChanged,
        pluginCode: pluginCodeAvailability(),
        pluginCodeSize: pluginCodeSize(),
        onReset: () async {
          final confirmed = await _showActionConfirmation(
            plugin,
            title: S.reuploadSettingsTitle,
            body: S.reuploadSettingsBody,
            confirmText: S.reupload,
            destructive: true,
          );
          if (!confirmed) return;
          try {
            await onResetSettings();
            showNotice(S.settingsReuploadFinished);
          } catch (e) {
            showNotice(S.settingsReuploadFailed(e));
          }
        },
        onRestore: () async {
          final confirmed = await _showActionConfirmation(
            plugin,
            title: S.downloadSettingsTitle,
            body: S.downloadSettingsBody,
            confirmText: S.download,
            destructive: true,
          );
          if (!confirmed) return;
          try {
            await onRestoreSettings();
            showNotice(S.settingsDownloadFinished);
          } catch (e) {
            showNotice(S.settingsDownloadFailed(e));
          }
        },
      );
    }

    // Advanced diagnostics — always shown (useful even before sign-in / vault
    // connect, e.g. to capture a failing boot), last so it stays out of the way.
    addDiagnosticsSection(t);
  }

  Future<void> buildAsync(PluginSettingsTab t) async {
    final client = currentAuthClient();
    DateTime? fetched;
    // Self-host always allows BYO; on managed it's gated on the plan caps.
    var fetchedExternalAllowed = selfHostEnabled;
    int? fetchedMaxVaultCount;
    // Session present, not token-fresh — getSubscription refreshes on demand.
    if (client != null && client.session != null) {
      // One getSubscription call yields both the period end and the plan
      // capabilities.
      try {
        final sub = await client.getSubscription();
        onSubscriptionFetched(sub);
        fetched = (sub.isActive && sub.currentPeriodEnd != null)
            ? DateTime.fromMillisecondsSinceEpoch(
                sub.currentPeriodEnd! * 1000,
              ).toLocal()
            : null;
        fetchedExternalAllowed =
            sub.capabilities?.canUseExternalStorage ?? false;
        fetchedMaxVaultCount = sub.capabilities?.maxVaultCount;
      } catch (_) {
        fetched = null;
        fetchedExternalAllowed = false;
        fetchedMaxVaultCount = null;
      }
    }

    // Fetch vault usage if connected.
    ({int usedBytes, int quotaBytes})? fetchedUsage;
    if (currentConfig.vaultId.isNotEmpty) {
      fetchedUsage = await onFetchUsage();
    }

    final needsRefresh =
        fetched != subscriptionEnd ||
        fetchedUsage != vaultUsage ||
        fetchedExternalAllowed != externalStorageAllowed;
    subscriptionEnd = fetched;
    vaultUsage = fetchedUsage;
    externalStorageAllowed = fetchedExternalAllowed;
    maxVaultCount = fetchedMaxVaultCount;
    if (needsRefresh) {
      tab.show();
    }
  }

  tab = PluginSettingsTab(
    plugin,
    name: 'Rhyolite Sync',
    onDisplay: build,
    onDisplayAsync: buildAsync,
  );
  build(tab); // initial sync build
  plugin.addSettingTab(tab.handle.raw);

  // Managed edition only: self-host has no account service, so browser-auth
  // and the code fallback don't apply. Registered once here (registerSettingsTab
  // runs once per plugin load); Obsidian clears both on unload.
  if (!selfHostEnabled) {
    // Web login redirects the browser to obsidian://rhyolite-auth?code=...&state=...
    // which Obsidian dispatches here. Validate the state we minted, redeem the
    // one-time code for a session, and sign in.
    jsu.callMethod<void>(plugin.raw, 'registerObsidianProtocolHandler', [
      'rhyolite-auth',
      jsu.allowInterop((params) {
        final code = (jsu.getProperty<String?>(params, 'code') ?? '').trim();
        final state = jsu.getProperty<String?>(params, 'state') ?? '';
        if (code.isEmpty) {
          return;
        }
        if (pendingAuthState == null || state != pendingAuthState) {
          showNotice(S.signInLinkWrongDevice);
          return;
        }
        pendingAuthState = null;
        () async {
          try {
            await accountClient.redeemLoginCode(code);
            await applySignedIn();
            showNotice(S.signedIn);
          } catch (e) {
            showNotice(S.signInFailed(e));
          }
        }();
      }),
    ]);
  }

  return (refresh: tab.show, beginSignIn: beginBrowserAuth);
}

/// A section heading plus a muted note under it.
///
/// [PluginSettingsTab.addSection] renders the heading alone, and for the
/// device-vs-vault split the note IS the point: whether a setting stays on
/// this install or reaches every device is not something the reader should
/// have to infer from a paragraph three rows down.
void _addGroupHeading(PluginSettingsTab t, String title, String note) {
  t.addSection(title);
  final el = jsu.callMethod<Object>(t.containerEl, 'createEl', ['div']);
  jsu.setProperty(el, 'className', 'rhyolite-group-note');
  jsu.setProperty(el, 'textContent', note);
}

// ---------------------------------------------------------------------------
// External storage settings
// ---------------------------------------------------------------------------

void _addExternalStorageSection(
  PluginSettingsTab t, {
  required VaultConfig config,
  required Future<void> Function(VaultConfig updated) onSave,
  required Future<void> Function() onClear,
}) {
  t.addSection(S.externalStorageSection);

  // Decided by the NON-SECRET marker, not by the secret. The credentials are
  // never written to data.json — they live only in the E2EE config on the
  // server and are fetched into memory during start() — so a config loaded
  // from disk has `externalBlobConfig == null` ALWAYS, and asking it made a
  // configured vault look unconfigured on every launch.
  final kind = config.externalStorageKind;
  final current = config.externalBlobConfig;

  if (kind != null) {
    // The endpoint comes from the secret when it is loaded; before that only
    // the backend name is known, which is still the thing the user asked
    // about ("did my WebDAV setting survive?").
    final summary = switch (current) {
      S3BlobConfig(:final endpoint, :final bucket) => 'S3: $endpoint/$bucket',
      WebDavBlobConfig(:final endpoint) => 'WebDAV: $endpoint',
      _ => switch (kind) {
          's3' => 'S3',
          'webdav' => 'WebDAV',
          _ => 'Custom',
        },
    };
    t.addCustom((s) {
      s.setName(S.connected);
      s.setDesc(summary);
    });
    t.addButton(
      name: S.disconnectStorage,
      description: S.disconnectStorageDescription,
      buttonText: S.disconnect,
      onClick: () async {
        try {
          await onClear();
          showNotice(S.externalStorageDisconnected);
        } catch (e) {
          showNotice(S.couldNotDisconnectStorage(e));
        }
      },
    );
    return;
  }

  // No external storage — show setup buttons.
  t.addCustom((s) {
    s.setName(S.bringYourOwnStorage);
    s.setDesc(S.bringYourOwnDescription);
  });

  t.addButton(
    name: S.s3Compatible,
    description: S.s3Description,
    buttonText: S.configure,
    onClick: () async {
      final result = await _showS3ConfigModal(t.plugin);
      if (result == null) return;
      try {
        await onSave(config.copyWith(
          externalBlobConfig: result,
          externalStorageKind: result.kind,
        ));
        showNotice(S.externalStorageConnected('S3'));
      } catch (e) {
        showNotice(S.couldNotSaveStorage(e));
      }
    },
  );

  t.addButton(
    name: S.webdavName,
    description: S.webdavDescription,
    buttonText: S.configure,
    onClick: () async {
      final result = await _showWebDavConfigModal(t.plugin);
      if (result == null) return;
      try {
        await onSave(config.copyWith(
          externalBlobConfig: result,
          externalStorageKind: result.kind,
        ));
        showNotice(S.externalStorageConnected('WebDAV'));
      } catch (e) {
        showNotice(S.couldNotSaveStorage(e));
      }
    },
  );
}

InputRef _labeledInput(
  ModalContext ctx, {
  required String label,
  String placeholder = '',
  String type = 'text',
}) {
  ctx.spaceVertical(px: 8);
  ctx.createEl('div', text: label, cls: 'setting-item-name');
  final input = ctx.input(type: type, placeholder: placeholder);
  return input;
}

Future<S3BlobConfig?> _showS3ConfigModal(PluginHandle plugin) async {
  return showModalWith<S3BlobConfig>(
    plugin,
    build: (ctx) {
      ctx.h3(S.s3ConfigTitle);

      final endpointInput = _labeledInput(
        ctx,
        label: S.endpoint,
        placeholder: 's3.amazonaws.com',
      );
      final bucketInput = _labeledInput(
        ctx,
        label: S.bucket,
        placeholder: 'my-vault-backup',
      );
      final accessKeyInput = _labeledInput(
        ctx,
        label: S.accessKey,
        placeholder: 'AKIA...',
      );
      final secretKeyInput = _labeledInput(
        ctx,
        label: S.secretKey,
        type: 'password',
      );
      final regionInput = _labeledInput(
        ctx,
        label: S.region,
        placeholder: 'us-east-1',
      );

      ctx.spaceVertical(px: 16);
      ctx.buttonRow([
        ButtonSpec(S.save, () {
          final endpoint = ctx.valueOf(endpointInput).trim();
          final bucket = ctx.valueOf(bucketInput).trim();
          final accessKey = ctx.valueOf(accessKeyInput).trim();
          final secretKey = ctx.valueOf(secretKeyInput).trim();
          final region = ctx.valueOf(regionInput).trim();
          if (endpoint.isEmpty ||
              bucket.isEmpty ||
              accessKey.isEmpty ||
              secretKey.isEmpty)
            return;
          ctx.close(
            S3BlobConfig(
              endpoint: endpoint,
              bucket: bucket,
              accessKey: accessKey,
              secretKey: secretKey,
              region: region.isEmpty ? 'us-east-1' : region,
            ),
          );
        }, variant: ButtonVariant.primary),
        ButtonSpec(S.cancel, () => ctx.close(null)),
      ]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

Future<WebDavBlobConfig?> _showWebDavConfigModal(PluginHandle plugin) async {
  return showModalWith<WebDavBlobConfig>(
    plugin,
    build: (ctx) {
      ctx.h3(S.webdavConfigTitle);

      final endpointInput = _labeledInput(
        ctx,
        label: S.endpoint,
        placeholder: 'dav.example.com/remote.php/dav/files/user',
      );
      final usernameInput = _labeledInput(ctx, label: S.username);
      final passwordInput = _labeledInput(
        ctx,
        label: S.password,
        type: 'password',
      );

      ctx.spaceVertical(px: 16);
      ctx.buttonRow([
        ButtonSpec(S.save, () {
          final endpoint = ctx.valueOf(endpointInput).trim();
          final username = ctx.valueOf(usernameInput).trim();
          final password = ctx.valueOf(passwordInput).trim();
          if (endpoint.isEmpty || username.isEmpty || password.isEmpty) return;
          ctx.close(
            WebDavBlobConfig(
              endpoint: endpoint,
              username: username,
              password: password,
            ),
          );
        }, variant: ButtonVariant.primary),
        ButtonSpec(S.cancel, () => ctx.close(null)),
      ]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

/// Generic confirmation dialog for troubleshooting actions.
Future<bool> _showActionConfirmation(
  PluginHandle plugin, {
  required String title,
  required String body,
  required String confirmText,
  required bool destructive,
}) async {
  final confirmed = await showModalWith<bool>(
    plugin,
    build: (ctx) {
      ctx.h3(title);
      ctx.spaceVertical(px: 12);
      ctx.createEl('p', cls: 'rhyolite-setting-desc', text: body);
      ctx.spaceVertical(px: 16);
      ctx.buttonRow([
        ButtonSpec(
          confirmText,
          () => ctx.close(true),
          variant: destructive
              ? ButtonVariant.destructive
              : ButtonVariant.primary,
        ),
        ButtonSpec(S.cancel, () => ctx.close(false)),
      ]);
      ctx.onEscape(() => ctx.close(false));
    },
  );
  return confirmed ?? false;
}

/// Asks the user to confirm disconnecting from the current vault.
Future<bool> _showDisconnectConfirmation(
  PluginHandle plugin, {
  required String vaultName,
}) async {
  final confirmed = await showModalWith<bool>(
    plugin,
    build: (ctx) {
      ctx.h3(S.disconnectVaultTitle);
      ctx.spaceVertical(px: 12);
      ctx.createEl('p', text: S.disconnectFromVault(vaultName));
      ctx.spaceVertical(px: 8);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: S.disconnectVaultBody,
      );
      ctx.spaceVertical(px: 16);
      ctx.buttonRow([
        ButtonSpec(
          S.disconnect,
          () => ctx.close(true),
          variant: ButtonVariant.destructive,
        ),
        ButtonSpec(S.cancel, () => ctx.close(false)),
      ]);
      ctx.onEscape(() => ctx.close(false));
    },
  );
  return confirmed ?? false;
}

/// The storage row: managed usage when there is a quota to report, and the way
/// into the overview.
///
/// Rendered even with no [usage] — self-host and bring-your-own have no managed
/// quota, but the overview is just as useful there, and burying the only
/// entrance to it behind a figure those users never see meant they had none.
void _addStorageUsage(
  PluginSettingsTab t,
  ({int usedBytes, int quotaBytes})? usage, {
  required Future<void> Function() onShowOverview,
}) {
  final String label;
  if (usage != null && usage.quotaBytes > 0) {
    final usedMiB = usage.usedBytes / (1024 * 1024);
    final quotaMiB = usage.quotaBytes / (1024 * 1024);
    final percent = (usage.usedBytes / usage.quotaBytes * 100).clamp(0, 100);
    label = '${usedMiB.toStringAsFixed(1)} / ${quotaMiB.toStringAsFixed(0)} MiB '
        '(${percent.toStringAsFixed(0)}%)';
  } else {
    label = S.storageOverviewRowDesc;
  }

  t.addButton(
    name: S.storageSection,
    description: label,
    buttonText: S.storageOverviewAction,
    onClick: () => unawaited(onShowOverview()),
  );
}

/// Shows a modal that immediately starts checking for a restored subscription.
/// Displays a spinner while checking, then shows the result with an OK button.
Future<void> _showRestoreSubscriptionModal(
  PluginHandle plugin, {
  required Future<bool> Function() onRestore,
  required void Function() onSubscribed,
}) async {
  await showModalWith<void>(
    plugin,
    build: (ctx) {
      final title = ctx.h3(S.checkingSubscription);
      ctx.spaceVertical(px: 12);
      final spin = ctx.spinner(label: S.contactingServer);
      spin.show();
      ctx.spaceVertical(px: 4);
      final message = ctx.createEl('p', cls: 'rhyolite-setting-desc');
      ctx.spaceVertical(px: 16);
      final buttons = ctx.buttonRow([ButtonSpec(S.ok, () => ctx.close(null))]);
      buttons.first.setDisabled(value: true);

      Future(() async {
        bool restored;
        try {
          restored = await onRestore();
        } catch (_) {
          restored = false;
        }
        spin.hide();
        if (restored) {
          setText(title, S.subscriptionActivated);
          setText(message, S.subscriptionRestored);
          onSubscribed();
        } else {
          setText(title, S.noSubscriptionFound);
          setText(message, S.noPaymentFound);
        }
        buttons.first.setDisabled(value: false);
      });
    },
  );
}
