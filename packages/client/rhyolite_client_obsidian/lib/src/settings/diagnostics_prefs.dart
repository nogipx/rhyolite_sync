/// User preferences for remote diagnostics logging, persisted under the
/// `diagnostics` key of the plugin's `data.json`.
///
/// Off by default: in production NOTHING is logged (no console output, no
/// remote sink) until the user explicitly enables this AND supplies a
/// collector URL. When enabled, structured logs stream to [url] over
/// WebSocket. Logs carry file paths, ids, blob hashes, sizes and timings —
/// never file content (that stays end-to-end encrypted).
class DiagnosticsPrefs {
  const DiagnosticsPrefs({required this.enabled, required this.url});

  /// Master switch. False by default — the log collector is never installed
  /// and the log controller stays at its silent baseline.
  final bool enabled;

  /// WebSocket collector endpoint (`wss://host:port`). On iOS App Transport
  /// Security blocks cleartext `ws://` silently, so `wss://` is required there.
  final String url;

  static const dataKey = 'diagnostics';

  static const DiagnosticsPrefs disabled =
      DiagnosticsPrefs(enabled: false, url: '');

  /// Parses prefs from the raw `data.json` map (the whole document).
  factory DiagnosticsPrefs.fromData(Object? rawData) {
    final root = rawData is Map ? rawData[dataKey] : null;
    if (root is! Map) return disabled;
    final url = root['url'];
    return DiagnosticsPrefs(
      enabled: root['enabled'] == true,
      url: url is String ? url.trim() : '',
    );
  }

  Map<String, Object?> toJson() => {'enabled': enabled, 'url': url};

  DiagnosticsPrefs copyWith({bool? enabled, String? url}) => DiagnosticsPrefs(
        enabled: enabled ?? this.enabled,
        url: url ?? this.url,
      );
}
