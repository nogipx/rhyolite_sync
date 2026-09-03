import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob_sqlite/rpc_blob_sqlite.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';

import 'discarding_change_journal.dart';

/// Everything this plugin is allowed to do with its SQLite connection.
///
/// A connection has ONE transaction slot, and more than one component writes
/// to it: the data layer holds the slot across awaits, the blob store takes it
/// synchronously. They must share a gate, and a gate can only be shared if
/// something owns both — so the raw handle is opened, wrapped and dropped
/// here, and the rest of the plugin never sees it.
///
/// That the handle does not escape is the point, not a side effect. The
/// collision this prevents shipped once already with a correct queue in place:
/// the queue lived inside the data client, and the blob store was constructed
/// six lines below it from the same `dbConn.database`. Nothing about that read
/// as wrong, which is why the rule cannot be a rule — it has to be an absence.
///
/// `test/gated_database_guard_test.dart` fails if `.database` appears anywhere
/// in this package outside this file.
class GatedDatabase {
  GatedDatabase._(
    this._connection,
    this.gate,
    this.dataClient,
    this.blobRepository,
  );

  /// Wraps [connection]. After this returns, the caller holds capabilities and
  /// no way back to the handle.
  factory GatedDatabase.wrap(DatabaseConnection connection) {
    final gate = ConnectionGate();
    return GatedDatabase._(
      connection,
      gate,
      SerialisedDataClient(
        IDataClient.repository(
          repository: SqliteDataRepository(
            storage: SqliteDataStorageAdapter.connection(connection),
            // Nothing here reads a change feed, and writing one cost more than
            // everything it sat beside — see [DiscardingChangeJournal].
            changeJournal: DiscardingChangeJournal(),
          ),
        ),
        gate: gate,
      ),
      GatedBlobRepository(
        SqliteBlobRepository.db(connection.database, enableWal: false),
        gate: gate,
      ),
    );
  }

  final DatabaseConnection _connection;

  /// This connection's one gate. Exposed so a test can assert by identity that
  /// both writers below queue on it — see `gated_database_wiring_test.dart`.
  /// Nothing in the plugin needs it: everything that writes here is already
  /// behind it.
  final ConnectionGate gate;

  /// The engine's stores and settings sync both take this one.
  final IDataClient dataClient;

  /// Backs [LocalBlobStore].
  final IBlobRepository blobRepository;

  /// How big this database is, and how much of it is reusable.
  ///
  /// Permanent, and cheap enough to be: three O(1) pragmas read off the header.
  ///
  /// It exists because its absence cost a vault two days. The local blob cache
  /// kept a full second copy of every binary — the file on disk, and its
  /// chunks here — and grew to 1.5 GB with nothing anywhere reporting a size.
  /// At that point the file stopped being able to take another page, and since
  /// a database that cannot grow cannot grow for anybody, the writes that
  /// failed were the ones carrying sync state. What surfaced was sqlite's
  /// generic `SQL logic error` on an unrelated statement, repeated forever.
  ///
  /// The two numbers that would have said so immediately are the size and the
  /// freelist: pages already allocated and free to reuse. A large file with a
  /// freelist of zero is a file one row away from refusing to write.
  /// Which web VFS this database actually opened on, inferred from the path.
  ///
  /// It decides whether [flush] does anything AT ALL. The flush hook drains
  /// the IndexedDB write queue and is a deliberate no-op on OPFS, which writes
  /// through — so on OPFS every durability barrier in this plugin is a
  /// function call that returns. Nothing said which one was in use, and the
  /// difference is the difference between "the barrier did not help" and
  /// "there was no barrier".
  ///
  /// `SimpleOpfsFileSystem` is opened as `/database`; the IndexedDB VFS opens
  /// under the configured file name. That is the only distinguishing fact
  /// visible from this side without a library change.
  Future<String> storageKind() => gate.run(() {
    try {
      final rows = _connection.database.select('PRAGMA database_list');
      for (final r in rows) {
        if (r['name'] != 'main') continue;
        final file = r['file'];
        if (file is! String || file.isEmpty) return 'memory';
        return file.endsWith('/database') ? 'opfs' : 'indexeddb ($file)';
      }
      return 'unknown';
    } catch (e) {
      return 'unknown ($e)';
    }
  });

