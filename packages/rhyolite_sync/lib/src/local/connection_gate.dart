import 'dart:async';

/// Serialises everything that touches one database connection.
///
/// A connection has ONE transaction slot. The data layer holds it across
/// awaits — a drift transaction body is async — while the blob store takes it
/// synchronously. Overlap gives `cannot start a transaction within a
/// transaction` on BEGIN and SQL-logic errors on COMMIT as the two unwind over
/// each other, which is how a user's first sync stopped banking anything.
///
/// The gate belongs to the CONNECTION, not to either component. A queue owned
/// by one of them serialises that one's callers and is invisible to the other:
/// that is exactly what shipped, and the second writer was six lines below the
/// first in the same function. One gate per connection, handed to everything
/// that writes.
///
/// Reads are serialised too. They look harmless, but a read can create a
/// collection table on the way past, and that is DDL inside a transaction like
/// any other. Nothing real is lost — calls to one connection were never
/// running in parallel, only queued somewhere less safe.
class ConnectionGate {
  /// Tail of the queue: a token saying "the previous holder is done", not its
  /// result.
  ///
  /// The `onError` that flattens it is deliberate. The caller's own error
  /// arrives through its own future; this one exists only for sequencing, and
  /// letting it carry the error would leave a future nobody awaits — an
  /// unhandled error per failed call.
  Future<void> _tail = Future<void>.value();

  /// Runs [body] once every earlier holder has finished.
  Future<T> run<T>(FutureOr<T> Function() body) {
    final completer = Completer<T>();
    final previous = _tail;
    _tail = completer.future.then<void>((_) {}, onError: (_) {});
    previous.whenComplete(() {
      // `Future.sync`, not a bare call: a body that throws SYNCHRONOUSLY would
      // otherwise throw out of this callback and leave the completer to hang
      // forever, which is worse than the collision being prevented.
      Future<T>.sync(
        body,
      ).then(completer.complete, onError: completer.completeError);
    });
    return completer.future;
  }
}
