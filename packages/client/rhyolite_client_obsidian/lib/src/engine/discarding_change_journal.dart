import 'package:rpc_data/rpc_data.dart';

/// A change journal that keeps nothing, for a client that reads nothing.
///
/// `rpc_data` records every write to a second table so a consumer can replay
/// what changed. This plugin has no such consumer: `watchChanges` is passed
/// through by `SerialisedDataClient` and called by nobody, and a sync engine
/// learns what changed from the server's cursor and from disk, never from a
/// local feed.
///
/// It was not free. On one vault the journal measured 106.5 MB against 1.4 MB
/// of actual sync state and 2.2 MB of Fugue trees — ninety-five per cent of
/// the live database, holding a replay nothing would ever ask for. Its
/// retention (5000 events, seven days) had not kept up: 22 612 rows were
/// present. And because the write lands AFTER the record's own transaction
/// commits, every state update paid for a second, non-atomic write to produce
/// it.
///
/// The SQLite journal is also what made the failure visible in the first
/// place: with the database full, `INSERT INTO s_change_journal` was the
/// statement that failed, and it took an evening to establish that the row it
/// could not write was one nobody wanted.
///
/// Events are still returned, because callers use the returned cursor — they
/// are just never stored. [replayCollection] is consequently always empty,
/// which is the honest answer for a journal that keeps nothing rather than a
/// lie about having lost it.
class DiscardingChangeJournal implements DataChangeJournal {
  DiscardingChangeJournal();

  /// Monotonic within a session, so two events in one run never share a
  /// cursor. It does not survive a restart and does not need to: nothing
  /// compares cursors across sessions, and nothing replays.
  int _seq = 0;

  @override
  Future<DataChangeEvent> recordChange({
    required DataChangeType type,
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
    DataRecord? record,
  }) async => DataChangeEvent(
    type: type,
    collection: collection,
    id: id,
    record: record,
    version: version,
    cursor: '${++_seq}',
    occurredAt: occurredAt,
  );

  @override
  Future<DataChangeEvent> recordDeletion({
    required String collection,
    required String id,
    required int version,
    required DateTime occurredAt,
  }) async => DataChangeEvent(
    type: DataChangeType.deleted,
    collection: collection,
    id: id,
    version: version,
    cursor: '${++_seq}',
    occurredAt: occurredAt,
  );

  @override
  Future<List<DataChangeEvent>> replayCollection(
    String collection, {
    String? afterCursor,
  }) async => const [];

  @override
  Future<void> prune({
    required String collection,
    int? maxEvents,
    DateTime? retainAfter,
  }) async {}

  @override
  Future<void> purgeCollection(String collection) async {}

  @override
  Future<void> dispose() async {}
}
