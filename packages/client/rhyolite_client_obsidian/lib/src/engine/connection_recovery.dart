/// What to do when a connection probe comes back negative.
enum ConnectionRecovery {
  /// Restart the engine: it is silent and unreachable, which is what a dead
  /// transport looks like.
  restart,

  /// Leave it alone. The engine is demonstrably alive — it is still emitting
  /// — so the probe failing says something about load, not about the socket.
  waitItIsAlive,

  /// Re-arm the connection without tearing anything down: reissue notify,
  /// pull, resync settings.
  ///
  /// The commonest real cause of a dead probe is a socket that was swapped
  /// underneath a live engine — rpc_dart's reconnect replaces the transport
  /// but does not carry in-flight calls across, so the notify stream goes
  /// permanently silent while everything else still works. That is repaired
  /// by re-arming, and a restart repairs it too — at the cost of every file
  /// the startup pass had uploaded.
  ///
  /// So it goes first, and the probe is asked again afterwards. Only a second
  /// refusal earns the restart.
  nudge,
}

/// Decides whether a failed health check justifies tearing the engine down.
///
/// The probe is one `getStates` with a five-second awaiter timeout. Passing
/// proves the socket is alive; FAILING proves much less than the old logic
/// assumed. dart2js runs on one thread, so a startup pass that is chunking,
/// hashing and encrypting leaves the RPC response and the timeout timer
/// queued behind the same work — five seconds of backlog is ordinary while a
/// vault of thousands of files is being uploaded for the first time.
///
/// The remedy is drastic: `stop()` disposes the blob hub and nulls the
/// stores, so an in-flight startup pass is abandoned. One real vault lost a
/// pass that way after an hour of uploading, and the restart began by
/// re-scanning all 9121 files.
///
/// So the asymmetry decides it. Restarting a healthy busy engine costs
/// everything that pass had done; declining to restart a genuinely dead one
/// costs a few seconds, because the self-heal ladder comes back at 5s, 10s,
/// 20s, 40s, then every minute. The default belongs on the cheap side of that.
///
/// [sinceLastEvent] is the time since the engine last emitted ANYTHING. An
/// engine that is emitting is alive whatever a ping says, and that is a far
/// better liveness signal than the ping: it needs no round trip and cannot be
/// starved by the work it is reporting on.
/// [busy] is the engine's own [SyncBusy] state. It is the strongest signal
/// available and the probe cannot see it: the engine raises it for the whole
/// startup pipeline and releases it in a `finally`, and its stated invariant
/// is to fail toward stuck-busy rather than stuck-idle. So while it is set,
/// work is happening — even across the startup scan, which walks the vault
/// for a minute without emitting anything else.
///
/// [busyPatience] is the escape hatch for the other side of that invariant. A
/// wedged engine stays busy forever, and deferring to it forever would trade
/// one stuck state for another; past this bound, busy stops being an excuse.
/// Long, because the thing it must not interrupt is measured in minutes.
ConnectionRecovery planConnectionRecovery({
  required Duration sinceLastEvent,
  bool busy = false,
  bool engineStopped = false,
  Duration aliveWithin = const Duration(seconds: 20),
  Duration busyPatience = const Duration(minutes: 5),
  bool alreadyNudged = false,
}) {
  // Before anything about recency. A stopped engine is not slow, and every
  // branch below reasons about how recently it spoke — which a stopped engine
  // did, right up to the moment it stopped. That is how an instant `stopped`
  // was read as "alive, do not disturb" four times in a row while a user's
  // vault sat broken: the strongest evidence of death is also the freshest.
  //
  // Nudging is pointless too — there is no connection to re-arm.
  if (engineStopped) return ConnectionRecovery.restart;
  if (sinceLastEvent <= aliveWithin) return ConnectionRecovery.waitItIsAlive;
  if (busy && sinceLastEvent <= busyPatience) {
    return ConnectionRecovery.waitItIsAlive;
  }
  // Silent and unreachable. Still not a restart on the first refusal: try the
  // cheap repair, then ask again. [alreadyNudged] is the caller saying it has
  // done that and been refused a second time.
  return alreadyNudged ? ConnectionRecovery.restart : ConnectionRecovery.nudge;
}

/// Whether a recovery attempt should run at all, before anything is probed.
///
/// Split out from the probe/plan pair because these are refusals of a
/// different kind: [planConnectionRecovery] weighs evidence about a live
/// engine, while every case here says there is nothing to recover, or nothing
/// to recover TO, and asking would only cost a round trip to find that out.
///
/// [bootInFlight] is the one that had to be learned. A restart is a stop
/// followed by a start, and in between the engine answers `stopped` — the one
/// verdict the planner never second-guesses, ahead of every liveness test. So
/// probing across a restart reliably schedules another restart, which lands on
/// the first and tears down whatever it had going. Coming back to the window
/// while sync is restarting is an ordinary thing to do, and a user reported it
/// as sync starting over every time she did.
///
/// [alreadyRecovering] guards the same window from the other side: the ladder
/// re-entering itself.
///
/// [bootRunningFor] bounds the boot guard, for the same reason [busyPatience]
/// bounds deferring to a busy engine: a restart that hangs — a `stop()` waiting
/// on a pull that will not unwind — would otherwise disable recovery for the
/// rest of the load, trading a restart loop for a plugin that cannot restart at
/// all. Past the bound the guard steps out of the way and the ladder decides on
/// the evidence, as it did before.
bool shouldAttemptRecovery({
  required bool paused,
  required bool blocked,
  required bool engineMissing,
  required bool alreadyRecovering,
  Duration? bootRunningFor,
  Duration bootPatience = const Duration(minutes: 3),
  bool requireVisible = false,
  bool visible = true,
}) {
  if (alreadyRecovering) return false;
  if (paused) return false;
  // Restarting against a missing session or a locked vault cannot succeed, and
  // each attempt costs a full refresh round trip before failing.
  if (blocked) return false;
  if (engineMissing) return false;
  if (bootRunningFor != null && bootRunningFor <= bootPatience) return false;
  if (requireVisible && !visible) return false;
  return true;
}

/// How long to give the connection probe.
///
/// Five seconds is fine for an idle engine and wrong for a working one. On
/// dart2js the probe queues behind the very work it is probing: a startup pass
/// chunking, hashing and encrypting will spend that whole budget on its own
/// backlog, and the probe then reports a dead socket for an engine that is
/// merely busy.
///
/// The probe asks whether the socket is ALIVE, not whether it is quick, so a
/// longer deadline while busy costs nothing real and removes most of the false
/// negatives. It is not unbounded: a genuinely dead socket still resolves, just
/// half a minute later, and the self-heal ladder is what covers that gap.
Duration probeTimeout({required bool busy}) =>
    busy ? const Duration(seconds: 30) : const Duration(seconds: 5);
