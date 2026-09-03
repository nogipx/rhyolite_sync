import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';

/// What host this plugin is running in.
///
/// Four probes, grouped because they answer one question and fail the same
/// way: every one reaches into a JS object the host may not have shaped the
/// way this build expects, so every one falls back rather than throwing. A
/// plugin that cannot start because it could not read a version string would
/// be worse than one that reports an empty version.
///
/// Lives in `lib` rather than beside `onLoad` so it can be named, read and —
/// where the interop allows — exercised. That is the whole of the argument:
/// nothing here is hard, it was simply unreachable.

/// `desktop`, `Android` or `iOS`, for diagnostics that must tell devices
/// apart. `mobile` when the user agent cannot be read at all.
String diagnosticsOs(bool isMobile) {
  if (!isMobile) return 'desktop';
  try {
    final nav = jsu.getProperty<JSObject?>(jsu.globalThis, 'navigator');
    final ua = nav != null
        ? (jsu.getProperty<String?>(nav, 'userAgent') ?? '')
        : '';
    return ua.contains('Android') ? 'Android' : 'iOS';
  } catch (_) {
    return 'mobile';
  }
}

/// Best-effort read of this build's version from the Obsidian manifest.
String pluginVersion(PluginHandle plugin) {
  try {
    final manifest = jsu.getProperty<JSObject?>(plugin.raw, 'manifest');
    if (manifest == null) return '';
    return jsu.getProperty<String?>(manifest, 'version') ?? '';
  } catch (_) {
    return '';
  }
}

/// Obsidian's own API version, so a report says which host it came from.
String obsidianVersion() {
  try {
    return jsu.getProperty<String?>(obsidianModule(), 'apiVersion') ?? '';
  } catch (_) {
    return '';
  }
}

/// Whether Obsidian considers this a mobile host. Read defensively — every
/// caller has a sensible answer for "could not tell".
bool isMobileHost(PluginHandle plugin) {
  try {
    return jsu.getProperty<bool>(plugin.app.raw, 'isMobile');
  } catch (_) {
    return false;
  }
}

/// Starts the on-device log.
///
/// Runs at the very top of onLoad, before the first await, for the same reason
/// the panel view is registered there: whatever this call is placed after is
/// something a report can no longer explain. Boot is where the interesting
/// failures are, and until this feature existed a release build recorded none
/// of them.
///
/// Local only. This writes to a file inside the plugin's own folder and to a
/// memory ring, and transmits nothing; shipping the result anywhere is a
/// separate, deliberate act by the user (see [showBugReportModal]).
