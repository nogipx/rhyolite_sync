import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:rpc_dart/rpc_dart.dart';

import '../gated_database.dart';

/// Where the vault's SQLite file lives.
///
/// The suffix comes from `data.json` and exists for recovery: a database that
/// will not open is renamed out of the way by bumping it, rather than deleted.
/// Both names are needed by the corruption modal, which tells the user what to
/// remove, so they are computed once here and carried rather than rebuilt from
/// the same three inputs in two places.
class DatabaseNames {
  const DatabaseNames({required this.fileName, required this.databaseName});

  factory DatabaseNames.forVault(String vaultId, {String suffix = ''}) {
    final tail = suffix.isNotEmpty ? '-$suffix' : '';
    return DatabaseNames(
      fileName: '$vaultId$tail.db',
      databaseName: 'rhyolite-$vaultId$tail',
    );
  }

  final String fileName;
  final String databaseName;
}

/// How long each half of the open took, and whether durability was granted.
///
/// Split because one number could not be acted on. A user reporting 44 seconds
/// in `boot: openFileDb` said only that something in the stretch was slow — the
/// persistence grant (which can prompt), the VFS probe, or reading a database
/// that has grown to hold a gigabyte of cached blobs. Three different fixes.
class DatabaseBoot {
  const DatabaseBoot({
    required this.db,
    required this.names,
    required this.durable,
    required this.persistMs,
    required this.openMs,
  });

  final GatedDatabase db;
  final DatabaseNames names;

  /// False when the browser refused a durable bucket and the open fell back.
  /// Nothing persists past the session in that state, which the user is told.
  final bool durable;

  final int persistMs;
  final int openMs;

  int get totalMs => persistMs + openMs;
}

/// Opens the vault database and hands back capabilities, never the handle.
///
/// [requestPersistence] runs first and is awaited: everything this plugin keeps
/// — FileState registers, the pull cursor, Fugue trees, the local blob cache —
/// is one SQLite file in WebView origin storage. Without a persistence grant
/// that storage is best-effort and the OS may evict it while Obsidian sits
/// unused; the next launch then starts from cursor 0 and re-downloads the
/// vault.
///
/// The first open refuses the library's silent in-memory fallback. In-memory
/// looks exactly like a working-but-empty database: sync runs, pulls the whole
/// vault from cursor 0, writes it into RAM, and does it again next launch —
/// without a line saying why. Not fatal, though. On a device with neither OPFS
/// nor IndexedDB, refusing to open at all would just mean no sync, so the
/// second attempt takes the fallback deliberately and [onFallback] warns that
/// nothing will persist.
Future<DatabaseBoot> openVaultDatabase({
  required DatabaseNames names,
  required Uri wasmUri,
  required Future<void> Function() requestPersistence,
  required void Function(Object error) onFallback,
  required LogScope log,
  Future<DatabaseConnection> Function(SqliteConnectionOptions options)? open,
}) async {
  final opener = open ?? (o) => openFileDb(options: o);

  final persistSw = Stopwatch()..start();
  await requestPersistence();
  persistSw.stop();

  final openSw = Stopwatch()..start();
  var durable = true;
  DatabaseConnection connection;
  try {
    connection = await opener(
      SqliteConnectionOptions(
        webDatabaseName: names.databaseName,
        webFileName: names.fileName,
        webSqliteWasmUri: wasmUri,
        webRequireDurableStorage: true,
      ),
    );
  } on DurableWebStorageUnavailable catch (e) {
    log.error('boot: no durable storage for the sync database: $e');
    durable = false;
    onFallback(e);
    connection = await opener(
      SqliteConnectionOptions(
        webDatabaseName: names.databaseName,
        webFileName: names.fileName,
        webSqliteWasmUri: wasmUri,
      ),
    );
  }
  openSw.stop();

  // The handle is wrapped and dropped here. Everything past this line holds
  // capabilities: a gated data client and a gated blob repository sharing one
  // gate, because the connection has one transaction slot and both write to it.
  //
  // Keeping `.database` out of reach is the enforcement, not a nicety — the
  // same collision shipped once with a correct queue in place, because the
  // queue was inside one writer and the other was built from the raw handle six
  // lines below it.
  final boot = DatabaseBoot(
    db: GatedDatabase.wrap(connection),
    names: names,
    durable: durable,
    persistMs: persistSw.elapsedMilliseconds,
    openMs: openSw.elapsedMilliseconds,
  );
  log.info(
    'boot: openFileDb ${boot.totalMs}ms '
    '(persist ${boot.persistMs}ms, open ${boot.openMs}ms)',
  );
  return boot;
}
