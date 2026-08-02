import 'package:rpc_blob_minio/rpc_blob_minio.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';

class MinioModule extends RpcModule {
  @override
  String get name => 'MinioModule';

  late String _endpoint;
  late int _port;
  late String _accessKey;
  late String _secretKey;
  late bool _useSSL;
  late String _bucket;

  @override
  void configureWithEnv(RpcContainer container, RpcEnvConfig env) {
    _endpoint = env['MINIO_ENDPOINT'] ?? 'localhost';
    _port = env.getInt('MINIO_PORT') ?? 9000;
    _accessKey = env['MINIO_ACCESS_KEY'] ?? 'minioadmin';
    _secretKey = env['MINIO_SECRET_KEY'] ?? 'minioadmin';
    _useSSL = env.getBool('MINIO_USE_SSL');
    // One bucket for every vault; a vault is a key prefix inside it. A bucket
    // per vault does not survive a move to a hosted S3, where accounts are
    // capped on bucket count and creating one is a heavyweight operation.
    _bucket = env['MINIO_BUCKET'] ?? 'rhyolite-blobs';
  }

  @override
  Future<void> onStart(RpcContainer container) async {
    final repo = S3BlobRepository.connect(
      endPoint: _endpoint,
      port: _port,
      accessKey: _accessKey,
      secretKey: _secretKey,
      useSSL: _useSSL,
      pathStyle: true,
      options: S3BlobStorageOptions(
        bucket: _bucket,
        presignRegion: 'local',
        // Blob ids are content hashes, so an object never changes under its
        // id: no read before a write to carry a version forward.
        immutableObjects: true,
        // Clients fetch blobs through this server, never straight from the
        // bucket — so the bucket is private, and saying so keeps the adapter
        // from asking it once per descriptor it builds.
        publicRead: false,
      ),
    );
    container.registerSingleton<IBlobClient>(
      IBlobClient.repository(repository: repo),
    );
  }
}
