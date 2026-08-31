import 'package:rhyolite_client_obsidian/src/diagnostics/diagnostic_redactor.dart';
import 'package:rhyolite_client_obsidian/src/diagnostics/log_file_store.dart';
import 'package:rhyolite_client_obsidian/src/diagnostics/persistent_log_sink.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class FakeLogFileStore implements LogFileStore {
  final Map<String, String> heads = {};
  final Map<String, List<String>> tails = {};
  String problems = '';
  List<String> sessions = [];
  String? current;
  int slot = 0;
  int slotBytes = 0;
  int discards = 0;
  int keepTailSlots = 2;

  /// When set, every append throws it — a read-only vault or a full disk.
  Object? appendFailure;

  @override
  Future<List<String>> beginSegment(String segmentId) async {
    current = segmentId;
    slot = 0;
    slotBytes = 0;
    heads[segmentId] = '';
    tails[segmentId] = [''];
    sessions = [...sessions, segmentId];
    return sessions;
  }

  @override
  Future<void> appendHead(String text) async {
    _guard();
    heads[current!] = (heads[current!] ?? '') + text;
  }

  @override
  Future<bool> appendTail(String text, {required int tailSlotBytes}) async {
    _guard();
    var discarded = false;
    if (slotBytes > 0 && slotBytes + text.length > tailSlotBytes) {
      slot++;
      slotBytes = 0;
      final stale = slot - keepTailSlots;
      if (stale >= 0 && tails[current!]![stale].isNotEmpty) {
        tails[current!]![stale] = '';
        discarded = true;
        discards++;
      }
    }
    final list = tails[current!]!;
    while (list.length <= slot) {
      list.add('');
    }
    list[slot] += text;
    slotBytes += text.length;
    return discarded;
  }

  @override
  Future<void> appendProblems(String text) async {
    _guard();
    problems += text;
  }

  @override
  Future<String> readRecent(int segments) async {
    final ids = heads.keys.toList()..sort();
    final take =
        ids.length <= segments ? ids : ids.sublist(ids.length - segments);
    final parts = <String>[];
    for (final id in take) {
      parts.add(heads[id] ?? '');
      parts.addAll(tails[id] ?? const []);
    }
    return parts.where((s) => s.isNotEmpty).join();
  }

  @override
  Future<String> readProblems() async => problems;

  @override
  Future<int> totalBytes() async {
    var total = problems.length;
    for (final h in heads.values) {
      total += h.length;
    }
    for (final slots in tails.values) {
      for (final t in slots) {
        total += t.length;
      }
    }
    return total;
  }

  @override
  Future<List<(String, String)>> readAllFiles() async {
    final out = <(String, String)>[];
    for (final id in heads.keys.toList()..sort()) {
      if ((heads[id] ?? '').isNotEmpty) out.add(('$id.head.log', heads[id]!));
      final slots = tails[id] ?? const <String>[];
      for (var i = 0; i < slots.length; i++) {
        if (slots[i].isNotEmpty) out.add(('$id.tail$i.log', slots[i]));
      }
    }
    if (problems.isNotEmpty) out.add(('problems.log', problems));
    return out;
  }

  @override
  Future<void> deleteAll() async {
    heads.clear();
    tails.clear();
    problems = '';
  }

  void _guard() {
    final f = appendFailure;
    if (f != null) throw f;
  }

  String get allTail =>
      (tails[current] ?? const []).where((s) => s.isNotEmpty).join();
}

LogEvent _event(String message, {RpcLogLevel level = RpcLogLevel.info}) =>
    LogEvent(scope: 'test', level: level, message: message);

/// Opens the gate that holds records back until a redactor is known. Null is a
/// real answer — it means "no vault here", not "wait longer".
PersistentLogSink _settled(PersistentLogSink s) => s..redactor = null;

