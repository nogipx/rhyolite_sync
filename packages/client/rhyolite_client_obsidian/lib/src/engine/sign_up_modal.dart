import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_client_account/rhyolite_client_account.dart';

/// Result of sign-up:
/// - [client] is non-null if sign-in happened immediately (email confirmation disabled).
/// - [emailConfirmationRequired] is true when the server requires email confirmation.
typedef SignUpResult = ({
  RpcAccountClient? client,
  bool emailConfirmationRequired,
});

/// Shows a sign-up modal with email + password fields.
///
/// Returns [SignUpResult] on success, null if cancelled.
Future<SignUpResult?> showSignUpModal(
  PluginHandle plugin, {
  required RpcAccountClient client,
}) async {
  return showModalWith<SignUpResult?>(
    plugin,
    build: (ctx) {
      ctx.h3('Create Account');
      ctx.spaceVertical(px: 12);

      final emailInput = ctx.input(type: 'email', placeholder: 'Email');
      ctx.spaceVertical(px: 8);

      final passwordInput = ctx.input(type: 'password', placeholder: 'Password')
        ..focus();
      ctx.spaceVertical(px: 8);

      final passwordConfirmInput = ctx.input(
        type: 'password',
        placeholder: 'Confirm password',
      );
      ctx.spaceVertical(px: 16);

      final loading = ctx.spinner(label: 'Creating account…');

      late final List<ButtonRef> buttons;

      Future<void> trySignUp() async {
        final email = ctx.valueOf(emailInput).trim();
        final password = ctx.valueOf(passwordInput);
        final passwordConfirm = ctx.valueOf(passwordConfirmInput);

        if (email.isEmpty || password.isEmpty) return;
        if (password != passwordConfirm) {
          ctx.showError('Passwords do not match');
          return;
        }

        buttons[0].setDisabled(value: true);
        buttons[1].setDisabled(value: true);
        loading.show();

        try {
          await client.signUp(email, password);
          ctx.close((client: client, emailConfirmationRequired: false));
        } catch (e) {
          loading.hide();
          buttons[0].setDisabled(value: false);
          buttons[1].setDisabled(value: false);
          ctx.showError('Sign-up failed: $e');
        }
      }

      buttons = ctx.buttonRow([
        ButtonSpec('Create Account', trySignUp, variant: ButtonVariant.primary),
        ButtonSpec('Cancel', () => ctx.close(null)),
      ]);
      ctx
        ..onEnter(passwordConfirmInput, trySignUp)
        ..onEscape(() => ctx.close(null));
    },
  );
}
