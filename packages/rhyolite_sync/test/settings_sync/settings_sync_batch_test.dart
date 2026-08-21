import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/settings_sync/resource_crdt_codec.dart';
import 'package:rhyolite_sync/src/settings_sync/settings_store.dart';
import 'package:rhyolite_sync/src/settings_sync/settings_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

import '../support/identity_cipher.dart';

const _vaultId = '00000000-0000-4000-8000-000000000042';

/// Counts what actually reaches the wire. The point of the batch is that N
/// changed resources cost ONE request, so the item counts per call are the
/// whole assertion.
class _CountingRemote implements IStateSyncContract {
  final List<List<String>> pushes = [];
  final List<({int items, int bytes})> byteSizes = [];
  final List<StatePutItem> sent = [];
  int seq = 0;

  /// Refuses any item whose encrypted payload is at least this big, the way the
  /// server's `recordSizeLimit` does.
  int? rejectAtLeastBytes;

  /// Fails the next call outright, the way a dropped connection does.
  bool failNext = false;

  @override
  Future<StatePutResponse> putStates(StatePutRequest request,
      {RpcContext? context}) async {
    if (failNext) {
      failNext = false;
      throw StateError('connection dropped');
    }
    pushes.add([for (final i in request.items) i.fileId]);
    byteSizes.add((
      items: request.items.length,
      bytes: request.items.fold(0, (n, i) => n + i.encryptedState.length),
    ));
    sent.addAll(request.items);
    final limit = rejectAtLeastBytes;
    return StatePutResponse(
      results: [
        for (final i in request.items)
          if (limit != null && i.encryptedState.length >= limit)
            StatePutResult(
              fileId: i.fileId,
              serverSeq: 0,
              rejection: StatePutRejection(
                code: 'state_size',
                current: i.encryptedState.length,
                limit: limit,
              ),
            )
          else
            StatePutResult(fileId: i.fileId, serverSeq: ++seq),
      ],
      cursor: seq,
      epoch: 0,
    );
  }

  @override
  Future<StateGetResponse> getStates(StateGetRequest request,
          {RpcContext? context}) async =>
      StateGetResponse(records: const [], cursor: seq, epoch: 0);

  @override
  Future<StateWipeResponse> wipeVault(StateWipeRequest request,
          {RpcContext? context}) async =>
      const StateWipeResponse(epoch: 1);

  @override
  Future<StatePurgeResponse> purgeVault(StatePurgeRequest request,
          {RpcContext? context}) async =>
      const StatePurgeResponse();
}

Uint8List _json(Map<String, Object?> m) =>
    Uint8List.fromList(utf8.encode(jsonEncode(m)));

