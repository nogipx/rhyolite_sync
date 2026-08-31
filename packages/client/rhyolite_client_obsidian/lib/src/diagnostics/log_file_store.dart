/// Where the log sink puts bytes, behind a seam so the sink can be tested
/// without Obsidian.
///
/// The unit of retention is a **segment**: a plugin session, or a UTC day,
/// whichever ends first.
///
/// Sessions alone were tried and are not enough. Obsidian is left running for
/// days, so "keep the last five sessions" means five hours for someone who
/// restarts often and five weeks for someone who does not — the same
/// unbounded variance that makes plain day-based retention useless in the
/// other direction. Rolling on either boundary gives a window a person can
/// reason about, and it puts the cut where they describe problems anyway
/// ("it started yesterday").
///
/// Each segment writes:
///
///  * a **head**, frozen after the first few lines. The banner, the boot
///    timings, the connect and the first pull sit here. Under a flood these
///    are the first thing size-based rotation used to eat, and they are the
///    most valuable lines in the file.
///  * a **tail**, in numbered slots so recent output survives without ever
///    rewriting megabytes. The middle of a very loud segment is dropped; the
///    sequence numbers make the gap visible and countable. Numbered rather
///    than alternating, because after a restart nothing else says which of two
///    slots was the newer one.
///
/// Alongside them, spanning every segment, is **problems**: one file holding
/// every warning and error, each citing the segment and sequence number where
/// its full context lives. Warnings are rare enough that this reaches much
/// further back than the segment logs do.
abstract class LogFileStore {
  /// Starts [segmentId] and prunes old segments. Returns the ids still on
  /// disk, oldest first, including the new one.
  Future<List<String>> beginSegment(String segmentId);

  /// Appends to the current segment's head. Ignored once the head is frozen.
  Future<void> appendHead(String text);

  /// Appends to the current segment's tail, opening a new slot when the active
  /// one passes [tailSlotBytes]. Returns true when doing so discarded an older
  /// slot, which the caller reports as dropped records.
  Future<bool> appendTail(String text, {required int tailSlotBytes});

  /// Appends to the cross-segment problems file.
  Future<void> appendProblems(String text);

  /// The last [segments] segments in reading order, oldest first.
  ///
  /// More than one because a segment rolls at midnight: a problem noticed in
  /// the afternoon may have started before the roll, and a report holding only
  /// the current segment would have thrown that away.
  Future<String> readRecent(int segments);

  /// Every retained problem line, oldest first.
  Future<String> readProblems();

  /// Bytes every log file this store owns occupies, so the user can be told
  /// what deleting them frees.
  Future<int> totalBytes();

  /// Every retained file, as (name, contents), oldest segment first.
  ///
  /// Handed out one at a time and copied verbatim into the report archive.
  /// Nothing is concatenated: joining them was what forced a size cap in the
  /// first place, and it threw away the boundaries — which file, which
  /// segment — that say what a reader is looking at.
  Future<List<(String, String)>> readAllFiles();

  /// Drops every log file this store owns.
  Future<void> deleteAll();
}

/// Discards everything. Used when no writable location is available, so the
/// sink degrades to its in-memory ring instead of failing on every record.
class NoopLogFileStore implements LogFileStore {
  const NoopLogFileStore();

  @override
  Future<List<String>> beginSegment(String segmentId) async => [segmentId];

  @override
  Future<void> appendHead(String text) async {}

  @override
  Future<bool> appendTail(String text, {required int tailSlotBytes}) async =>
      false;

  @override
  Future<void> appendProblems(String text) async {}

  @override
  Future<String> readRecent(int segments) async => '';

  @override
  Future<String> readProblems() async => '';

  @override
  Future<int> totalBytes() async => 0;

  @override
  Future<List<(String, String)>> readAllFiles() async => const [];

  @override
  Future<void> deleteAll() async {}
}
