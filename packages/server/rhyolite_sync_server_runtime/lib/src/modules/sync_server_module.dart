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
      // dataClient enables the backup delete-guard: a client-driven blob delete
      // is refused for chunks a retained snapshot pins. No-op without backups
      // (self-host / free), so it's safe in the shared module.
      RhyoliteBlobResponder(client: blobClient, dataClient: dataClient),
      // Orphan-blob sweep: reads state + history to build the live set, lists
      // the shared blob bucket, reclaims the difference (dry-run by default).
      RhyoliteVaultMaintenanceResponder(
        dataClient: dataClient,
        blobClient: blobClient,
      ),
      StateSyncResponder(
        client: dataClient,
        blobClient: blobClient,
        notifyRepository: notifyRepository,
        // OOM guard: notes records are tiny manifests; the cap only bounds the
        // opaque-ciphertext vector. Over-cap items are rejected per-item.
        recordSizeLimit: 5 << 20,
        // Whole-batch DoS caps — generous vs any real first-sync (manifests are
        // KB-scale), tight vs the GiB-batch OOM attack. A transport-level
        // max-message-size + client-side batch chunking are the complementary
        // complete fix (deserialization happens before the responder runs).
        maxBatchItems: 100000,
        maxBatchBytes: 64 << 20,
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
        // Settings records are KB-scale even with whole-file inlining; keep a
        // tighter cap than notes.
        recordSizeLimit: 3 << 20,
        // Fewer settings resources than notes → a tighter batch bound.
        maxBatchItems: 10000,
        maxBatchBytes: 32 << 20,
      ),
      HistoryResponder(client: dataClient),
      // Read-only backup access (notes keyspace). Snapshots are captured by the
      // managed edition; self-host simply has none, so this lists empty.
      RhyoliteBackupResponder(dataClient: dataClient),
      NotifySubscribeResponder(
        subscriber: INotifySubscriber.repository(notifyRepository),
      ),
    ];

    final extras = _extraContracts?.call(container);
    if (extras != null) contracts.addAll(extras);

    return contracts;
  }
}