PersistentLogSink _sink(
  FakeLogFileStore store, {
  int headLines = 60,
  int tailSlotBytes = 2 * 1024 * 1024,
  int memoryCapacity = 2000,
  int flushThresholdRecords = 200,
  Duration flushInterval = const Duration(seconds: 5),
}) =>
    PersistentLogSink(
      store: store,
      segmentId: '20260830-195622-000',
      headLines: headLines,
      tailSlotBytes: tailSlotBytes,
      memoryCapacity: memoryCapacity,
      flushThresholdRecords: flushThresholdRecords,
      flushInterval: flushInterval,
    );

void main() {
  late FakeLogFileStore store;
  setUp(() => store = FakeLogFileStore());

  group('sequence numbers', () {
    test('every written record carries one, in order', () async {
      final sink = _settled(_sink(store));
      await sink.start();
      sink
        ..write(_event('one'))
        ..write(_event('two'));
      await sink.flush();

      final text = store.heads[store.current]!;
      expect(text, contains('#1 '));
      expect(text, contains('#2 '));
      expect(text.indexOf('#1 '), lessThan(text.indexOf('#2 ')));
    });

    test('every record is written — repeats are never folded away', () async {
      // A summary would be an interpretation, and an interpretation is the
      // thing a reader then has to guess behind.
      final sink = _settled(_sink(store));
      await sink.start();
      for (var i = 0; i < 4; i++) {
        sink.write(_event('same shape'));
      }
      await sink.flush();

      final written = store.heads[store.current]! + store.allTail;
      expect('same shape'.allMatches(written).length, 4);
      expect(sink.stats.recordsSeen, 4);
    });
  });


  group('the session head', () {
    test('holds the first lines and is never displaced by later ones',
        () async {
      final sink = _settled(_sink(store, headLines: 3));
      await sink.start(banner: 'rhyolite 3.15.5 desktop');
      for (var i = 0; i < 50; i++) {
        sink.write(_event('later $i'));
      }
      await sink.flush();

      expect(store.heads[store.current], contains('rhyolite 3.15.5 desktop'));
      expect(store.allTail, isNot(contains('rhyolite 3.15.5')));
    });

  });

  test('the tail ping-pongs and reports the discard', () async {
    final sink = _settled(_sink(store, headLines: 0, tailSlotBytes: 200));
    await sink.start();
    for (var i = 0; i < 3; i++) {
      sink.write(_event('x' * 150));
      await sink.flush();
    }
    expect(store.discards, greaterThan(0));
    expect(sink.stats.tailSlotsDiscarded, store.discards);
  });

  group('rolling at midnight', () {
    // Obsidian is left running for days. Without this, "keep the last five
    // sessions" means five hours for someone who restarts often and five
    // weeks for someone who does not, and one head written last Monday would
    // be the only context in a week of log.
    LogEvent at(DateTime when, String message) => LogEvent(
          scope: 'test',
          level: RpcLogLevel.info,
          message: message,
          timestamp: when,
        );

    final beforeMidnight = DateTime.utc(2026, 8, 30, 23, 59, 50);
    final afterMidnight = DateTime.utc(2026, 8, 31, 0, 0, 4);

    test('a new day starts a new segment inside one session', () async {
      final sink = _settled(_sink(store));
      await sink.start();
      sink
        ..write(at(beforeMidnight, 'yesterday'))
        ..write(at(afterMidnight, 'today'));
      await sink.flush();

      expect(store.sessions, hasLength(2));
      expect(sink.stats.segmentId, isNot('20260830-195622-000'));
    });

    test('a record is filed under the day its timestamp belongs to', () async {
      // The split happens per flush batch, so a flush straddling midnight does
      // not drag the late-night records into the next day.
      final sink = _settled(_sink(store));
      await sink.start();
      sink
        ..write(at(beforeMidnight, 'yesterday'))
        ..write(at(afterMidnight, 'today'));
      await sink.flush();

      final first = store.sessions.first;
      final second = store.sessions.last;
      expect(store.heads[first], contains('yesterday'));
      expect(store.heads[first], isNot(contains('today')));
      expect(store.heads[second], contains('today'));
    });

    test('the new segment opens with its own head, not a stale banner',
        () async {
      final sink = _settled(_sink(store, headLines: 2));
      await sink.start(banner: 'rhyolite 3.15.5 desktop');
      sink.write(at(beforeMidnight, 'yesterday'));
      await sink.flush();
      sink.write(at(afterMidnight, 'today'));
      await sink.flush();

      final second = store.sessions.last;
      expect(store.heads[second], contains('segment continues from'));
      expect(store.heads[second], contains('today'));
    });

    test('a report spans segments, so this morning is not lost', () async {
      // A problem noticed in the afternoon may have started before the roll.
      final sink = _settled(_sink(store));
      await sink.start();
      sink.write(at(beforeMidnight, 'started going wrong here'));
      await sink.flush();
      sink.write(at(afterMidnight, 'noticed here'));
      await sink.flush();

      final text = await sink.readAllLogFilesJoined();
      expect(text, contains('started going wrong here'));
      expect(text, contains('noticed here'));
    });

    test('sequence numbers continue across the roll', () async {
      // One session, one numbering: a problems-file citation still resolves.
      final sink = _settled(_sink(store));
      await sink.start();
      sink
        ..write(at(beforeMidnight, 'before'))
        ..write(at(afterMidnight, 'after'));
      await sink.flush();

      expect(sink.stats.recordsSeen, 2);
      expect(store.heads[store.sessions.last], contains('#2 '));
    });
  });

  group('the problems file', () {
    test('takes warnings and errors, citing the session', () async {
      final sink = _settled(_sink(store));
      await sink.start();
      sink
        ..write(_event('routine'))
        ..write(_event('it broke', level: RpcLogLevel.error));
      await sink.flush();

      expect(store.problems, contains('it broke'));
      expect(store.problems, contains('[20260830-195622-000]'));
      expect(store.problems, isNot(contains('routine')));
    });

    test('the entry stays in the main log too — it is an index, not a move',
        () async {
      final sink = _settled(_sink(store));
      await sink.start();
      sink.write(_event('it broke', level: RpcLogLevel.error));
      await sink.flush();

      expect(store.heads[store.current], contains('it broke'));
    });

    test('the cited sequence number finds the line in the session log',
        () async {
      final sink = _settled(_sink(store));
      await sink.start();
      sink
        ..write(_event('a'))
        ..write(_event('boom', level: RpcLogLevel.error));
      await sink.flush();

      final seq = RegExp(r'#(\d+)').firstMatch(store.problems)!.group(0)!;
      expect(await sink.readAllLogFilesJoined(), contains('$seq '));
    });
  });

  group('stats tell the report what it is missing', () {
    test('a clean session reports itself complete', () async {
      final sink = _settled(_sink(store));
      await sink.start();
      sink.write(_event('one'));
      await sink.flush();
      expect(sink.stats.isComplete, isTrue);
    });

    test('a dropped middle makes it incomplete', () async {
      final sink = _settled(_sink(store, headLines: 0, tailSlotBytes: 200));
      await sink.start();
      for (var i = 0; i < 3; i++) {
        sink.write(_event('x' * 150));
        await sink.flush();
      }
      expect(sink.stats.isComplete, isFalse);
    });

    test('an unwritable file makes it incomplete', () async {
      final sink = _settled(_sink(store));
      await sink.start();
      store.appendFailure = StateError('read-only');
      sink.write(_event('lost'));
      await sink.flush();
      expect(sink.stats.fileHealthy, isFalse);
      expect(sink.stats.isComplete, isFalse);
    });
  });

  group('the redactor gate', () {
    LogEvent pathEvent(String path) => LogEvent(
          scope: 'test',
          level: RpcLogLevel.info,
          message: 'reconcile',
          data: {'path': LogPath(path)},
        );

    test('nothing reaches disk before a redactor is known', () async {
      final sink = _sink(store);
      await sink.start();
      sink.write(pathEvent('Notes/Daily.md'));
      await sink.flush();
      expect(store.heads[store.current] ?? '', isEmpty);
    });

    test('records buffered during boot are redacted once it arrives', () async {
      final sink = _sink(store);
      await sink.start();
      sink.write(pathEvent('Notes/Daily.md'));

      sink.redactor = DiagnosticRedactor(salt: 'vault-1');
      await sink.flush();

      final written = store.heads[store.current]!;
      expect(written, isNot(contains('Daily')));
      expect(written, contains('.md'));
    });

    test('a report opens the gate — an empty report helps nobody', () async {
      final sink = _sink(store);
      await sink.start();
      sink.write(_event('boot failed here'));
      expect(await sink.readAllLogFilesJoined(), contains('boot failed here'));
    });
  });

  group('when the files cannot be written', () {
    test('the failure is captured instead of thrown at the caller', () async {
      final sink = _settled(_sink(store));
      await sink.start();
      store.appendFailure = StateError('read-only');
      sink.write(_event('still logged'));
      await sink.flush();
      expect(sink.lastStoreError, isStateError);
    });

    test('the report falls back to the memory ring', () async {
      final sink = _settled(_sink(store));
      store.appendFailure = StateError('read-only');
      sink.write(_event('only in memory'));
      expect(await sink.readAllLogFilesJoined(), contains('only in memory'));
    });

    test('later flushes still run — the queue is not poisoned', () async {
      final sink = _settled(_sink(store));
      await sink.start();
      store.appendFailure = StateError('read-only');
      sink.write(_event('lost'));
      await sink.flush();

      store.appendFailure = null;
      sink.write(_event('kept'));
      await sink.flush();

      expect(store.heads[store.current]! + store.allTail, contains('kept'));
    });
  });

  test('the memory ring keeps the newest records and drops the oldest', () {
    // Distinct shapes, or collapsing would fold them and the ring would be
    // testing suppression rather than eviction.
    const names = ['alpha', 'bravo', 'charlie', 'delta', 'echo'];
    final sink = _settled(_sink(store, memoryCapacity: 3));
    for (final n in names) {
      sink.write(_event(n));
    }
    final entries = sink.memoryEntries;
    expect(entries, hasLength(3));
    expect(entries.first, contains('charlie'));
    expect(entries.last, contains('echo'));
  });

  group('clearing', () {
    test('reports the size it is about to free', () async {
      final sink = _settled(_sink(store));
      await sink.start();
      sink.write(_event('something worth bytes'));
      await sink.flush();
      expect(await sink.diskBytes(), greaterThan(0));
    });

    test('erases the files and the ring', () async {
      final sink = _settled(_sink(store));
      await sink.start();
      sink.write(_event('gone'));
      await sink.flush();

      await sink.clear();

      expect(sink.memoryEntries, isEmpty);
      expect(await sink.diskBytes(), 0);
    });

    test('logging continues, and the segment gets its head back', () async {
      // clear() erases history; it does not turn anything off. Without
      // unfreezing the head, everything after would be tail with no top.
      final sink = _settled(_sink(store, headLines: 5));
      await sink.start();
      sink.write(_event('before'));
      await sink.flush();

      await sink.clear();
      sink.write(_event('after'));
      await sink.flush();

      expect(store.heads[store.current], contains('after'));
      expect(store.heads[store.current], isNot(contains('before')));
    });
  });

  test('span starts are not recorded — they render to nothing', () {
    final sink = _settled(_sink(store));
    sink.write(LogSpanStart(spanId: 's', scope: 'test', name: 'op'));
    expect(sink.memoryEntries, isEmpty);
  });

  test('readSessionLog keeps the tail when capped', () async {
    // Each message its own shape, so nothing is folded and the cap is what is
    // under test.
    final sink = _settled(_sink(store, headLines: 0));
    await sink.start();
    for (var i = 0; i < 20; i++) {
      sink.write(_event('step ${String.fromCharCode(97 + i)}'));
    }
    final text = await sink.readAllLogFilesJoined(maxLines: 5);
    expect(text, contains('step t'));
    expect(text, isNot(contains('step a')));
  });
}
