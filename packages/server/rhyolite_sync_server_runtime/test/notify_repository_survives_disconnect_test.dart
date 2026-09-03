// The notify bus belongs to the application, not to whichever client happens
// to disconnect first.
//
// `buildContracts` runs once per connection while `INotifyRepository` is a
// singleton the notify module registered at boot, and rpc_dart disposes a
// connection's contracts when its endpoint closes. A contract that disposed
// the repository therefore ended notify for the whole process at the first
// disconnect — every replica held no Redis connection, retried nothing and
// logged nothing. This pins our side of that: whatever contracts we build per
// connection, the shared repository must outlive them.

import 'package:rhyolite_sync_server_runtime/rhyolite_sync_server_runtime.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_notify/rpc_notify.dart';
import 'package:test/test.dart';

/// The module only constructs responders, so nothing here is ever called.
/// Anything that does call it should fail loudly rather than silently pass.
class _UnusedDataClient implements IDataClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of '
    'building contracts',
  );
}

class _UnusedBlobClient implements IBlobClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of '
    'building contracts',
  );
}

void main() {
  test(
    'a connection\'s contracts do not take the notify bus with them',
    () async {
      final shared = InMemoryNotifyRepository();
      addTearDown(shared.dispose);

      final container = RpcContainer()
        ..registerSingleton<IDataClient>(_UnusedDataClient())
        ..registerSingleton<IBlobClient>(_UnusedBlobClient())
        ..registerSingleton<INotifyRepository>(shared);

      // Another client, already connected and subscribed.
      final received = <NotifyEvent>[];
      var closed = false;
      shared
          .subscribe('another-connection', 'vault:x')
          .listen(received.add, onDone: () => closed = true);

      // One connection arrives, gets its own contracts, and drops.
      final contracts = SyncServerModule().buildContracts(container);
      expect(
        contracts.whereType<NotifySubscribeResponder>(),
        hasLength(1),
        reason: 'the notify contract is the one this test is about',
      );
      // Exactly what rpc_dart does on endpoint close: fire-and-forget, the
      // base contract's dispose returns void.
      for (final contract in contracts) {
        contract.dispose();
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      shared.publish('vault:x', {'n': 1});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        closed,
        isFalse,
        reason: 'a disconnect closed a stream it did not own',
      );
      expect(
        received,
        hasLength(1),
        reason: 'one client disconnecting ended notify for everyone else',
      );
    },
  );
}