void main() {
  late _CountingRemote remote;
  late SettingsSync sync;

  setUp(() async {
    final env = await DataServiceFactory.inMemory();
    addTearDown(env.dispose);
    final store = SettingsStore(client: env.client, vaultId: _vaultId);
    await store.load();
    remote = _CountingRemote();
    sync = SettingsSync(
      remote: remote,
      store: store,
      cipher: IdentityCipher(),
      vaultId: _vaultId,
      kindOf: (_) => SettingsCrdtKind.jsonWholeFile,
    );
  });

  test('without a batch, every resource costs its own request', () async {
    for (var i = 0; i < 5; i++) {
      await sync.applyLocalChange('r$i.json', _json({'k': i}));
    }
    expect(remote.pushes.length, 5,
        reason: 'this is the behaviour the batch exists to replace');
  });

  test('a batch sends every changed resource in ONE request', () async {
    await sync.batched(() async {
      for (var i = 0; i < 5; i++) {
        await sync.applyLocalChange('r$i.json', _json({'k': i}));
      }
    });
    expect(remote.pushes.length, 1);
    expect(remote.pushes.single.length, 5);
  });

  test('an unchanged resource is not pushed at all', () async {
    await sync.batched(() async {
      await sync.applyLocalChange('a.json', _json({'k': 1}));
    });
    remote.pushes.clear();
    await sync.batched(() async {
      // Same bytes: diffApply yields the identical state, so nothing is owed.
      await sync.applyLocalChange('a.json', _json({'k': 1}));
    });
    expect(remote.pushes, isEmpty);
  });

  test('a throw inside the batch still publishes what already changed',
      () async {
    await expectLater(
      sync.batched(() async {
        await sync.applyLocalChange('a.json', _json({'k': 1}));
        await sync.applyLocalChange('b.json', _json({'k': 2}));
        throw StateError('a malformed file blew up mid-scan');
      }),
      throwsStateError,
    );
    expect(remote.pushes.length, 1,
        reason: 'deferring a push must never be able to lose a write');
    expect(remote.pushes.single.length, 2);
  });

  test('nesting is safe — only the outermost section flushes', () async {
    await sync.batched(() async {
      await sync.applyLocalChange('a.json', _json({'k': 1}));
      await sync.batched(() async {
        await sync.applyLocalChange('b.json', _json({'k': 2}));
      });
      expect(remote.pushes, isEmpty, reason: 'the inner section must not send');
      await sync.applyLocalChange('c.json', _json({'k': 3}));
    });
    expect(remote.pushes.length, 1);
    expect(remote.pushes.single.length, 3);
  });

  test('a batch never exceeds the cap, even when a huge state follows small '
      'ones', () async {
    // The ordering that breaks a check made AFTER adding: fill the batch to
    // just under the cap with small resources, then hand it one big state.
    final big = List.filled(900 * 1024, 'x').join();
    await sync.batched(() async {
      for (var i = 0; i < 6; i++) {
        await sync.applyLocalChange('small$i.json', _json({'v': 'y' * 100000}));
      }
      await sync.applyLocalChange('big.json', _json({'v': big}));
    });
    for (final push in remote.byteSizes) {
      // One item may exceed the cap on its own — nothing can be done about
      // that. A batch of several must not.
      if (push.items > 1) {
        expect(push.bytes, lessThanOrEqualTo(1 << 20),
            reason: 'a multi-item request must stay under the cap');
      }
    }
    expect(remote.pushes.expand((p) => p).length, 7);
  });

  test('a single state larger than the cap is sent alone, not dropped',
      () async {
    final huge = List.filled(2 * 1024 * 1024, 'x').join();
    await sync.batched(() async {
      await sync.applyLocalChange('a.json', _json({'k': 1}));
      await sync.applyLocalChange('huge.json', _json({'v': huge}));
      await sync.applyLocalChange('b.json', _json({'k': 2}));
    });
    final hugePush =
        remote.byteSizes.firstWhere((p) => p.bytes > (1 << 20));
    expect(hugePush.items, 1, reason: 'it must not drag siblings over the cap');
    expect(remote.pushes.expand((p) => p).length, 3,
        reason: 'and every resource must still be sent');
  });

  test('an oversized batch is split rather than sent as one huge request',
      () async {
    // Each state is ~200 KB, so the 1 MiB cap forces more than one request.
    final big = List.filled(200 * 1024, 'x').join();
    await sync.batched(() async {
      for (var i = 0; i < 8; i++) {
        await sync.applyLocalChange('big$i.json', _json({'v': big}));
      }
    });
    expect(remote.pushes.length, greaterThan(1),
        reason: 'the request itself must stay bounded');
    expect(remote.pushes.expand((p) => p).length, 8,
        reason: 'and every resource must still be sent exactly once');
  });

  group('the server refusing an item', () {
    test('does not stop its accepted siblings from being committed', () async {
      remote.rejectAtLeastBytes = 500 * 1024;
      final huge = List.filled(600 * 1024, 'x').join();
      await sync.batched(() async {
        await sync.applyLocalChange('ok1.json', _json({'k': 1}));
        await sync.applyLocalChange('big.json', _json({'v': huge}));
        await sync.applyLocalChange('ok2.json', _json({'k': 2}));
      });
      final ids = remote.pushes.expand((p) => p).toSet();
      expect(ids.length, 3, reason: 'all three were attempted');

      // The accepted two are settled; only the refused one is still owed.
      remote.rejectAtLeastBytes = null;
      remote.pushes.clear();
      await sync.batched(() async {
        await sync.applyLocalChange('ok1.json', _json({'k': 1}));
      });
      expect(remote.pushes, isEmpty,
          reason: 'an accepted resource must not be re-sent');
    });

    test('is reported rather than swallowed', () async {
      final logged = <String>[];
      final env = await DataServiceFactory.inMemory();
      addTearDown(env.dispose);
      final store = SettingsStore(client: env.client, vaultId: _vaultId);
      await store.load();
      final remote2 = _CountingRemote()..rejectAtLeastBytes = 1024;
      final sync2 = SettingsSync(
        remote: remote2,
        store: store,
        cipher: IdentityCipher(),
        vaultId: _vaultId,
        kindOf: (_) => SettingsCrdtKind.jsonWholeFile,
        log: logged.add,
      );
      await sync2.batched(() async {
        await sync2.applyLocalChange(
            'big.json', _json({'v': List.filled(4096, 'x').join()}));
      });
      expect(logged.where((l) => l.contains('server refused')), isNotEmpty);
      expect(logged.join(), contains('state_size'));
    });

    test('does not claim the write: the next push carries the same context',
        () async {
      remote.rejectAtLeastBytes = 1024;
      final big = List.filled(4096, 'x').join();
      await sync.batched(() async {
        await sync.applyLocalChange('big.json', _json({'v': big}));
      });
      final firstContext = remote.sent.single.contextPacked;

      // A NEW version of the same resource — the block is keyed on the payload,
      // so this must be attempted rather than skipped forever.
      remote.sent.clear();
      await sync.batched(() async {
        await sync.applyLocalChange('big.json', _json({'v': '${big}more'}));
      });
      expect(remote.sent, hasLength(1),
          reason: 'a changed payload must be retried, not blocked');
      expect(remote.sent.single.contextPacked, firstContext,
          reason: 'the refused write must not have advanced what we claim to '
              'have seen');
    });

    test('the same refused payload is not sent again', () async {
      remote.rejectAtLeastBytes = 1024;
      final big = List.filled(4096, 'x').join();
      await sync.batched(() async {
        await sync.applyLocalChange('big.json', _json({'v': big}));
      });
      expect(remote.pushes, hasLength(1));

      // pull() re-pushes anything it saw concurrent versions of; here it stands
      // in for any path that asks to publish the resource again unchanged.
      remote.pushes.clear();
      await sync.batched(() async {
        await sync.applyLocalChange('other.json', _json({'k': 1}));
      });
      final resent = remote.pushes.expand((p) => p).length;
      expect(resent, 1, reason: 'only the new resource, not the refused one');
    });
  });

  group('a push that fails outright', () {
    test('leaves the resources owed, so the next batch retries them', () async {
      remote.failNext = true;
      await expectLater(
        sync.batched(() async {
          await sync.applyLocalChange('a.json', _json({'k': 1}));
          await sync.applyLocalChange('b.json', _json({'k': 2}));
        }),
        throwsA(isA<StateError>()),
      );
      expect(remote.pushes, isEmpty, reason: 'nothing reached the server');

      // A later scan that touches something else must carry the two that never
      // made it. Otherwise the change is on disk, marked as scanned, and owed
      // to nobody — silently unsynced until the file is edited again.
      await sync.batched(() async {
        await sync.applyLocalChange('c.json', _json({'k': 3}));
      });
      final sent = remote.pushes.expand((p) => p).toSet();
      expect(sent.length, 3,
          reason: 'a.json and b.json must be retried alongside c.json');
    });
  });
}
