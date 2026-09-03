// ignore_for_file: deprecated_member_use
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';

import '../i18n/i18n.dart';
import '../settings/plugin_code_overview.dart';
import 'format_bytes.dart';

/// Plugin management: what the vault carries, what this device has of it, and
/// a way to drop a plugin from the vault entirely.
///
/// Removing here is the deliberate counterpart to the scan-time uninstall
/// detection: the user states the intent, so nothing has to be inferred from
/// the filesystem. It takes the plugin off every device and — because the
/// record then references no blobs — frees its storage, which is otherwise
/// held for good.
Future<void> showPluginManagementModal(
  PluginHandle plugin, {
  required Future<PluginCodeOverview> Function() load,
  required Future<bool> Function(String resourceId) onRemove,
}) async {
  final overview = await load();
  if (overview.isEmpty) {
    showNotice(S.pluginMgmtNoPlugins);
    return;
  }
  await _render(plugin, overview, load: load, onRemove: onRemove);
}

Future<void> _render(
  PluginHandle plugin,
  PluginCodeOverview overview, {
  required Future<PluginCodeOverview> Function() load,
  required Future<bool> Function(String resourceId) onRemove,
}) {
  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3(S.pluginMgmtTitle);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: S.pluginMgmtDescription(
          overview.count,
          formatBytes(overview.totalBytes),
        ),
      );
      ctx.spaceVertical(px: 12);

      final list = ctx.createEl('div');
      _css(list, {
        'display': 'flex',
        'flexDirection': 'column',
        'gap': '8px',
        'maxHeight': '55vh',
        'overflowY': 'auto',
        'paddingRight': '4px',
      });
      final doc = jsu.getProperty<JSObject>(list, 'ownerDocument');
      for (final p in overview.entries) {
        _pluginRow(doc, list, p, () async {
          ctx.close(null);
          final confirmed = await _confirmRemoval(plugin, p);
          if (!confirmed) return;
          try {
            final ok = await onRemove(p.resourceId);
            showNotice(
              ok
                  ? S.pluginRemovedFromVault(p.pluginId)
                  : S.pluginRemoveUnavailable,
            );
          } catch (e) {
            showNotice(S.pluginRemoveFailed(p.pluginId, e));
          }
          await _render(plugin, await load(), load: load, onRemove: onRemove);
        });
      }

      ctx.spaceVertical(px: 12);
      ctx.buttonRow([ButtonSpec(S.close, () => ctx.close(null))]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

/// Removal reaches every device, so it gets its own confirmation rather than
/// riding a single click in a list.
Future<bool> _confirmRemoval(PluginHandle plugin, PluginCodeRow p) async {
  final result = await showModalWith<bool>(
    plugin,
    build: (ctx) {
      ctx.h3(S.pluginRemoveTitle(p.pluginId));
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: S.pluginRemoveBody(formatBytes(p.sizeBytes)),
      );
      ctx.spaceVertical(px: 12);
      ctx.buttonRow([
        ButtonSpec(
          S.pluginRemoveConfirm,
          () => ctx.close(true),
          variant: ButtonVariant.destructive,
        ),
        ButtonSpec(S.cancel, () => ctx.close(false)),
      ]);
      ctx.onEscape(() => ctx.close(false));
    },
  );
  return result ?? false;
}

void _pluginRow(
  JSObject doc,
  JSObject host,
  PluginCodeRow p,
  Future<void> Function() onRemove,
) {
  final row = _el(doc, host, 'div');
  _css(row, {
    'display': 'flex',
    'alignItems': 'center',
    'gap': '10px',
    'padding': '8px 10px',
    'border': '1px solid var(--background-modifier-border)',
    'borderRadius': '6px',
  });

  final info = _el(doc, row, 'div');
  _css(info, {'flex': '1 1 auto', 'minWidth': '0'});

  final title = _el(
    doc,
    info,
    'div',
    text: '${p.pluginId}  ${p.vaultVersion ?? ''}'.trimRight(),
  );
  _css(title, {'fontWeight': '600', 'whiteSpace': 'nowrap'});

  final metaBits = <String>[
    formatBytes(p.sizeBytes),
    if (p.updatedBy != null) S.pluginFromDevice(p.updatedBy!),
    if (p.missingHere)
      p.desktopOnly ? S.pluginDesktopOnlySkipped : S.pluginNotInstalledHere,
    if (p.differsHere) S.pluginVersionHere(p.localVersion!),
  ];
  final meta = _el(doc, info, 'div', text: metaBits.join('  ·  '));
  _css(meta, {'fontSize': '12px', 'color': 'var(--text-muted)'});

  final btn = _el(doc, row, 'button', text: S.pluginRemoveAction);
  _css(btn, {'flex': '0 0 auto'});
  jsu.setProperty(btn, 'className', 'mod-warning');
  _onClick(btn, onRemove);
}

JSObject _el(JSObject doc, JSObject parent, String tag, {String? text}) {
  final el = jsu.callMethod<JSObject>(doc, 'createElement', [tag]);
  if (text != null) jsu.setProperty(el, 'textContent', text);
  jsu.callMethod<void>(parent, 'appendChild', [el]);
  return el;
}

void _onClick(JSObject el, void Function() handler) {
  jsu.callMethod<void>(el, 'addEventListener', [
    'click',
    jsu.allowInterop((JSAny? _) => handler()),
  ]);
}

void _css(JSObject el, Map<String, String> styles) {
  final style = jsu.getProperty<JSObject>(el, 'style');
  styles.forEach((k, v) {
    jsu.setProperty(style, k, v);
  });
}
