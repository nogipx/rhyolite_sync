// ignore_for_file: deprecated_member_use
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import '../i18n/i18n.dart';
import 'obsidian_config_storage.dart';

/// Shows a passphrase prompt modal and handles unlock + optional key remembering.
///
/// [vaultId] and [verificationToken] are used to derive and verify the key.
///
/// Returns [VaultCipher] if unlock succeeded, null if cancelled.
Future<VaultCipher?> showPassphraseModal(
  PluginHandle plugin,
  ObsidianConfigStorage configStorage, {
  required String vaultId,
  required String verificationToken,
}) async {
  return showModalWith<VaultCipher?>(
    plugin,
    build: (ctx) {
      ctx.h3('Rhyolite Sync');
      ctx.spaceVertical(px: 8);

      final input = ctx.input(type: 'password', placeholder: S.vaultPassphrase)
        ..focus();
      ctx.spaceVertical(px: 16);

      // Show/hide passphrase toggle
      var showPassphrase = false;
      ctx.toggle(
        label: S.showPassphrase,
        initialValue: false,
        onChange: (value) {
          showPassphrase = value;
          jsu.setProperty(
            input.raw,
            'type',
            showPassphrase ? 'text' : 'password',
          );
        },
      );
      ctx.spaceVertical(px: 8);

      // Remember passphrase toggle with description
      var remember = true;
      ctx.toggle(
        label: S.rememberOnThisDevice,
        initialValue: remember,
        onChange: (value) => remember = value,
      );
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

      Future<void> tryUnlock() async {
        final passphrase = ctx.valueOf(input);
        if (passphrase.isEmpty) return;
        buttons[0].setDisabled(value: true);
        buttons[1].setDisabled(value: true);
        loading.show();
        final cipher = await VaultCipher.derive(passphrase, vaultId);
        final valid = await cipher.verifyToken(verificationToken);
        if (!valid) {
          loading.hide();
          buttons[0].setDisabled(value: false);
          buttons[1].setDisabled(value: false);
          ctx.showError(S.incorrectPassphrase);
          return;
        }
        if (remember) {
          await configStorage.rememberKey(cipher, vaultId);
        }
        ctx.close(cipher);
      }

      buttons = ctx.buttonRow([
        ButtonSpec(S.unlock, tryUnlock, variant: ButtonVariant.primary),
        ButtonSpec(S.cancel, () => ctx.close(null)),
      ]);
      ctx
        ..onEnter(input, tryUnlock)
        ..onEscape(() => ctx.close(null));
    },
  );
}
