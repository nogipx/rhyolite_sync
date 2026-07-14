import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import '../vault/vault_directory.dart';
import 'obsidian_config_storage.dart';
import 'passphrase_modal.dart';
import 'setup_modal.dart';

/// Shows vault picker: list existing vaults, connect to one, or create new.
///
/// Works against any [IVaultDirectory] — the managed account service or the
/// self-host sync registry — so the picker is edition-agnostic.
///
/// Vaults are loaded before the modal is shown so the build function stays
/// synchronous (ModalContext has no dynamic DOM insertion API).
///
/// Returns [(VaultConfig, VaultCipher)] on success, null if cancelled.
Future<(VaultConfig, VaultCipher)?> showVaultPickerModal(
  PluginHandle plugin,
  IVaultDirectory directory,
  ObsidianConfigStorage configStorage, {
  Future<void> Function(VaultInfo vault)? onDeleteVault,
  // Owned-vault cap from the plan (`PlanCapabilities.maxVaultCount`). null =
  // no managed-side cap (self-host / unknown) → creation always offered. When
  // the count is reached the "+ Create" row is hidden (the account server is
  // the real gate; this is a UX hint that avoids a doomed create attempt).
  int? maxVaultCount,
}) async {
  // Load vaults before showing the modal. Hide tombstones (permanently deleted
  // on another device) — listVaults returns them so connected devices can drop
  // the vault locally, but the picker only offers live vaults.
  List<VaultInfo> vaults;
  try {
    vaults = (await directory.listVaults())
        .where((v) => !v.isDeleted)
        .toList();
  } catch (e) {
    vaults = [];
  }

  return _showPickerModal(
    plugin,
    directory,
    configStorage,
    vaults: vaults,
    onDeleteVault: onDeleteVault,
    maxVaultCount: maxVaultCount,
  );
}

