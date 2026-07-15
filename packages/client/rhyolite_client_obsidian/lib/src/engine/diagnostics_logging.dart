import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_log/rpc_dart_log.dart';

import '../settings/diagnostics_prefs.dart';

/// Owns the remote log-sink lifecycle on a shared [LogController].
///
/// Off by default so production stays silent unless the user explicitly opts
/// in (see [DiagnosticsPrefs]). [apply] installs or tears down a
/// [LogCollectorOutput] to match the current prefs and raises/lowers the
/// controller's [LogController.minLevel] accordingly, so a settings toggle
/// takes effect live without a plugin restart.
///
/// [LogController.removeOutput] only detaches an output from the pipeline — it
/// does NOT close the collector's WebSocket — so [_teardown] disposes the
/// output explicitly to avoid leaking a connection on disable / URL change.
class DiagnosticsLogging {
  DiagnosticsLogging({
    required LogController controller,
    required DeviceInfo Function() device,
    required RpcLogLevel baselineLevel,
    LogScope? log,
  })  : _controller = controller,
        _device = device,
        _baselineLevel = baselineLevel,
        _log = log;

  final LogController _controller;
  final DeviceInfo Function() _device;

  /// Level the controller returns to when the sink is torn down — the silent
  /// production baseline (warning) or the dev baseline (debug).
  final RpcLogLevel _baselineLevel;
  final LogScope? _log;

  LogCollectorOutput? _output;
  String? _activeUrl;

  /// Applies [prefs]. When enabled with a parseable `ws`/`wss` URL, (re)installs
  /// the remote sink and streams debug-level logs; otherwise tears it down and
  /// returns the controller to its silent baseline. Idempotent — re-applying
  /// the same URL while active is a no-op.
  void apply(DiagnosticsPrefs prefs) {
    final url = prefs.url.trim();
    if (!prefs.enabled || url.isEmpty) {
      _teardown();
      return;
    }

    // Already streaming to this exact URL — leave the live connection alone.
    if (_output != null && _activeUrl == url) return;

    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'ws' && uri.scheme != 'wss')) {
      _log?.warning(
        'Diagnostics: collector URL must be ws:// or wss:// — ignoring "$url"',
      );
      _teardown();
      return;
    }

    // URL changed while active — drop the old sink before opening the new one.
    _teardown();

    final output = LogCollectorOutput(uri: uri, device: _device());
    // Order: lower the gate first so the confirmation line below reaches the
    // freshly-added sink.
    _controller
      ..minLevel = RpcLogLevel.debug
      ..addOutput(output);
    _output = output;
    _activeUrl = url;
    _log?.warning('Diagnostics: streaming logs to $url');
  }

  /// Detaches and disposes the current sink (closing its WebSocket) and
  /// restores the silent baseline level. No-op when nothing is installed.
  void _teardown() {
    final out = _output;
    if (out == null) return;
    _controller
      ..removeOutput(out)
      ..minLevel = _baselineLevel;
    out.dispose();
    _output = null;
    _activeUrl = null;
  }

  /// Tears the sink down on plugin unload.
  void dispose() => _teardown();
}
