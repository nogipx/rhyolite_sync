import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import 'diagnostic_redactor.dart';
import 'log_file_store.dart';
import 'log_line.dart';

/// What a report has to say about its own completeness.
class LogStats {
  const LogStats({
    required this.segmentId,
    required this.recordsSeen,
    required this.tailSlotsDiscarded,
    required this.retainedSegments,
    required this.fileHealthy,
  });

  final String segmentId;

  /// Records this session produced. Also the last sequence number handed out.
  final int recordsSeen;

  /// Times the tail ping-ponged and discarded a slot. Non-zero means the
  /// middle of this session is gone — the sequence numbers show where.
  final int tailSlotsDiscarded;

  /// Segments still on disk, this one included.
  final int retainedSegments;

  /// False when the store rejected a write and the report fell back to the
  /// memory ring.
  final bool fileHealthy;

  bool get isComplete => tailSlotsDiscarded == 0 && fileHealthy;
}

/// The always-on log destination for release builds.
///
/// Two destinations behind one output, because they fail differently:
///
///  * an in-memory ring, which cannot fail and cannot survive a restart;
///  * session files, which survive a restart and can fail (a read-only vault,
///    a mobile sandbox, a full disk).
///
/// A bug report reads the files and falls back to the ring, so a device that
/// cannot write to disk still reports the session it is in — which is the one
/// case where losing logs would be worst, since a failing write is itself the
/// kind of bug being reported.
///
/// Records are held unformatted and rendered at flush time. That is what lets
/// [redactor] arrive late: the vaultId it salts pseudonyms with is not known
/// until boot has read the config, and formatting eagerly would bake real
/// paths into the file for exactly the early-boot records that matter most.
///
/// [write] is called synchronously from the logging pipeline, so it only
/// buffers. Bytes reach the store on a timer, at a record threshold, or when
/// [flush] is awaited — never on the caller's stack, and never in a way that
/// can throw back into the code being logged.
class PersistentLogSink extends LogOutput {
  PersistentLogSink({
    required LogFileStore store,
    required String segmentId,
    this.memoryCapacity = 2000,
    this.flushThresholdRecords = 200,
    this.flushInterval = const Duration(seconds: 5),
    this.headLines = 60,
    this.tailSlotBytes = 2 * 1024 * 1024,
    this.redactorDeadline = const Duration(seconds: 30),
  }) : _store = store,
       _segmentId = segmentId,
       _segmentDay = '',
       _ring = List<LogRecord?>.filled(memoryCapacity, null),
       _seqRing = List<int>.filled(memoryCapacity, 0);

  final LogFileStore _store;
  String _segmentId;

  /// The UTC day the current segment belongs to. Empty until the first record
  /// dates it.
  String _segmentDay;

  /// Records kept in memory. Doubles as the flush buffer and as the report's
  /// fallback, so it is sized to hold a session of a normally-quiet engine
  /// rather than to be small.
  final int memoryCapacity;

  /// Buffered records that trigger a flush without waiting for the timer.
  final int flushThresholdRecords;

  /// How long a quiet buffer waits before reaching disk. Bounds how much a
  /// hard crash can lose.
  final Duration flushInterval;

  /// Lines pinned into the session head, never displaced however loud the
  /// session becomes. The banner, boot timings, connect and first pull fit
  /// comfortably; these are the lines a flood used to eat first, and the ones
  /// a reader needs to make sense of everything after them.
  final int headLines;

  /// Size of one tail slot. Two ping-pong, so recent output on disk sits
  /// between one and two of these.
  final int tailSlotBytes;

  /// How long the first write waits for a [redactor]. Boot sets one within
  /// milliseconds; this only matters when boot dies first, and a session that
  /// never opened a vault has no vault paths to protect anyway.
  final Duration redactorDeadline;

  final List<LogRecord?> _ring;
  final List<int> _seqRing;
  int _ringHead = 0;
  int _ringCount = 0;
  int _unflushed = 0;

  int _seq = 0;
  int _headWritten = 0;
  int _discardedSlots = 0;
  int _retainedSegments = 1;

  Timer? _timer;
  Timer? _deadline;
  bool _started = false;
  bool _disposed = false;

  /// Nothing reaches the files until this is settled — either a redactor was
  /// installed or [redactorDeadline] passed. Without the gate, the handful of
  /// records written between plugin load and config load would be the only
  /// ones on disk with real paths in them.
  bool _settled = false;

  DiagnosticRedactor? _redactor;

  /// Installs the redactor and releases the buffered records to disk. Setting
  /// it to null settles the gate too: it means "there is no vault here", not
  /// "wait longer".
  set redactor(DiagnosticRedactor? value) {
    _redactor = value;
    _settle();
  }

  DiagnosticRedactor? get redactor => _redactor;

  Future<void> _queue = Future<void>.value();
  Object? _lastStoreError;

