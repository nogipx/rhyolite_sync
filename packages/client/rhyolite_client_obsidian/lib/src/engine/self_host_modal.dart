import 'package:obsidian_dart/obsidian_dart.dart';

import 'obsidian_config_storage.dart';

/// Configure self-host mode: point the plugin at a self-hosted sync server
/// with a static bearer token instead of the managed account service.
///
/// Returns true if the configuration changed (the caller should reload the
/// plugin / restart the engine to apply it).
Future<bool> showSelfHostModal(
  PluginHandle plugin,
  ObsidianConfigStorage configStorage,
) async {
  final current = await configStorage.loadSelfHost();

  final result = await showModalWith<bool>(
    plugin,
    build: (ctx) {
      ctx.h3('Self-host server');
      ctx.spaceVertical(px: 8);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: 'Sync with your own server instead of the managed service. '
            'Reload the plugin after saving to apply.',
      );
      ctx.spaceVertical(px: 8);

      ctx.createEl('span', cls: 'rhyolite-vault-label', text: 'Server URL');
      ctx.spaceVertical(px: 4);
      final urlInput = ctx.input(
        placeholder: current.syncUrl.isNotEmpty
            ? current.syncUrl
            : 'wss://sync.example.com',
      )..focus();
      ctx.spaceVertical(px: 8);

      ctx.createEl('span', cls: 'rhyolite-vault-label', text: 'Access token');
      ctx.spaceVertical(px: 4);
      final tokenInput = ctx.input(placeholder: 'RHYOLITE_SYNC_TOKEN');
      ctx.spaceVertical(px: 12);

      ctx.buttonRow([
        ButtonSpec('Enable & Save', () async {
          final url = ctx.valueOf(urlInput).trim();
          final token = ctx.valueOf(tokenInput).trim();
          if (url.isEmpty || token.isEmpty) {
            ctx.showError('Server URL and access token are both required.');
            return;
          }
          await configStorage.saveSelfHost(enabled: true, syncUrl: url);
          await configStorage.saveSelfHostToken(token);
          // Switching edition/server: drop the current vault so the reload
          // lands on the new server's vault picker instead of trying to sync
          // the old vault (different registry, different E2EE) against it.
          await configStorage.disconnectVault();
          ctx.close(true);
        }, variant: ButtonVariant.primary),
        ButtonSpec('Disable', () async {
          await configStorage.saveSelfHost(
            enabled: false,
            syncUrl: current.syncUrl,
          );
          // Back to managed: drop the self-host vault too.
          await configStorage.disconnectVault();
          ctx.close(true);
        }),
        ButtonSpec('Cancel', () => ctx.close(false)),
      ]);
      ctx.onEscape(() => ctx.close(false));
    },
  );

  return result ?? false;
}
