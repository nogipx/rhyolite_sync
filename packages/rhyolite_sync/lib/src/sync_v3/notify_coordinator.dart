import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_notify/rpc_notify.dart';

/// Wires the server-side notify channel ("server says: someone pushed
/// new state to this vault — go pull") into a single callback the
/// engine can react to.
///
/// Errors during setup or in the underlying stream are logged via
/// [onWarning] (engine plugs in its scoped logger) and do not propagate —
/// notify is a best-effort optimization: if it's down the engine
/// simply falls back to whatever timer-based pull cadence it has.
///
/// The subscription is SELF-HEALING: if the server-stream errors or
/// completes (e.g. the server closes the logical stream while the socket
/// stays alive), the coordinator resubscribes on its own with capped
/// exponential backoff, so notify doesn't silently stay dead. A genuine
/// transport reconnect — where the old stream goes silent WITHOUT erroring
/// or completing — is still the engine's job to handle (it builds a fresh
/// coordinator on the new connection); this only covers terminated streams.
class NotifyCoordinator {
  NotifyCoordinator({
    required this.endpoint,
    required this.topic,
    required this.onNotify,
    void Function(String message)? onWarning,
  }) : _onWarning = onWarning;

  final RpcCallerEndpoint endpoint;
  final String topic;
  final void Function() onNotify;
  final void Function(String message)? _onWarning;

  static const Duration _minBackoff = Duration(seconds: 1);
  static const Duration _maxBackoff = Duration(seconds: 30);

  NotifySubscriber? _subscriber;
  StreamSubscription? _sub;
  Timer? _resubscribeTimer;
  Duration _backoff = _minBackoff;

  /// True between [start] and [stop]; gates resubscribes so a stopped
  /// coordinator never reattaches.
  bool _active = false;

  /// Subscribes to the notify topic. Safe to call once per coordinator
  /// instance; a second call while active is a no-op.
  void start() {
    if (_active) return;
    _active = true;
    _subscribe();
  }

  void _subscribe() {
    if (!_active) return;
    _resubscribeTimer?.cancel();
    _resubscribeTimer = null;
    unawaited(_sub?.cancel());
    _sub = null;
    try {
      _subscriber = NotifySubscriber.endpoint(endpoint);
      _sub = _subscriber!.subscribe(topic).listen(
            (_) {
              _backoff = _minBackoff; // healthy delivery → reset backoff
              onNotify();
            },
            onError: (e) {
              _onWarning?.call('Notify stream error: $e — resubscribing');
              _scheduleResubscribe();
            },
            onDone: () {
              _onWarning?.call('Notify stream closed — resubscribing');
              _scheduleResubscribe();
            },
            cancelOnError: true,
          );
    } catch (e) {
      _onWarning?.call('Notify setup failed: $e — resubscribing');
      _scheduleResubscribe();
    }
  }

  void _scheduleResubscribe() {
    if (!_active) return;
    if (_resubscribeTimer != null) return; // one pending attempt at a time
    final delay = _backoff;
    final doubled = _backoff * 2;
    _backoff = doubled > _maxBackoff ? _maxBackoff : doubled;
    _resubscribeTimer = Timer(delay, _subscribe);
  }

  Future<void> stop() async {
    _active = false;
    _resubscribeTimer?.cancel();
    _resubscribeTimer = null;
    await _sub?.cancel();
    _sub = null;
    _subscriber = null;
  }
}