Future<(VaultConfig, VaultCipher)?> _showPickerModal(
  PluginHandle plugin,
  IVaultDirectory directory,
  ObsidianConfigStorage configStorage, {
  required List<VaultInfo> vaults,
  Future<void> Function(VaultInfo vault)? onDeleteVault,
  int? maxVaultCount,
}) {
  final atCapacity =
      maxVaultCount != null && vaults.length >= maxVaultCount;
  return showModalWith<(VaultConfig, VaultCipher)?>(
    plugin,
    build: (ctx) {
      ctx.h3('Select Vault');
      ctx.spaceVertical(px: 8);

      if (vaults.isEmpty) {
        ctx.createEl('p', cls: 'rhyolite-setting-desc', text: 'No vaults found. Create one below.');
      } else {
        for (final vault in vaults) {
          final label = vault.vaultName.isNotEmpty
              ? vault.vaultName
              : vault.vaultId;
          ctx.createEl('span', cls: 'rhyolite-vault-label', text: label);
          ctx.spaceVertical(px: 4);
          ctx.buttonRow([
            ButtonSpec('Connect', () async {
              final result = await _connectToVault(
                plugin,
                directory,
                configStorage,
                vault: vault,
              );
              if (result != null) ctx.close(result);
            }, variant: ButtonVariant.primary),
            if (onDeleteVault != null)
              ButtonSpec('Delete', () async {
                final confirmed = await _confirmDeleteVault(plugin, vault);
                if (!confirmed) return;
                try {
                  await onDeleteVault(vault);
                  showNotice('Vault "$label" deleted.');
                  ctx.close(null);
                } catch (e) {
                  ctx.showError('Delete failed: $e');
                }
              }),
          ]);
          ctx.spaceVertical(px: 8);
        }
      }

      ctx.spaceVertical(px: 4);
      ctx.createEl('hr');
      ctx.spaceVertical(px: 8);

      if (atCapacity) {
        // Plan vault limit reached — creating another would be rejected by the
        // account server, so offer no create form, just explain why.
        ctx.createEl(
          'p',
          cls: 'rhyolite-setting-desc',
          text: maxVaultCount == 1
              ? 'Your plan includes a single vault. Upgrade to add more.'
              : 'You have reached your plan\'s vault limit ($maxVaultCount). '
                    'Upgrade to add more.',
        );
        ctx.spaceVertical(px: 8);
        ctx.buttonRow([
          ButtonSpec('Cancel', () => ctx.close(null)),
        ]);
        ctx.onEscape(() => ctx.close(null));
        return;
      }

      ctx.createEl('p', cls: 'rhyolite-setting-desc', text: 'Create a new vault:');
      ctx.spaceVertical(px: 4);

      final nameInput = ctx.input(placeholder: 'Vault name')..focus();
      ctx.spaceVertical(px: 8);

      ctx.buttonRow([
        ButtonSpec('+ Create', () async {
          final name = ctx.valueOf(nameInput).trim();
          if (name.isEmpty) {
            ctx.showError('Vault name cannot be empty.');
            return;
          }
          final result = await _createNewVault(
            plugin,
            directory,
            configStorage,
            vaultName: name,
          );
          if (result != null) ctx.close(result);
        }, variant: ButtonVariant.primary),
        ButtonSpec('Cancel', () => ctx.close(null)),
      ]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

/// Type-the-name confirmation for the irreversible vault delete.
Future<bool> _confirmDeleteVault(PluginHandle plugin, VaultInfo vault) async {
  final label =
      vault.vaultName.isNotEmpty ? vault.vaultName : vault.vaultId;
  final result = await showModalWith<bool>(
    plugin,
    build: (ctx) {
      ctx.h3('Delete vault "$label"?');
      ctx.spaceVertical(px: 8);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text:
            'This permanently deletes all of this vault\'s data from the server '
            '(files, history, blobs). Your local note files on disk are NOT '
            'deleted. If this vault used your own S3/WebDAV storage, clear that '
            'bucket separately. This cannot be undone.',
      );
      ctx.spaceVertical(px: 8);
      ctx.createEl('p', text: 'Type the vault name to confirm:');
      final input = ctx.input(placeholder: label)..focus();
      ctx.spaceVertical(px: 12);

      Future<void> confirm() async {
        if (ctx.valueOf(input).trim() != label) {
          ctx.showError('Name does not match.');
          return;
        }
        ctx.close(true);
      }

      ctx.buttonRow([
        ButtonSpec('Delete permanently', confirm),
        ButtonSpec('Cancel', () => ctx.close(false)),
      ]);
      ctx
        ..onEnter(input, confirm)
        ..onEscape(() => ctx.close(false));
    },
  );
  return result ?? false;
}

Future<(VaultConfig, VaultCipher)?> _connectToVault(
  PluginHandle plugin,
  IVaultDirectory directory,
  ObsidianConfigStorage configStorage, {
  required VaultInfo vault,
}) async {
  if (vault.verificationToken != null && vault.verificationToken!.isNotEmpty) {
    // Existing vault with E2EE — restore config and prompt for passphrase.
    final config = VaultConfig(
      vaultId: vault.vaultId,
      vaultName: vault.vaultName,
      verificationToken: vault.verificationToken,
    );
    await configStorage.save(config);
    final cipher = await showPassphraseModal(
      plugin,
      configStorage,
      vaultId: vault.vaultId,
      verificationToken: vault.verificationToken!,
    );
    if (cipher == null) return null;
    return (config, cipher);
  } else {
    // Vault exists but E2EE not set up — do setup now.
    final result = await showSetupModal(
      plugin,
      configStorage,
      vaultName: vault.vaultName,
    );
    if (result == null) return null;
    final (config, cipher) = result;
    if (config.verificationToken != null &&
        config.verificationToken!.isNotEmpty) {
      await directory.updateVerificationToken(
        vaultId: vault.vaultId,
        verificationToken: config.verificationToken!,
      );
    }
    return result;
  }
}

Future<(VaultConfig, VaultCipher)?> _createNewVault(
  PluginHandle plugin,
  IVaultDirectory directory,
  ObsidianConfigStorage configStorage, {
  required String vaultName,
}) async {
  final result = await showSetupModal(
    plugin,
    configStorage,
    vaultName: vaultName,
  );
  if (result == null) return null;
  final (config, cipher) = result;

  await directory.createVault(vaultId: config.vaultId, vaultName: vaultName);
  if (config.verificationToken != null &&
      config.verificationToken!.isNotEmpty) {
    await directory.updateVerificationToken(
      vaultId: config.vaultId,
      verificationToken: config.verificationToken!,
    );
  }
  return result;
}
