/// Marks a value in a log record's `data` map as a vault path.
///
/// The point is to stop anything downstream from having to guess. A bug report
/// leaves the user's device, so it must not carry note titles or folder names;
/// but recovering those from an already-formatted message is ambiguous in
/// principle — in `superseded for Notes/Q3 plan.md` nothing in the text says
/// whether the name begins at `Q3` or at `plan`, and a guess is either a leak
/// or a mangled message.
///
/// So a path is never interpolated into a message. It is passed as data:
///
/// ```dart
/// _log.info('text reconcile begin', data: {'path': LogPath(relPath)});
/// ```
///
/// Each log output then decides what to do with it, knowing exactly which
/// bytes are a path: a development console prints it as it is, while the
/// on-device sink that feeds bug reports replaces it with a stable pseudonym.
///
/// [toString] returns the raw path, so an output that does nothing special
/// still renders something sensible — the fallback is "readable", and only the
/// outputs that promise privacy have to act.
class LogPath {
  const LogPath(this.value) : isConfigRelative = false;

  /// A path inside Obsidian's config directory — a plugin id, a theme name, a
  /// settings file. Kept readable by a redacting output.
  ///
  /// These describe the user's *setup*, never their notes, and a settings-sync
  /// bug is unreadable without them ("15 directories skipped: no manifest" is
  /// the answer, and it is nothing without the names). Declaring the exemption
  /// on the value is what makes it safe: the alternative — exempting whole
  /// files known to touch only `.obsidian/` — silently stops being true the
  /// day one of them handles a vault path.
  ///
  /// The value is config-relative (`plugins/omnisearch/data.json`), so it
  /// cannot be recognised by prefix; a vault can hold a folder called
  /// `plugins` too. Only the call site knows, so only the call site says.
  const LogPath.config(this.value) : isConfigRelative = true;

  final String value;

  /// Whether this path names part of Obsidian's configuration rather than the
  /// user's content.
  final bool isConfigRelative;

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) =>
      other is LogPath &&
      other.value == value &&
      other.isConfigRelative == isConfigRelative;

  @override
  int get hashCode => Object.hash(value, isConfigRelative);
}

/// Marks a value in a log record's `data` map as an endpoint URL.
///
/// Same contract as [LogPath], for a different secret. A self-hosting user's
/// server address is their own infrastructure — often a home IP — and the URL
/// may carry a credential outright, in userinfo (`wss://user:pass@host`) or a
/// query parameter. Neither belongs in a file the user sends to a stranger.
///
/// ```dart
/// _log.info('WebSocket connected', data: {'url': LogUrl(wsUri.toString())});
/// ```
///
/// What a redacting output keeps is the shape, because the shape is what gets
/// debugged: the scheme (`ws` vs `wss` decides whether iOS will talk to it at
/// all), the port, and whether the host was localhost, an IP or a name.
class LogUrl {
  const LogUrl(this.value);

  final String value;

  @override
  String toString() => value;

  @override
  bool operator ==(Object other) => other is LogUrl && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
