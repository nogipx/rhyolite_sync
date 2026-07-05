import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:rpc_notify/rpc_notify.dart';

/// Registers an in-process [INotifyRepository].
///
/// Correct for single-process editions (self-host): notify only needs to fan
/// out to the devices connected to THIS process, which is pure in-memory. No
/// broker, no network leg — so it cannot suffer the idle-connection push loss
/// that a Postgres/Redis-backed repository must actively guard against.
///
/// Do NOT use with more than one sync-server replica: an in-memory repository
/// does not fan out across processes. Multi-replica fan-out is a managed-only
/// capability (a Redis-backed notify module in the closed managed package), so
/// the open runtime intentionally ships only this single-replica backend.
class InMemoryNotifyModule extends RpcModule {
  @override
  String get name => 'InMemoryNotifyModule';

  InMemoryNotifyRepository? _notify;

  @override
  Future<void> onStart(RpcContainer container) async {
    _notify = InMemoryNotifyRepository();
    container.registerSingleton<INotifyRepository>(_notify!);
  }

  @override
  Future<void> onStop() async {
    await _notify?.dispose();
  }
}
