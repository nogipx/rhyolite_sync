import 'package:rpc_blob/rpc_blob.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_notify/rpc_notify.dart';

import 'package:rhyolite_sync/rhyolite_sync.dart' show StateSyncContractNames;
import 'package:rhyolite_sync_server/rhyolite_sync_server.dart';

import 'minio_module.dart';
import 'postgres_module.dart';
import 'websocket_listener_module.dart';

/// Registers the pure sync responders (state, history, blob, notify).
///
/// These responders are policy-free — auth / subscription / ownership /
/// quota are enforced by interceptors composed in each edition's
/// `bin/server.dart`. Edition-specific responders (e.g. the managed
/// vault-usage responder, which depends on the account contracts) are
/// supplied via [extraContracts] so this module stays edition-agnostic.
class SyncServerModule extends RpcServerModule {
  SyncServerModule({
    List<RpcResponderContract> Function(RpcContainer container)? extraContracts,
  }) : _extraContracts = extraContracts;

  final List<RpcResponderContract> Function(RpcContainer container)?
      _extraContracts;

  @override
  String get name => 'SyncServerModule';

  @override
  List<Type> get dependencies =>
      [PostgresModule, MinioModule, WebSocketListenerModule];

  @override
  List<RpcResponderContract> buildContracts(RpcContainer container) {
    final dataClient = container.get<IDataClient>();
    final blobClient = container.get<IBlobClient>();
    final notifyRepository = container.get<INotifyRepository>();

    final contracts = <RpcResponderContract>[
      RhyoliteBlobResponder(client: blobClient),
      StateSyncResponder(
        client: dataClient,
        blobClient: blobClient,
        notifyRepository: notifyRepository,
      ),
      // Second keyspace for .obsidian settings sync. Same vaultId (so it
      // reuses vault ownership), but isolated collections (<vaultId>_config_*),
      // no history (stays within a single collection), and a distinct service
      // name so it routes independently from the notes sync above.
      StateSyncResponder(
        client: dataClient,
        notifyRepository: notifyRepository,
        namespace: 'config',
        historyEnabled: false,
        serviceNameOverride: StateSyncContractNames.instance('config'),
      ),
      HistoryResponder(client: dataClient),
      NotifySubscribeResponder(
        subscriber: INotifySubscriber.repository(notifyRepository),
      ),
    ];

    final extras = _extraContracts?.call(container);
    if (extras != null) contracts.addAll(extras);

    return contracts;
  }
}