  /// The most recent store failure, or null if the files have been healthy.
  Object? get lastStoreError => _lastStoreError;

  LogStats get stats => LogStats(
    segmentId: _segmentId,
    recordsSeen: _seq,
    tailSlotsDiscarded: _discardedSlots,
    retainedSegments: _retainedSegments,
    fileHealthy: _lastStoreError == null,
  );

  /// Opens the sink and prunes old sessions.
  Future<void> start({String? banner}) async {
    if (_started || _disposed) return;
    _started = true;
    _deadline = Timer(redactorDeadline, _settle);
    await _enqueue(() async {
      final segments = await _store.beginSegment(_segmentId);
      _retainedSegments = segments.isEmpty ? 1 : segments.length;
    });
    if (banner != null && banner.isNotEmpty) {
      _record(
        LogEvent(scope: 'session', level: RpcLogLevel.info, message: banner),
      );
      // A no-op while the redactor gate is closed, in which case the banner
      // goes out with the first real flush. It carries no paths.
      await flush();
    }
  }

  void _settle() {
    if (_settled) return;
    _settled = true;
    _deadline?.cancel();
    _deadline = null;
    unawaited(flush());
  }

  @override
  void write(LogRecord record) {
    if (_disposed) return;
    _record(record);
  }

  void _record(LogRecord record) {
    // A span start says only that work began; the matching span repeats all of
    // it with a duration, so it renders to nothing and is not worth a number.
    if (record is LogSpanStart) return;

    // Every record is written. Nothing is folded or summarised: a summary is
    // an interpretation, and an interpretation is the thing a reader then has
    // to guess behind. When the log outgrows its slot the middle is dropped
    // verbatim instead, and the gap in these numbers says exactly how much.
    final seq = ++_seq;

    _ring[_ringHead] = record;
    _seqRing[_ringHead] = seq;
    _ringHead = (_ringHead + 1) % memoryCapacity;
    if (_ringCount < memoryCapacity) _ringCount++;
    if (_unflushed < memoryCapacity) _unflushed++;

    if (_settled && _unflushed >= flushThresholdRecords) {
      unawaited(flush());
    } else {
      _scheduleFlush();
    }
  }

