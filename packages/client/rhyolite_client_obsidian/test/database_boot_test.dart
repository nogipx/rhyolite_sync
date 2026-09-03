@TestOn('vm')
library;

import 'package:rhyolite_client_obsidian/src/engine/boot/database_boot.dart';
import 'package:rpc_data_sqlite/rpc_data_sqlite.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Opening the vault database, and the fallback nobody could reach.
//
// The durability fallback is the interesting half. It only runs on a device
// with neither OPFS nor a usable IndexedDB, which is not a device anyone here
// has — so the branch that decides whether a user syncs into RAM for the rest
// of the session, silently, had never been executed outside the field.
// ---------------------------------------------------------------------------

final _log = LogController(outputs: []).scope('test');
final _wasm = Uri.parse('app://obsidian.md/sqlite3mc.wasm');

void main() {
  group('names', () {
    test('a plain vault gets a plain pair', () {
      final names = DatabaseNames.forVault('vault-1');
      expect(names.fileName, 'vault-1.db');
      expect(names.databaseName, 'rhyolite-vault-1');
    });

    test('the recovery suffix moves both, together', () {
      // Recovery renames a database that will not open out of the way by
      // bumping the suffix. Moving one name and not the other would point the
      // VFS at one file and the connection at another.
      final names = DatabaseNames.forVault('vault-1', suffix: '2');
      expect(names.fileName, 'vault-1-2.db');
      expect(names.databaseName, 'rhyolite-vault-1-2');
    });

    test('an empty suffix adds no separator', () {
      expect(DatabaseNames.forVault('v', suffix: '').fileName, 'v.db');
    });
  });

  group('open', () {
    test('persistence is requested before the database is touched', () async {
      final order = <String>[];
      await openVaultDatabase(
        names: DatabaseNames.forVault('v'),
        wasmUri: _wasm,
        requestPersistence: () async => order.add('persist'),
        onFallback: (_) {},
        log: _log,
        open: (options) async {
          order.add('open');
          return openInMemoryDb();
        },
      );

      expect(
        order,
        ['persist', 'open'],
        reason:
            'a bucket granted after the file exists does not protect what is '
            'already in it, and the OS is free to evict it meanwhile',
      );
    });

    test('the first attempt refuses a silent in-memory fallback', () async {
      final seen = <bool?>[];
      final boot = await openVaultDatabase(
        names: DatabaseNames.forVault('v'),
        wasmUri: _wasm,
        requestPersistence: () async {},
        onFallback: (_) {},
        log: _log,
        open: (options) async {
          seen.add(options.webRequireDurableStorage);
          return openInMemoryDb();
        },
      );

      expect(
        seen,
        [true],
        reason:
            'in-memory looks exactly like a working-but-empty database: sync '
            'pulls the whole vault from cursor 0 into RAM and does it again '
            'next launch, without a line saying why',
      );
      expect(boot.durable, isTrue);
    });

    test('and takes it deliberately, once, when there is no other', () async {
      final durabilityAsked = <bool?>[];
      var warned = 0;

      final boot = await openVaultDatabase(
        names: DatabaseNames.forVault('v'),
        wasmUri: _wasm,
        requestPersistence: () async {},
        onFallback: (_) => warned++,
        log: _log,
        open: (options) async {
          durabilityAsked.add(options.webRequireDurableStorage);
          if (options.webRequireDurableStorage == true) {
            throw const DurableWebStorageUnavailable('no OPFS', 'no IndexedDB');
          }
          return openInMemoryDb();
        },
      );

      // The second attempt asks for the fallback explicitly (the option
      // defaults to false when omitted), so the two calls are distinguishable
      // — a retry that asked for durability again would loop.
      expect(durabilityAsked, [true, false]);
      expect(
        warned,
        1,
        reason:
            'nothing persists past this session, and a user not told that '
            'reports it as "sync keeps re-downloading my vault"',
      );
      expect(
        boot.durable,
        isFalse,
        reason: 'the caller has to be able to say so afterwards',
      );
      expect(boot.db, isNotNull, reason: 'no sync at all would be worse');
    });

    test('a failure that is not about durability is not swallowed', () async {
      // Throws once, then succeeds. A catch-all would take the fallback, get a
      // working database on the retry and return happily — so a fake that
      // always throws could not tell the two apart.
      var attempts = 0;
      await expectLater(
        openVaultDatabase(
          names: DatabaseNames.forVault('v'),
          wasmUri: _wasm,
          requestPersistence: () async {},
          onFallback: (_) {},
          log: _log,
          open: (_) async {
            if (attempts++ == 0) throw StateError('wasm blocked by CSP');
            return openInMemoryDb();
          },
        ),
        throwsA(isA<StateError>()),
        reason:
            'only a durability refusal earns a second attempt; retrying past '
            'anything else hides the first reason behind the second',
      );
      expect(attempts, 1, reason: 'there was no second attempt to make');
    });

    test('the two halves are timed apart', () async {
      final boot = await openVaultDatabase(
        names: DatabaseNames.forVault('v'),
        wasmUri: _wasm,
        requestPersistence: () =>
            Future<void>.delayed(const Duration(milliseconds: 40)),
        onFallback: (_) {},
        log: _log,
        open: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return openInMemoryDb();
        },
      );

      // One number could not be acted on: 44 seconds in `boot: openFileDb`
      // said only that something in the stretch was slow. The grant can
      // prompt, the VFS probe can stall, and a database holding a gigabyte of
      // cached blobs is simply large — three different fixes.
      expect(boot.persistMs, greaterThanOrEqualTo(30));
      expect(boot.openMs, greaterThanOrEqualTo(15));
      expect(boot.openMs, lessThan(boot.persistMs + 100));
      expect(boot.totalMs, boot.persistMs + boot.openMs);
    });
  });
}
