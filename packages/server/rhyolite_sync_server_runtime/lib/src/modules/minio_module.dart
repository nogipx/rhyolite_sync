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

  @override
  void configureWithEnv(RpcContainer container, RpcEnvConfig env) {
    _endpoint = env['MINIO_ENDPOINT'] ?? 'localhost';
    _port = env.getInt('MINIO_PORT') ?? 9000;
    _accessKey = env['MINIO_ACCESS_KEY'] ?? 'minioadmin';
    _secretKey = env['MINIO_SECRET_KEY'] ?? 'minioadmin';
    _useSSL = env.getBool('MINIO_USE_SSL');
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
      options: S3BlobStorageOptions(presignRegion: 'local'),
    );
    container.registerSingleton<IBlobClient>(
      IBlobClient.repository(repository: repo),
    );
  }
}
