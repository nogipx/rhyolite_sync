import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_client_obsidian/src/engine/vault_picker_modal.dart';
import 'package:rhyolite_client_obsidian/src/vault/managed_vault_directory.dart';
import 'package:rhyolite_client_obsidian/src/vault/vault_directory.dart';

import 'db_recovery.dart';
import 'self_host_modal.dart';

import '../settings/settings_sync_prefs.dart';
import '../settings/settings_sync_settings_ui.dart';
import 'modal_lock.dart';
import 'obsidian_config_storage.dart';
import 'payment_modal.dart';
import 'sign_in_modal.dart';
import 'sign_up_modal.dart';

/// Registers the settings tab. The tab rebuilds its UI on every open so that
/// auth and vault state are always up to date.
///
/// Returns a [refresh] function — call it to immediately re-render the tab
/// (e.g. right after sign-in/sign-out without waiting for the user to reopen).
void Function() registerSettingsTab({
  required PluginHandle plugin,
  required ObsidianConfigStorage configStorage,
  required VaultConfig config,
  required AuthConfig authConfig,
  required RpcAccountClient? authClient,
  required RpcAccountClient accountClient,
  required Future<({int usedBytes, int quotaBytes})?> Function() onFetchUsage,
  required void Function(String url) openUrl,
  required void Function(VaultConfig updated) onConfigChanged,
  required void Function(AuthConfig updated, RpcAccountClient client)
  onAuthChanged,
  required void Function() onSignOut,
  required void Function() onDisconnectVault,
  required void Function(VaultConfig config, VaultCipher cipher) onVaultChanged,
  required void Function() onSubscribed,
  required Future<void> Function() onResetVault,
  required Future<void> Function() onRestoreFromServer,
  required Future<void> Function() onRepairVault,
  required Future<void> Function(ExternalBlobConfig config)
  onSaveExternalBlobConfig,
  required Future<void> Function() onClearExternalBlobConfig,
  required SettingsSyncPrefs Function() settingsSyncPrefs,
  required Future<void> Function(SettingsSyncPrefs next) onSettingsSyncChanged,
  required Future<void> Function() onResetSettings,
  required Future<void> Function() onRestoreSettings,
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
  var currentAuthClient = authClient;
  DateTime? subscriptionEnd; // cached per tab open, refreshed on display
  ({int usedBytes, int quotaBytes})? vaultUsage;
  // External (BYO) storage: always available on self-host (own server — lean
  // VPS + cheap external blobs is a real win). On managed it's a Pro-tier
  // feature: hidden for free (no capability), set from plan caps on display.
  var externalStorageAllowed = selfHostEnabled;
  // Open/closed state of the collapsed settings-sync block; survives the tab
  // rebuilds that every toggle triggers.
  var settingsSyncExpanded = false;

  late PluginSettingsTab tab;

  void build(PluginSettingsTab t) {
    void addSignOutButton(PluginSettingsTab t, String userEmail) => t.addButton(
      name: 'Auth status',
      description: 'Signed in as $userEmail. Click to sign out.',
      buttonText: 'Sign Out',
      onClick: () async {
        await currentAuthClient?.signOut();
        await configStorage.clearAuthSession();
        await configStorage.disconnectVault();
        currentAuthClient = null;
        currentConfig = const VaultConfig(vaultId: '', vaultName: '');
        onSignOut();
        tab.show();
      },
    );

    void addDisconnectVaultButton(PluginSettingsTab t) => t.addButton(
      name: 'Disconnect vault',
      description:
          'Stop sync and forget this vault on this device. '
          'Vault data on the server is not affected.',
      buttonText: 'Disconnect',
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
      t.addSection('Troubleshooting');

      t.addButton(
        name: 'Re-upload from this device',
        description:
            'Use this device as the source of truth. '
            'Server history will be replaced with files from this device. '
            'Other devices will download the updated files automatically.',
        buttonText: 'Re-upload',
        onClick: () async {
          final confirmed = await _showActionConfirmation(
            plugin,
            title: 'Re-upload from this device?',
            body:
                'Server history will be replaced with files from this device. '
                'Other devices will re-sync automatically. '
                'No files are deleted.',
            confirmText: 'Re-upload',
            destructive: true,
          );
          if (!confirmed) return;
          await onResetVault();
        },
      );

      t.addButton(
        name: 'Download from server',
        description:
            'Replace local files with the server version. '
            'Use this if your files on this device are outdated or corrupted.',
        buttonText: 'Download',
        onClick: () async {
          final confirmed = await _showActionConfirmation(
            plugin,
            title: 'Download from server?',
            body:
                'Local files will be deleted and replaced with the server version. '
                'This only affects this device.',
            confirmText: 'Download',
            destructive: true,
          );
          if (!confirmed) return;
          await onRestoreFromServer();
        },
      );

      t.addButton(
        name: 'Repair vault sync state',
        description:
            'Rebuild sync state for every note from its current disk '
            'content and re-upload so the server adopts the fresh '
            'state. Use this if notes look corrupted, duplicated, or '
            'sync seems stuck. Your file content on disk is not '
            'modified.',
        buttonText: 'Repair',
        onClick: () async {
          final confirmed = await _showActionConfirmation(
            plugin,
            title: 'Repair vault sync state?',
            body:
                'Every note will be re-seeded from its current disk '
                'content and re-uploaded. This can take a while for '
                'large vaults. File content on disk is not changed.',
            confirmText: 'Repair',
            destructive: false,
          );
          if (!confirmed) return;
          try {
            await onRepairVault();
            showNotice('Vault repair finished — see logs for details.');
          } catch (e) {
            showNotice('Vault repair failed: $e');
          }
        },
      );
    }

    void addConnectVaultButton(PluginSettingsTab t) => t.addButton(
      name: 'Vault',
      description: 'Connect to an existing vault or create a new one.',
      buttonText: 'Connect Vault',
      onClick: () async {
        final IVaultDirectory? dir;
        if (selfHostEnabled) {
          dir = selfHostDirectory;
        } else {
          final client = currentAuthClient;
          dir = (client != null && client.isSignedIn)
              ? ManagedVaultDirectory(client)
              : null;
        }
        if (dir == null) return;
        if (currentConfig.vaultId.isNotEmpty) return;

        final result = await withModalLock(
          () => showVaultPickerModal(plugin, dir!, configStorage),
        );
        if (result != null) {
          currentConfig = result.$1;
          onVaultChanged(result.$1, result.$2);
          tab.show();
        }
      },
    );

    void addSelfHostSection(PluginSettingsTab t) {
      t.addSection('Self-host');
      t.addButton(
        name: selfHostEnabled ? 'Self-host enabled' : 'Self-host',
        description: selfHostEnabled
            ? 'Server: $selfHostUrl'
            : 'Sync with your own server instead of the managed service.',
        buttonText: selfHostEnabled ? 'Reconfigure' : 'Enable self-host',
        onClick: () async {
          final changed = await withModalLock(
            () => showSelfHostModal(plugin, configStorage),
          );
          if (changed) {
            // Apply immediately by re-running the plugin's onLoad (disable +
            // re-enable) — no manual reload, no account interaction.
            showNotice('Applying self-host settings…');
            reloadPlugin(plugin);
          }
        },
      );
    }

    void addSignInButton(PluginSettingsTab t) => t.addButton(
      name: 'Sign in',
      description: 'Sign in to Supabase to enable authenticated sync.',
      buttonText: 'Sign In',
      primary: true,
      onClick: () async {
        if (!currentAuthConfig.isConfigured) return;
        final client = await withModalLock(
          () => showSignInModal(plugin, client: accountClient),
        );
        if (client == null) return;
        final session = client.session;
        if (session != null) {
          await configStorage.saveAuthSession(session);
        }
        currentAuthClient = client;
        onAuthChanged(currentAuthConfig, client);
        tab.show();
      },
    );

    void addSignUpButton(PluginSettingsTab t) => t.addButton(
      name: 'Create account',
      description: 'New to Rhyolite Sync? Create a free account.',
      buttonText: 'Create Account',
      onClick: () async {
        if (!currentAuthConfig.isConfigured) return;
        final result = await withModalLock(
          () => showSignUpModal(plugin, client: accountClient),
        );
        if (result == null) return;
        if (result.emailConfirmationRequired) {
          await showModalWith<void>(
            plugin,
            build: (ctx) {
              ctx.h3('Check your email');
              ctx.spaceVertical(px: 12);
              ctx.createEl(
                'p',
                text:
                    'A confirmation link has been sent to your email address. '
                    'Please confirm it and then sign in.',
              );
              ctx.spaceVertical(px: 16);
              ctx.buttonRow([ButtonSpec('OK', () => ctx.close(null))]);
            },
          );
          return;
        }
        final client = result.client!;
        final session = client.session;
        if (session != null) {
          await configStorage.saveAuthSession(session);
        }
        currentAuthClient = client;
        onAuthChanged(currentAuthConfig, client);
        tab.show();
      },
    );

    void addSubscriptionSection(PluginSettingsTab t, DateTime? periodEnd) {
      t.addSection('Subscription');
      if (periodEnd != null) {
        final day = periodEnd.day.toString().padLeft(2, '0');
        final month = periodEnd.month.toString().padLeft(2, '0');
        final year = periodEnd.year;
        t.addCustom((s) {
          s.setName('Active until $day.$month.$year');
          s.setDesc('Your subscription is active.');
        });
      } else {
        t.addButton(
          name: 'Subscribe',
          description: 'Sync across all your devices.',
          buttonText: 'Subscribe',
          onClick: () async {
            final client = currentAuthClient;
            if (client == null) return;
            final paid = await showPaymentModal(
              plugin,
              authClient: client,
              openUrl: openUrl,
            );
            if (paid) {
              onSubscribed();
            }
          },
        );
        t.addButton(
          name: 'Already paid?',
          description: 'Check if your payment went through.',
          buttonText: 'Restore subscription',
          onClick: () async {
            final client = currentAuthClient;
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

    final isSignedIn = currentAuthClient?.isSignedIn ?? false;
    final userEmail = currentAuthClient?.email ?? '';

    addSelfHostSection(t);

    if (selfHostEnabled) {
      // Self-host: no account service. Vault comes from the sync registry.
      t.addSection('Vault');
      if (currentConfig.vaultId.isNotEmpty) {
        if (vaultUsage != null) {
          _addStorageUsage(t, vaultUsage!);
        }
        addDisconnectVaultButton(t);
        addTroubleshootingSection(t);
      } else {
        addConnectVaultButton(t);
      }
    } else {
      t.addSection('Authentication');
      if (isSignedIn) {
        addSignOutButton(t, userEmail);
        if (currentConfig.vaultId.isNotEmpty) {
          if (vaultUsage != null) {
            _addStorageUsage(t, vaultUsage!);
          }
          addDisconnectVaultButton(t);
          addTroubleshootingSection(t);
        } else {
          addConnectVaultButton(t);
        }
        addSubscriptionSection(t, subscriptionEnd);
      } else {
        addSignInButton(t);
        addSignUpButton(t);
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

    // Settings sync (.obsidian) — last, collapsed: it's advanced and rarely
    // touched, so it stays out of the way at the bottom of the tab.
    if (currentConfig.vaultId.isNotEmpty) {
      addSettingsSyncSection(
        t,
        prefs: settingsSyncPrefs(),
        onChanged: onSettingsSyncChanged,
        expanded: settingsSyncExpanded,
        onExpandedChanged: (v) => settingsSyncExpanded = v,
        onReset: () async {
          final confirmed = await _showActionConfirmation(
            plugin,
            title: 'Re-upload settings from this device?',
            body:
                "Server settings will be replaced with this device's "
                '.obsidian settings. Other devices re-sync automatically.',
            confirmText: 'Re-upload',
            destructive: true,
          );
          if (!confirmed) return;
          try {
            await onResetSettings();
            showNotice('Settings re-upload finished.');
          } catch (e) {
            showNotice('Settings re-upload failed: $e');
          }
        },
        onRestore: () async {
          final confirmed = await _showActionConfirmation(
            plugin,
            title: 'Download settings from server?',
            body:
                "This device's .obsidian settings will be replaced with the "
                'server version. Most changes apply after an Obsidian restart.',
            confirmText: 'Download',
            destructive: true,
          );
          if (!confirmed) return;
          try {
            await onRestoreSettings();
            showNotice('Settings download finished — restart Obsidian to apply.');
          } catch (e) {
            showNotice('Settings download failed: $e');
          }
        },
      );
    }
  }

  Future<void> buildAsync(PluginSettingsTab t) async {
    final client = currentAuthClient;
    DateTime? fetched;
    // Self-host always allows BYO; on managed it's gated on the plan caps.
    var fetchedExternalAllowed = selfHostEnabled;
    if (client != null && client.isSignedIn) {
      // One getSubscription call yields both the period end and the plan
      // capabilities.
      try {
        final sub = await client.getSubscription();
        fetched = (sub.isActive && sub.currentPeriodEnd != null)
            ? DateTime.fromMillisecondsSinceEpoch(
                sub.currentPeriodEnd! * 1000,
              ).toLocal()
            : null;
        fetchedExternalAllowed = sub.capabilities?.canUseExternalStorage ?? false;
      } catch (_) {
        fetched = null;
        fetchedExternalAllowed = false;
      }
    }

    // Fetch vault usage if connected.
    ({int usedBytes, int quotaBytes})? fetchedUsage;
    if (currentConfig.vaultId.isNotEmpty) {
      fetchedUsage = await onFetchUsage();
    }

    final needsRefresh = fetched != subscriptionEnd ||
        fetchedUsage != vaultUsage ||
        fetchedExternalAllowed != externalStorageAllowed;
    subscriptionEnd = fetched;
    vaultUsage = fetchedUsage;
    externalStorageAllowed = fetchedExternalAllowed;
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

  return tab.show; // caller can trigger a refresh
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
  t.addSection('External Storage');

  final current = config.externalBlobConfig;

  if (current != null) {
    // Show current config summary + disconnect button.
    final summary = switch (current) {
      S3BlobConfig(:final endpoint, :final bucket) => 'S3: $endpoint/$bucket',
      WebDavBlobConfig(:final endpoint) => 'WebDAV: $endpoint',
      _ => 'Custom',
    };
    t.addCustom((s) {
      s.setName('Connected');
      s.setDesc(summary);
    });
    t.addButton(
      name: 'Disconnect storage',
      description:
          'Stop using external storage. New blobs will go through the sync server.',
      buttonText: 'Disconnect',
      onClick: () async {
        try {
          await onClear();
          showNotice('External storage disconnected.');
        } catch (e) {
          showNotice('Could not disconnect external storage: $e');
        }
      },
    );
    return;
  }

  // No external storage — show setup buttons.
  t.addCustom((s) {
    s.setName('Bring your own storage');
    s.setDesc(
      'Store file content in your own S3 or WebDAV server. '
      'The sync server will only handle lightweight metadata.',
    );
  });

  t.addButton(
    name: 'S3-compatible',
    description: 'AWS S3, MinIO, Cloudflare R2, Backblaze B2',
    buttonText: 'Configure',
    onClick: () async {
      final result = await _showS3ConfigModal(t.plugin);
      if (result == null) return;
      try {
        await onSave(config.copyWith(externalBlobConfig: result));
        showNotice('External storage connected: S3');
      } catch (e) {
        showNotice('Could not save external storage: $e');
      }
    },
  );

  t.addButton(
    name: 'WebDAV',
    description: 'Nextcloud, ownCloud, or any WebDAV server',
    buttonText: 'Configure',
    onClick: () async {
      final result = await _showWebDavConfigModal(t.plugin);
      if (result == null) return;
      try {
        await onSave(config.copyWith(externalBlobConfig: result));
        showNotice('External storage connected: WebDAV');
      } catch (e) {
        showNotice('Could not save external storage: $e');
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
      ctx.h3('S3 Storage Configuration');

      final endpointInput = _labeledInput(
        ctx,
        label: 'Endpoint',
        placeholder: 's3.amazonaws.com',
      );
      final bucketInput = _labeledInput(
        ctx,
        label: 'Bucket',
        placeholder: 'my-vault-backup',
      );
      final accessKeyInput = _labeledInput(
        ctx,
        label: 'Access Key',
        placeholder: 'AKIA...',
      );
      final secretKeyInput = _labeledInput(
        ctx,
        label: 'Secret Key',
        type: 'password',
      );
      final regionInput = _labeledInput(
        ctx,
        label: 'Region',
        placeholder: 'us-east-1',
      );

      ctx.spaceVertical(px: 16);
      ctx.buttonRow([
        ButtonSpec('Save', () {
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
        ButtonSpec('Cancel', () => ctx.close(null)),
      ]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

Future<WebDavBlobConfig?> _showWebDavConfigModal(PluginHandle plugin) async {
  return showModalWith<WebDavBlobConfig>(
    plugin,
    build: (ctx) {
      ctx.h3('WebDAV Storage Configuration');

      final endpointInput = _labeledInput(
        ctx,
        label: 'Endpoint',
        placeholder: 'dav.example.com/remote.php/dav/files/user',
      );
      final usernameInput = _labeledInput(ctx, label: 'Username');
      final passwordInput = _labeledInput(
        ctx,
        label: 'Password',
        type: 'password',
      );

      ctx.spaceVertical(px: 16);
      ctx.buttonRow([
        ButtonSpec('Save', () {
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
        ButtonSpec('Cancel', () => ctx.close(null)),
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
        ButtonSpec('Cancel', () => ctx.close(false)),
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
      ctx.h3('Disconnect Vault?');
      ctx.spaceVertical(px: 12);
      ctx.createEl('p', text: 'Disconnect from "$vaultName" on this device?');
      ctx.spaceVertical(px: 8);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text:
            'Sync will stop. The vault config and remembered passphrase '
            'will be removed from this device. '
            'Your data on the server and files on disk are not affected.',
      );
      ctx.spaceVertical(px: 16);
      ctx.buttonRow([
        ButtonSpec(
          'Disconnect',
          () => ctx.close(true),
          variant: ButtonVariant.destructive,
        ),
        ButtonSpec('Cancel', () => ctx.close(false)),
      ]);
      ctx.onEscape(() => ctx.close(false));
    },
  );
  return confirmed ?? false;
}

void _addStorageUsage(
  PluginSettingsTab t,
  ({int usedBytes, int quotaBytes}) usage,
) {
  final usedMiB = usage.usedBytes / (1024 * 1024);
  final quotaMiB = usage.quotaBytes / (1024 * 1024);
  final percent = usage.quotaBytes > 0
      ? (usage.usedBytes / usage.quotaBytes * 100).clamp(0, 100)
      : 0.0;
  final label =
      '${usedMiB.toStringAsFixed(1)} / ${quotaMiB.toStringAsFixed(0)} MiB '
      '(${percent.toStringAsFixed(0)}%)';

  t.addCustom((s) {
    s.setName('Storage');
    s.setDesc(label);
  });
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
      final title = ctx.h3('Checking subscription...');
      ctx.spaceVertical(px: 12);
      final spin = ctx.spinner(label: 'Contacting server');
      spin.show();
      ctx.spaceVertical(px: 4);
      final message = ctx.createEl('p', cls: 'rhyolite-setting-desc');
      ctx.spaceVertical(px: 16);
      final buttons = ctx.buttonRow([ButtonSpec('OK', () => ctx.close(null))]);
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
          setText(title, 'Subscription activated!');
          setText(message, 'Your subscription has been successfully restored.');
          onSubscribed();
        } else {
          setText(title, 'No subscription found');
          setText(
            message,
            'No completed payment was found for your account. '
            'If you just paid, please wait a moment and try again.',
          );
        }
        buttons.first.setDisabled(value: false);
      });
    },
  );
}
