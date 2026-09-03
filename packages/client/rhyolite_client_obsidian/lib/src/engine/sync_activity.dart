import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Whether anything in the plugin is working, folded from the engine's events.
///
/// One implementation, owned by both surfaces that answer the question. They
/// used to answer it separately, from overlapping but different facts: the
/// panel counted open transfers and the status dot did not, so under one
/// moving file the panel said "syncing" while the dot a few centimetres below
/// it sat at rest.
///
/// The first attempt at fixing that compared the two rules with a regular
/// expression over the source, which tested the words rather than the answer,
/// broke on the first rename, and could have passed while both were wrong.
/// Two rules that must agree are better replaced by one rule.
///
/// Settings sync is READ rather than folded, because it is a sibling of the
/// engine and emits none of these events. Reading it also survives being built
/// late: a surface created after a transition still gets the truth, where one
/// holding a pushed flag keeps whatever it was born with.
class SyncActivity {
  SyncActivity({bool Function()? settingsBusy}) : _settingsBusy = settingsBusy;

  final bool Function()? _settingsBusy;

  /// The engine says it is mid-operation. Trustworthy in one direction: it is
  /// raised for the whole startup pipeline and released in a `finally`, and
  /// the invariant is to fail toward stuck-busy rather than stuck-idle.
  bool engineBusy = false;

  /// Paths with a transfer in flight.
  ///
  /// Needed because [engineBusy] goes quiet between phases while a large file
  /// keeps moving, and a status that reports the gaps between reports is how
  /// the panel came to flicker between "syncing" and "up to date" on a slow
  /// backend.
  final Set<String> _transfers = {};

  bool get hasOpenTransfers => _transfers.isNotEmpty;

  bool get settingsBusy => _settingsBusy?.call() ?? false;

  /// The single answer both surfaces show.
  bool get isWorking => engineBusy || hasOpenTransfers || settingsBusy;

  /// Folds one engine event. Returns whether the answer changed, so a caller
  /// can repaint only when it did.
  bool observe(SyncEngineEvent event) {
    final before = isWorking;
    switch (event) {
      case SyncBusy(:final busy):
        engineBusy = busy;
      case SyncBlobTransfer(:final path, :final done):
        if (done) {
          _transfers.remove(path);
        } else {
          _transfers.add(path);
        }
      case SyncStopped():
      case SyncDisconnected():
        // Whatever the last event said, a stopped engine has nothing in
        // flight. Entries left behind are never retired — the run that would
        // have retired them is the one that ended — and they hold the status
        // at "working" for a vault that has stopped.
        engineBusy = false;
        _transfers.clear();
      default:
        break;
    }
    return isWorking != before;
  }
}
