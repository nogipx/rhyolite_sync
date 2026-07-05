import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_client_account/rhyolite_client_account.dart';

/// Shows a sign-in modal with email + password fields.
///
/// Returns [RpcAccountClient] on success, null if cancelled.
Future<RpcAccountClient?> showSignInModal(
  PluginHandle plugin, {
  required RpcAccountClient client,
}) async {
  return showModalWith<RpcAccountClient?>(
    plugin,
    build: (ctx) {
      ctx.h3('Sign In');
      ctx.spaceVertical(px: 12);

      final emailInput = ctx.input(type: 'email', placeholder: 'Email');
      ctx.spaceVertical(px: 8);

      final passwordInput = ctx.input(type: 'password', placeholder: 'Password')
        ..focus();
      ctx.spaceVertical(px: 16);

      final loading = ctx.spinner(label: 'Signing in…');

      late final List<ButtonRef> buttons;

      Future<void> trySignIn() async {
        final email = ctx.valueOf(emailInput).trim();
        final password = ctx.valueOf(passwordInput);
        if (email.isEmpty || password.isEmpty) return;

        buttons[0].setDisabled(value: true);
        buttons[1].setDisabled(value: true);
        loading.show();

        try {
          await client.signIn(email, password);
          ctx.close(client);
        } catch (e) {
          loading.hide();
          buttons[0].setDisabled(value: false);
          buttons[1].setDisabled(value: false);
          ctx.showError('Sign-in failed: $e');
        }
      }

      buttons = ctx.buttonRow([
        ButtonSpec('Sign In', trySignIn, variant: ButtonVariant.primary),
        ButtonSpec('Cancel', () => ctx.close(null)),
      ]);
      ctx
        ..onEnter(passwordInput, trySignIn)
        ..onEscape(() => ctx.close(null));
    },
  );
}
