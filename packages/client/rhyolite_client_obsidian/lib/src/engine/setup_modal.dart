// ignore_for_file: deprecated_member_use
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import '../i18n/i18n.dart';
import 'obsidian_config_storage.dart';

/// Setup modal: asks for passphrase + confirmation, creates or migrates vault with E2EE.
/// [existingConfig] — pass when migrating an existing vault to E2EE.
/// Returns (VaultConfig, VaultCipher) on success, null if cancelled.
Future<(VaultConfig, VaultCipher)?> showSetupModal(
  PluginHandle plugin,
  ObsidianConfigStorage configStorage, {
  required String vaultName,
  VaultConfig? existingConfig,
}) async {
  return showModalWith<(VaultConfig, VaultCipher)?>(
    plugin,
    build: (ctx) {
      ctx.h3('Rhyolite Sync');
      ctx.createEl('p',
          cls: 'rhyolite-setting-desc', text: S.setupDescription);
      ctx.spaceVertical(px: 12);

      final passphraseInput = ctx.input(
        type: 'password',
        placeholder: S.enterPassphrase,
      )..focus();
      ctx.spaceVertical(px: 8);

      final confirmInput = ctx.input(
        type: 'password',
        placeholder: S.confirmPassphrase,
      );
      ctx.spaceVertical(px: 8);

      // Show/hide passphrase toggle
      var showPassphrase = false;
      ctx.toggle(
        label: S.showPassphrase,
        initialValue: false,
        onChange: (value) {
          showPassphrase = value;
          final type = showPassphrase ? 'text' : 'password';
          jsu.setProperty(passphraseInput.raw, 'type', type);
          jsu.setProperty(confirmInput.raw, 'type', type);
        },
      );
      ctx.spaceVertical(px: 16);

      // Remember passphrase toggle with description
      var rememberPassphrase = true;
      ctx.toggle(
        label: S.rememberOnThisDevice,
        initialValue: true,
        onChange: (value) => rememberPassphrase = value,
      );
      ctx.spaceVertical(px: 4);
      ctx.column((col) {
        col.createEl(
          'p',
          cls: 'rhyolite-setting-desc',
          text: S.rememberKeyDescription,
        );
      });
      ctx.spaceVertical(px: 8);

      final loading = ctx.spinner(label: S.derivingKey);

      late final List<ButtonRef> buttons;

      Future<void> tryCreate() async {
        final passphrase = ctx.valueOf(passphraseInput);
        final confirm = ctx.valueOf(confirmInput);
        if (passphrase.isEmpty) {
          ctx.showError(S.passphraseEmpty);
          return;
        }
        final validation = PassphraseValidator.validate(passphrase);
        if (!validation.isValid) {
          ctx.showError(validation.error ?? S.passphraseTooWeak);
          return;
        }
        if (passphrase != confirm) {
          ctx.showError(S.passphrasesDoNotMatch);
          return;
        }
        buttons[0].setDisabled(value: true);
        buttons[1].setDisabled(value: true);
        loading.show();
        final result = existingConfig != null
            ? await configStorage.enableE2ee(
                existing: existingConfig,
                passphrase: passphrase,
              )
            : await configStorage.createWithE2ee(
                vaultName: vaultName,
                passphrase: passphrase,
              );
        if (rememberPassphrase) {
          await configStorage.rememberKey(result.$2, result.$1.vaultId);
        }
        ctx.close(result);
      }

      buttons = ctx.buttonRow([
        ButtonSpec(
          S.setUpEncryption,
          tryCreate,
          variant: ButtonVariant.primary,
        ),
        ButtonSpec(S.cancel, () => ctx.close(null)),
      ]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}
