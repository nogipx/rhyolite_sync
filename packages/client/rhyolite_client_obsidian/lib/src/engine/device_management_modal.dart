// ignore_for_file: deprecated_member_use
import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Device management: lists the devices syncing this vault and lets the user
/// "forget" a stale one so it stops holding back history cleanup.
///
/// Forgetting only drops the device's server-side head record — it never
/// deletes vault content. A forgotten device that reconnects just reports a
/// fresh head. Cleanup itself stays as safe as before; forgetting a dead
/// device simply lets the next cleanup reclaim what that device was pinning.
Future<void> showDeviceManagementModal(
  PluginHandle plugin,
  ISyncEngine engine,
) async {
  final registry =
      engine is StateSyncEngine ? engine.createDeviceRegistry() : null;
  if (registry == null) {
    showNotice('Device management not available — engine is not connected');
    return;
  }
  await _render(plugin, registry);
}

Future<void> _render(
  PluginHandle plugin,
  DeviceRegistryUseCase registry,
) async {
  final List<SyncDevice> devices;
  try {
    devices = await registry();
  } catch (e) {
    showNotice('Failed to load devices: $e');
    return;
  }

  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3('Sync devices');
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: '${devices.length} device(s) have synced this vault. Forgetting '
            'a device you no longer use lets cleanup reclaim the history it '
            'was holding back. It does not delete any content.',
      );
      ctx.spaceVertical(px: 12);

      if (devices.isEmpty) {
        ctx.createEl('p', text: 'No devices have reported yet.');
      } else {
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
        for (final d in devices) {
          _deviceRow(doc, list, d, () async {
            ctx.close(null);
            try {
              final ok = await registry.forget(d.deviceId);
              showNotice(ok
                  ? 'Forgot ${d.name}. Run cleanup to reclaim its held history.'
                  : 'Device ${d.name} was already gone.');
              await _render(plugin, registry); // refresh the list
            } catch (e) {
              // e.g. an older server without the forgetDevice RPC.
              showNotice('Could not forget ${d.name}: $e');
            }
          });
        }
      }

      ctx.spaceVertical(px: 12);
      ctx.buttonRow([ButtonSpec('Close', () => ctx.close(null))]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

void _deviceRow(
  JSObject doc,
  JSObject host,
  SyncDevice d,
  Future<void> Function() onForget,
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

  final title = _el(doc, info, 'div',
      text: d.isCurrent ? '${d.name}  (this device)' : d.name);
  _css(title, {'fontWeight': '600', 'whiteSpace': 'nowrap'});

  final client = [
    if (d.clientKind.isNotEmpty) d.clientKind,
    if (d.clientVersion.isNotEmpty) d.clientVersion,
  ].join(' ');
  final metaBits = <String>[
    if (client.isNotEmpty) client,
    'seen ${_ago(d.lastSeen)}',
    if (d.behindBySeq > 0) '${d.behindBySeq} behind',
  ];
  final meta = _el(doc, info, 'div', text: metaBits.join('  ·  '));
  _css(meta, {'fontSize': '12px', 'color': 'var(--text-muted)'});

  // No Forget for the current device — it would just re-report immediately.
  if (!d.isCurrent) {
    final btn = _el(doc, row, 'button', text: 'Forget');
    _css(btn, {'flex': '0 0 auto'});
    jsu.setProperty(btn, 'className', 'mod-warning');
    _onClick(btn, onForget);
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
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
