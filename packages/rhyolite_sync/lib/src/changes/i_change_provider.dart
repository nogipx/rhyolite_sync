abstract interface class IChangeProvider {
  Stream<FileChangeEvent> get changes;

  /// Per-keystroke signal that the user is actively editing [path] —
  /// emitted before any on-disk write. The sync engine uses this to
  /// hold off the push debounce while typing is in progress: writes to
  /// disk are still observed via [changes], but the debounce keeps
  /// resetting until the user pauses.
  ///
  /// Providers without a typing signal (filesystem watchers, etc.)
  /// return an empty stream and let the disk-event debounce alone
  /// govern push pacing.
  Stream<String> get typing;

  /// Suppresses the next [count] event(s) for [path].
  /// Use before writing a file to disk to avoid echo-back sync loops.
  /// A fallback timer ([holdFor]) auto-clears the suppression if the
  /// expected event never arrives.
  void suppress(String path, {int count = 1, Duration holdFor = const Duration(seconds: 2)});

  /// Removes suppression for [path].
  void unsuppress(String path);
}

sealed class FileChangeEvent {
  const FileChangeEvent();
}

class FileCreatedEvent extends FileChangeEvent {
  const FileCreatedEvent({required this.relativePath});

  final String relativePath;
}

class FileModifiedEvent extends FileChangeEvent {
  const FileModifiedEvent({required this.relativePath});

  final String relativePath;
}

class FileMovedEvent extends FileChangeEvent {
  const FileMovedEvent({required this.fromPath, required this.toPath});

  final String fromPath;
  final String toPath;
}

class FileDeletedEvent extends FileChangeEvent {
  const FileDeletedEvent({required this.relativePath});

  final String relativePath;
}
