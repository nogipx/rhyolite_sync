@TestOn('vm')
library;

import 'dart:async';

import 'package:rhyolite_client_obsidian/src/diagnostics/log_file_store.dart';
import 'package:rhyolite_client_obsidian/src/diagnostics/persistent_log_sink.dart';
import 'package:rhyolite_client_obsidian/src/engine/gated_database.dart';
import 'package:rhyolite_client_obsidian/src/engine/plugin_session.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// What a load gives back, and when.
//
// The ordering here is not a preference. Obsidian does not await `onunload`, so
// a reload can begin while teardown is suspended at an await — anything still
// attached to Obsidian at that moment stays attached with no owner, which is
// how one user collected seven settings tabs and seven sync circles in a
// session. So the detaching half has to finish before the first await, and the
// rest can take as long as it needs.
//
// The UI half cannot be exercised here: SyncPanel and SyncStatusIndicator need
// a live Obsidian handle. What is testable is the rule they depend on — that
// dispose() reaches its own first await with the synchronous work already done
// — and every resource that is not JS-bound.
// ---------------------------------------------------------------------------

void main() {
  test('the detaching half finishes before the first await', () async {
    final session = PluginSession(logs: LogController(outputs: []));

    // A timer left running past teardown fires into a disposed graph. These are
    // the three the plugin arms.
    session.flushDebounce = Timer(const Duration(minutes: 5), () {});
    session.settingsReloadDebounce = Timer(const Duration(minutes: 5), () {});
    session.selfHealTimer = Timer(const Duration(minutes: 5), () {});
    final timers = [
      session.flushDebounce!,
      session.settingsReloadDebounce!,
      session.selfHealTimer!,
    ];

    session.reportFacts = () => [];
    session.reportSubmitter = (_, _) async => '';
    session.reportPathSalt = 'vault-1';

    // Deliberately NOT awaited: the assertions below run in the same turn, so
    // they see exactly what a racing reload would see.
    final teardown = session.dispose();

    for (final timer in timers) {
      expect(timer.isActive, isFalse, reason: 'armed past its owner');
    }
    expect(session.flushDebounce, isNull);
    expect(session.settingsReloadDebounce, isNull);
    expect(session.selfHealTimer, isNull);
    expect(
      session.reportFacts,
      isNull,
      reason: 'report facts close over this load; the next one builds its own',
    );
    expect(session.reportSubmitter, isNull);
    expect(session.reportPathSalt, isEmpty);

    await teardown;
  });

  test('the log sink stops receiving records', () async {
    final logs = LogController(outputs: []);
    final session = PluginSession(logs: logs);

    // What installLog builds, minus the Obsidian handle it takes the file store
    // from. A Noop store keeps this to the ring, which is all that is being
    // observed.
    final sink = PersistentLogSink(
      store: const NoopLogFileStore(),
      segmentId: 'test',
      memoryCapacity: 16,
    );
    session.logSink = sink;
    logs.addOutput(sink);

    logs.scope('t').info('before');
    final seenBefore = sink.stats.recordsSeen;
    expect(seenBefore, greaterThan(0), reason: 'the sink was never attached');

    await session.dispose();

    logs.scope('t').info('after');
    expect(
      sink.stats.recordsSeen,
      seenBefore,
      reason:
          'a sink still taking records after its load ended is the next '
          "load's boot written into a dead output while its own goes "
          'unrecorded',
    );
    expect(session.logSink, isNull);

    // Note what this does and does not pin down. It observes the outcome —
    // records stop arriving — which `dispose()` currently achieves twice over,
    // by removing the sink from the controller and by disposing it. The
    // controller has no way to ask which outputs it holds, so dropping the
    // removal alone would not show up here. It is the outcome that matters;
    // the redundancy is deliberate and this is the assertion available.
  });

  test('subscriptions, engine, scheduler and database, in that order', () async {
    final session = PluginSession(logs: LogController(outputs: []));
    final order = <String>[];

    final events = StreamController<SyncEngineEvent>.broadcast();
    addTearDown(events.close);
    session.configReconnectSub = events.stream.listen((_) {});
    session.authEventsSub = events.stream.listen((_) {});
    session.deletedVaultWatchSub = events.stream.listen((_) {});
    session.stateLostSub = events.stream.listen((_) {});
    session.flushSub = events.stream.listen((_) {});
    session.selfHealSub = events.stream.listen((_) {});

    final engine = _RecordingEngine(order);
    session.engine = engine;
    session.scheduler = _RecordingScheduler(order);
    final registry = _RecordingConnection(order);
    session.registryConnection = registry;

    final conn = await openInMemoryDb();
    final db = GatedDatabase.wrap(conn);
    session.db = db;

    await session.dispose();

    expect(events.hasListener, isFalse, reason: 'a listener outlived its load');
    expect(
      order,
      ['engine.stop', 'scheduler.dispose', 'registry.dispose'],
      reason:
          'the engine stops before the lane it queues its own shutdown work '
          'on; the other way round, that work has nowhere to run',
    );
    expect(session.engine, isNull);
    expect(session.scheduler, isNull);
    expect(session.db, isNull);
    expect(
      session.registryConnection,
      isNull,
      reason:
          'self-host only, and it used to be a local with the comment "kept '
          'alive" and nothing that closed it',
    );

    // And the connection went with it. A load that leaves its database open
    // holds SQLite's exclusive OPFS handle, and the NEXT load falls back to an
    // in-memory database that starts from an empty vault every launch.
    await expectLater(
      db.dataClient.listCollections(),
      throwsA(anything),
      reason: 'the database outlived the load that opened it',
    );
  });

  test('disposing twice is not an error', () async {
    final session = PluginSession(logs: LogController(outputs: []));
    final engine = _RecordingEngine([]);
    session.engine = engine;

    await session.dispose();
    await session.dispose();

    expect(
      engine.stopCount,
      1,
      reason: 'a second teardown must find nothing left to do',
    );
  });
}

class _RecordingConnection implements SyncConnection {
  _RecordingConnection(this._order);

  final List<String> _order;

  @override
  Future<void> dispose() async => _order.add('registry.dispose');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of teardown',
  );
}

class _RecordingScheduler implements ITaskScheduler {
  _RecordingScheduler(this._order);

  final List<String> _order;

  @override
  Future<void> dispose() async => _order.add('scheduler.dispose');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of teardown',
  );
}

class _RecordingEngine implements ISyncEngine {
  _RecordingEngine(this._order);

  final List<String> _order;
  int stopCount = 0;
  bool get stopped => stopCount > 0;

  @override
  Future<void> stop() async {
    stopCount++;
    _order.add('engine.stop');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    '${invocation.memberName} is not part of teardown',
  );
}
