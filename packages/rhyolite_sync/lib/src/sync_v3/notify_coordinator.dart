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
/// exponential backoff, so notify doesn't silently stay dead.
///
/// [resolveEndpoint] is asked again on EVERY attempt, and that is the point.
/// It used to be a captured value, which made a resubscribe useful only while
/// the connection it was captured from still lived: after a transport swap
/// every retry re-attached to the dead one and failed identically, forever,
/// while the log filled with `transport not connected — resubscribing` and
/// notify was simply gone. Recovery then depended on someone outside noticing
/// and building a whole new coordinator, and nine minutes of a real session
/// went that way because nobody did.
///
/// Returning null means "no connection right now" — a wait, not a failure.
/// The coordinator backs off and asks again rather than treating it as an
/// error, because there is nothing to report and nothing to fix.
class NotifyCoordinator {
  NotifyCoordinator({
    required this.resolveEndpoint,
    required this.topic,
    required this.onNotify,
    void Function(String message)? onWarning,
    void Function(String message)? onInfo,
  }) : _onWarning = onWarning,
       _onInfo = onInfo;

  /// The connection to subscribe on, asked for fresh at every attempt.
  final RpcCallerEndpoint? Function() resolveEndpoint;
  final String topic;

  /// Invoked on each delivered notification. Receives the publisher's
  /// `sourceClientId` from the event payload (null when the publisher did not
  /// set one) so a subscriber can ignore the echo of its own push.
  final void Function(String? sourceClientId) onNotify;
  final void Function(String message)? _onWarning;

  /// Says when a subscription is ESTABLISHED, which nothing did before.
  ///
  /// Only failures were logged, so "subscribed and the server sends nothing"
  /// and "never subscribed at all" produced identical silence — and a report
  /// of missing notifications could not be told apart from a healthy client
  /// waiting on a quiet server.
  final void Function(String message)? _onInfo;

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
    final endpoint = resolveEndpoint();
    if (endpoint == null) {
      // No connection to attach to. Silent on purpose: this is the ordinary
      // state between a drop and a reconnect, and warning about it once per
      // backoff is how a log becomes unreadable.
      _scheduleResubscribe();
      return;
    }
    try {
      _subscriber = NotifySubscriber.endpoint(endpoint);
      _onInfo?.call('Notify subscribing to $topic');
      _sub = _subscriber!
          .subscribe(topic)
          .listen(
            (event) {
              if (_backoff != _minBackoff) {
                _onInfo?.call('Notify delivering again on $topic');
              }
              _backoff = _minBackoff; // healthy delivery → reset backoff
              onNotify(event.payload['sourceClientId'] as String?);
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