  void _scheduleFlush() {
    if (_timer != null || _disposed) return;
    _timer = Timer(flushInterval, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Writes everything buffered so far. Safe to call at any time; never
  /// throws. No-op while the redactor gate is still closed.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (!_settled) return;

    final pending = _takeUnflushed();
    if (pending.isEmpty) return;

    // Records are grouped by UTC day and each group written to its own
    // segment. Splitting here rather than at write time keeps a record in the
    // segment its timestamp belongs to even when a flush straddles midnight.
    var i = 0;
    while (i < pending.length) {
      final day = utcDay(pending[i].$2.timestamp);
      final group = <(int, LogRecord)>[];
      while (i < pending.length && utcDay(pending[i].$2.timestamp) == day) {
        group.add(pending[i]);
        i++;
      }
      if (_segmentDay.isNotEmpty && day != _segmentDay) {
        await _rollSegment(group.first.$2.timestamp);
      }
      _segmentDay = day;
      await _writeGroup(group);
    }
  }

  /// Starts a new segment because the day turned over inside a running
  /// session. The head is unfrozen so the new segment opens with its own
  /// context instead of inheriting a banner written days ago.
  Future<void> _rollSegment(DateTime at) async {
    final previous = _segmentId;
    _segmentId = segmentIdFor(at);
    _headWritten = 0;
    await _enqueue(() async {
      final segments = await _store.beginSegment(_segmentId);
      _retainedSegments = segments.isEmpty ? 1 : segments.length;
      await _store.appendHead(
        '#$_seq ${formatStamp(at)} INF session: segment continues from '
        '$previous (same session, new day)\n',
      );
    });
  }

  /// `20260831-000004-118`. Sortable, so retention needs no stat call, and
  /// millisecond-precise so a roll cannot collide with the segment it follows.
  static String segmentIdFor(DateTime at) {
    final t = at.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        '-${two(t.hour)}${two(t.minute)}${two(t.second)}-$ms';
  }

  Future<void> _writeGroup(List<(int, LogRecord)> pending) async {
    final head = StringBuffer();
    final tail = StringBuffer();
    final problems = StringBuffer();

    for (final (seq, record) in pending) {
      final line = formatLogRecord(record, redactor: _redactor, seq: seq);
      if (line.isEmpty) continue;
      if (_headWritten < headLines) {
        head.writeln(line);
        _headWritten++;
      } else {
        tail.writeln(line);
      }
      // A problem stays in the main log AND is copied here, citing where it
      // came from — the file is an index into the session, not a second and
      // possibly disagreeing account of it.
      if (isProblem(record)) {
        problems.writeln('[$_segmentId] $line');
      }
    }
    await _enqueue(() async {
      if (head.isNotEmpty) await _store.appendHead(head.toString());
      if (tail.isNotEmpty) {
        final discarded = await _store.appendTail(
          tail.toString(),
          tailSlotBytes: tailSlotBytes,
        );
        if (discarded) _discardedSlots++;
      }
      if (problems.isNotEmpty) {
        await _store.appendProblems(problems.toString());
      }
    });
  }

  List<(int, LogRecord)> _takeUnflushed() {
    if (_unflushed == 0) return const [];
    final all = _entries();
    final take = _unflushed > all.length ? all.length : _unflushed;
    _unflushed = 0;
    return all.sublist(all.length - take);
  }

  /// Runs [action] on the store queue, swallowing failures into
  /// [lastStoreError]. Logging must never take down the thing it is logging,
  /// and a throw here would surface inside whatever emitted the record.
  Future<void> _enqueue(Future<void> Function() action) {
    final next = _queue.then((_) async {
      try {
        await action();
      } catch (e) {
        _lastStoreError = e;
      }
    });
    // Keep the chain alive even if a link rejects, or every later flush would
    // be dropped by the dead future.
    _queue = next.catchError((_) {});
    return next;
  }

  List<(int, LogRecord)> _entries() {
    final out = <(int, LogRecord)>[];
    if (_ringCount < memoryCapacity) {
      for (var i = 0; i < _ringCount; i++) {
        out.add((_seqRing[i], _ring[i]!));
      }
      return out;
    }
    for (var i = 0; i < memoryCapacity; i++) {
      final idx = (_ringHead + i) % memoryCapacity;
      out.add((_seqRing[idx], _ring[idx]!));
    }
    return out;
  }

  /// Records held in memory, oldest first, rendered with the current redactor.
  /// Never fails, so this is the report's fallback when the files could not be
  /// written.
  List<String> get memoryEntries => [
    for (final (seq, record) in _entries())
      if (formatLogRecord(record, redactor: _redactor, seq: seq) case final line
          when line.isNotEmpty)
        line,
  ];

  /// Every retained log file, as (name, contents), oldest segment first.
  ///
  /// Files rather than one rendered blob: the archive keeps them separate, so
  /// nothing has to be concatenated and nothing has to be capped. Falls back
  /// to a single file built from the memory ring when the store could not be
  /// read — a device that cannot write its log is exactly the one worth
  /// hearing from.
  Future<List<(String, String)>> readAllLogFiles() async {
    _settle();
    await flush();
    var files = <(String, String)>[];
    try {
      files = await _store.readAllFiles();
    } catch (e) {
      _lastStoreError = e;
    }
    if (files.isEmpty) {
      final memory = memoryEntries.join('\n');
      if (memory.isNotEmpty) return [('memory-only.log', memory)];
    }
    return files;
  }

  /// The retained files joined, for callers that just want to read the log as
  /// one stream. The archive never uses this — it keeps the files apart.
  Future<String> readAllLogFilesJoined({int? maxLines}) async {
    final text = (await readAllLogFiles()).map((f) => f.$2).join('\n');
    if (maxLines == null) return text;
    return _tail(text, maxLines);
  }

  /// Every retained warning and error, across sessions. Each line cites the
  /// session it belongs to and the sequence number to find it under there.
  Future<String> readProblems({int? maxLines}) async {
    await flush();
    var text = '';
    try {
      text = await _store.readProblems();
    } catch (e) {
      _lastStoreError = e;
    }
    if (maxLines == null) return text;
    return _tail(text, maxLines);
  }

  /// Keeps the last [maxLines] lines. Cutting from the front keeps the tail,
  /// and the tail is where the failure is.
  static String _tail(String text, int maxLines) {
    final lines = text.split('\n');
    if (lines.length <= maxLines) return text;
    return lines.sublist(lines.length - maxLines).join('\n');
  }

  /// Bytes the log files occupy on disk.
  Future<int> diskBytes() async {
    try {
      return await _store.totalBytes();
    } catch (e) {
      _lastStoreError = e;
      return 0;
    }
  }

  /// Drops every log file and the memory ring. Logging continues afterwards —
  /// this erases history, it does not turn anything off.
  Future<void> clear() async {
    _ring.fillRange(0, memoryCapacity, null);
    _seqRing.fillRange(0, memoryCapacity, 0);
    _ringHead = 0;
    _ringCount = 0;
    _unflushed = 0;
    // Unfreeze the head: the files are gone, so the segment has to be able to
    // write its context again or everything after this is tail with no top.
    _headWritten = 0;
    await _enqueue(_store.deleteAll);
  }

  /// Stops the timers and writes what is buffered. [LogOutput.dispose] is
  /// synchronous, so the final flush is started and not awaited — Obsidian
  /// does not give an unloading plugin a chance to await anything either.
  @override
  void dispose() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _deadline?.cancel();
    _deadline = null;
    unawaited(flush());
    _disposed = true;
  }
}
