import 'package:http/http.dart' as http;
import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Configuration for S3-compatible blob storage.
class S3BlobConfig extends ExternalBlobConfig {
  const S3BlobConfig({
    required this.endpoint,
    required this.bucket,
    required this.accessKey,
    required this.secretKey,
    this.region = 'us-east-1',
    this.useSSL = true,
  });

  factory S3BlobConfig.fromJson(Map<String, dynamic> json) => S3BlobConfig(
    endpoint: json['endpoint'] as String,
    bucket: json['bucket'] as String,
    accessKey: json['accessKey'] as String,
    secretKey: json['secretKey'] as String,
    region: json['region'] as String? ?? 'us-east-1',
    useSSL: json['useSSL'] as bool? ?? true,
  );

  final String endpoint;
  final String bucket;
  final String accessKey;
  final String secretKey;
  final String region;
  final bool useSSL;

  @override
  String get kind => 's3';

  @override
  Map<String, dynamic> toJson() => {
    'type': 's3',
    'endpoint': endpoint,
    'bucket': bucket,
    'accessKey': accessKey,
    'secretKey': secretKey,
    'region': region,
    'useSSL': useSSL,
  };

  @override
  IBlobStorage createBlobStorage({
    required String vaultId,
    http.Client? httpClient,
  }) => HttpBlobStorage(
    baseUrl: _normalizeEndpoint('$endpoint/$bucket', useSSL),
    prefix: 'blobs/$vaultId/',
    httpClient: httpClient,
    auth: S3HttpBlobAuth(
      accessKey: accessKey,
      secretKey: secretKey,
      region: region,
    ),
  );
}

/// Configuration for WebDAV blob storage.
class WebDavBlobConfig extends ExternalBlobConfig {
  const WebDavBlobConfig({
    required this.endpoint,
    required this.username,
    required this.password,
    this.useSSL = true,
  });

  factory WebDavBlobConfig.fromJson(Map<String, dynamic> json) =>
      WebDavBlobConfig(
        endpoint: json['endpoint'] as String,
        username: json['username'] as String,
        password: json['password'] as String,
        useSSL: json['useSSL'] as bool? ?? true,
      );

  final String endpoint;
  final String username;
  final String password;
  final bool useSSL;

  @override
  String get kind => 'webdav';

  @override
  Map<String, dynamic> toJson() => {
    'type': 'webdav',
    'endpoint': endpoint,
    'username': username,
    'password': password,
    'useSSL': useSSL,
  };

  @override
  IBlobStorage createBlobStorage({
    required String vaultId,
    http.Client? httpClient,
  }) => HttpBlobStorage(
    baseUrl: _normalizeEndpoint(endpoint, useSSL),
    prefix: 'blobs/$vaultId/',
    httpClient: httpClient,
    auth: BasicHttpBlobAuth(username: username, password: password),
  );
}

Uri _normalizeEndpoint(String endpoint, bool useSSL) {
  var e = endpoint.trim();
  // Strip scheme if user included it.
  if (e.startsWith('https://')) {
    e = e.substring(8);
  } else if (e.startsWith('http://')) {
    e = e.substring(7);
  }
  // Strip trailing slash.
  if (e.endsWith('/')) e = e.substring(0, e.length - 1);
  final scheme = useSSL ? 'https' : 'http';
  return Uri.parse('$scheme://$e/');
}