  Future<String> describe() => gate.run(() {
    int? pragma(String name) {
      try {
        final v = _connection.database.select('PRAGMA $name').first.values.first;
        return v is int ? v : null;
      } catch (_) {
        return null;
      }
    }

    final pageSize = pragma('page_size');
    final pageCount = pragma('page_count');
    final freelist = pragma('freelist_count');
    final bytes = (pageSize != null && pageCount != null)
        ? pageSize * pageCount
        : null;
    final mb = bytes != null
        ? (bytes / (1024 * 1024)).toStringAsFixed(1)
        : '?';
    // Said in megabytes, and only when it is worth saying.
    //
    // `reusable=172745` is a true statement that means nothing to the person
    // reading it: acting on it requires knowing that SQLite keeps freed pages
    // inside the file and that opening one costs its size. Everybody who
    // upgrades with a filled cache lands here — the space comes back, the
    // plugin still takes twenty seconds to start, and nothing connects the
    // two.
    final freeMb = (pageSize is int && freelist is int)
        ? pageSize * freelist / (1024 * 1024)
        : null;
    final worthCompacting =
        pageCount is int && freelist is int && freelist > pageCount / 2;
    return 'db: ${mb}MB ($pageCount pages x $pageSize), '
        'reusable=$freelist pages'
        '${worthCompacting && freeMb != null ? ' — ${freeMb.toStringAsFixed(0)}MB '
            'of this file is empty; compacting would return it' : ''}';
  });

  /// Drops the change-journal table left behind by builds that wrote one.
  ///
  /// Switching to [DiscardingChangeJournal] stops NEW rows. It does not touch
  /// the ones already there, and on one vault those were 22 612 rows and
  /// 106.5 MB — ninety-five per cent of the live database. Compaction would
  /// not have helped: VACUUM rewrites a database compactly and keeps every
  /// row, so it would have packed the dead feed neatly and returned almost
  /// nothing. The rows have to go first, and then the space is worth
  /// reclaiming.
  ///
  /// Reaching into another package's table by name, which is worth saying out
  /// loud. `s_change_journal` belongs to `rpc_data_sqlite`, and the only
  /// reason this is safe is that nothing writes it any more — the repository
  /// is constructed with a journal that keeps nothing. A build that went back
  /// to the SQLite journal would recreate the table on its first write, so
  /// this is reversible rather than destructive.
  ///
  /// Idempotent: after the first run there is no table, and dropping one that
  /// is not there costs nothing. Returns the pages the drop released, or null
  /// if it could not be measured.
  Future<int?> dropLegacyChangeJournal() => gate.run(() {
    int? freelist() {
      try {
        final v = _connection.database
            .select('PRAGMA freelist_count')
            .first
            .values
            .first;
        return v is int ? v : null;
      } catch (_) {
        return null;
      }
    }

    final before = freelist();
    try {
      _connection.database.execute('DROP TABLE IF EXISTS "s_change_journal"');
    } catch (_) {
      return null;
    }
    final after = freelist();
    return (before != null && after != null) ? after - before : null;
  });

  /// The file's size and how much of it is empty, as numbers.
  ///
  /// Separate from [describe] because a panel cannot act on a sentence. Three
  /// O(1) pragmas off the header, so it is cheap enough to ask on every
  /// render.
  Future<({int? fileBytes, int? freeBytes})> stats() => gate.run(() {
    int? pragma(String name) {
      try {
        final v = _connection.database.select('PRAGMA $name').first.values.first;
        return v is int ? v : null;
      } catch (_) {
        return null;
      }
    }

    final pageSize = pragma('page_size');
    final pageCount = pragma('page_count');
    final freelist = pragma('freelist_count');
    return (
      fileBytes: (pageSize != null && pageCount != null)
          ? pageSize * pageCount
          : null,
      freeBytes: (pageSize != null && freelist != null)
          ? pageSize * freelist
          : null,
    );
  });

  /// Rewrites the database so the space it has already freed goes back to the
  /// filesystem, and reports what that cost and what it saved.
  ///
  /// Deleting rows does not shrink a SQLite file: the pages are returned to a
  /// freelist inside it and reused, which is what makes writes work again, and
  /// is invisible from outside. One vault sat at 1462 MB with 1349 MB of that
  /// free — and kept paying twenty-two seconds on every open, because the
  /// IndexedDB VFS holds the file in blocks and opening it costs their number
  /// rather than the live data among them.
  ///
  /// Deliberately not automatic. It rewrites the whole file, wants room for a
  /// second copy while it does, and takes as long as that takes; a boot is the
  /// worst possible moment for all three. The gate is held throughout, so
  /// every other writer waits — correct, since none of them may see the file
  /// mid-rewrite, and the reason this is a user's decision and not a
  /// background chore.
  Future<({int? beforeBytes, int? afterBytes})> compact() => gate.run(() {
    final db = _connection.database;

    int? size() {
      try {
        final page = db.select('PRAGMA page_size').first.values.first;
        final count = db.select('PRAGMA page_count').first.values.first;
        return (page is int && count is int) ? page * count : null;
      } catch (_) {
        return null;
      }
    }

    final before = size();
    // Outside any transaction by construction — VACUUM refuses to run in one,
    // and nothing here opens one.
    db.execute('VACUUM');
    return (beforeBytes: before, afterBytes: size());
  });

  /// A human-readable account of what occupies this database.
  ///
  /// Answers the question the size alone cannot: 1.5 GB of WHAT. Tonight that
  /// took a whole evening to establish by elimination, and the answer — a
  /// second copy of every binary in the vault, held by the blob cache — is one
  /// query away when the query exists.
  ///
  /// Bytes come from `dbstat`, a virtual table that reports the pages each
  /// b-tree actually occupies, indexes counted separately from their table. It
  /// is a compile-time option and may be absent; the row counts below stand on
  /// their own when it is, so a build without it loses the ranking and not the
  /// report.
  ///
  /// Reads only, and no `VACUUM`: this is for looking, and looking should not
  /// rewrite a gigabyte.
  Future<String> report() => gate.run(() {
    final db = _connection.database;
    final out = StringBuffer('# Rhyolite local database\n\n');

    Object? scalar(String sql) {
      try {
        return db.select(sql).first.values.first;
      } catch (_) {
        return null;
      }
    }

    final pageSize = scalar('PRAGMA page_size');
    final pageCount = scalar('PRAGMA page_count');
    final freelist = scalar('PRAGMA freelist_count');
    final bytes = (pageSize is int && pageCount is int)
        ? pageSize * pageCount
        : null;
    out
      ..writeln('- file: ${_mb(bytes)} ($pageCount pages x $pageSize)')
      ..writeln('- reusable: $freelist pages')
      ..writeln();

    // Per-b-tree bytes. Ordered by size because the only question anyone
    // brings here is which one is the big one.
    try {
      final rows = db.select(
        'SELECT name, SUM(pgsize) AS bytes, SUM(ncell) AS cells '
        'FROM dbstat GROUP BY name ORDER BY bytes DESC',
      );
      out
        ..writeln('## By b-tree (table or index)')
        ..writeln()
        ..writeln('| name | size | cells |')
        ..writeln('|---|---|---|');
      for (final r in rows) {
        final b = r['bytes'];
        out.writeln(
          '| ${r['name']} | ${_mb(b is int ? b : null)} | ${r['cells']} |',
        );
      }
      out.writeln();
    } catch (e) {
      out
        ..writeln('## By b-tree')
        ..writeln()
        ..writeln('dbstat unavailable in this build ($e) — row counts only.')
        ..writeln();
    }

    // Row counts, which need no optional feature and are the fallback when
    // dbstat is missing.
    out
      ..writeln('## Rows')
      ..writeln()
      ..writeln('| table | rows |')
      ..writeln('|---|---|');
    try {
      final tables = db
          .select(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name",
          )
          .map((r) => r['name'] as String);
      for (final t in tables) {
        // The name comes from sqlite_master, not from a caller, and is quoted
        // — but it is still interpolation into SQL, so it is worth saying that
        // this is the reason it is safe.
        final n = scalar('SELECT COUNT(*) FROM "$t"');
        out.writeln('| $t | ${n ?? '?'} |');
      }
    } catch (e) {
      out.writeln('| (unreadable) | $e |');
    }

    return out.toString();
  });

  static String _mb(int? bytes) => bytes == null
      ? '?'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  /// Waits until writes have reached durable storage.
  ///
  /// Only the web IndexedDB VFS needs this: it acknowledges a write and
  /// performs it afterwards from a queue, so a tab killed between the two
  /// loses writes the database already reported as committed.
  Future<void> flush() => _connection.flush();

  Future<void> close() => _connection.close();
}
