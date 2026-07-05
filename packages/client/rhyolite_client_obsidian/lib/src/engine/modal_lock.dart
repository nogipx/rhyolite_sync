/// Single-instance guard + wait primitive for top-level, user-facing
/// modals.
///
/// Sign-in, sign-up, passphrase, vault-picker and setup modals all
/// open through [withModalLock]. Auto-triggered flows (visibility
/// wake-up after the app is backgrounded, SessionExpired token
/// refresh) call [awaitModalClose] to wait until the current modal
/// finishes before they re-evaluate state and open their own. That
/// way we still show "sign in" / "connect vault" / "unlock vault"
/// automatically when really needed, but we never stack a second
/// modal on top of one the user is interacting with.
library;

import 'dart:async';

bool _open = false;
Completer<void>? _release;

bool get isModalOpen => _open;

/// Wraps [body] in a top-level modal lock. While [body] is running,
/// [isModalOpen] is true and any pending [awaitModalClose] callers
/// are parked. The lock clears even if [body] throws.
Future<T> withModalLock<T>(Future<T> Function() body) async {
  // Defensive: if a previous body somehow forgot to release, fail
  // fast instead of silently nesting.
  if (_open) {
    throw StateError(
      'withModalLock entered re-entrantly; auto-trigger flows must '
      'await modal close before re-locking.',
    );
  }
  _open = true;
  _release = Completer<void>();
  try {
    return await body();
  } finally {
    _open = false;
    final c = _release;
    _release = null;
    if (c != null && !c.isCompleted) c.complete();
  }
}

/// Completes the next time the currently-locked modal closes. Returns
/// immediately when no modal is open. Callers should re-check the
/// state they cared about after this returns — by the time the user
/// closes the modal the world may have moved on (they may have just
/// signed in inside that modal).
Future<void> awaitModalClose() {
  final c = _release;
  if (c == null) return Future<void>.value();
  return c.future;
}
