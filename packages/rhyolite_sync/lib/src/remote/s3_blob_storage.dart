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
  }) {
    final baseUrl = _normalizeEndpoint('$endpoint/$bucket', useSSL);
    _assertCredentialTransportSecure(baseUrl, useSSL);
    return HttpBlobStorage(
      baseUrl: baseUrl,
      prefix: 'blobs/$vaultId/',
      httpClient: httpClient,
      auth: S3HttpBlobAuth(
        accessKey: accessKey,
        secretKey: secretKey,
        region: region,
      ),
    );
  }
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
  }) {
    final baseUrl = _normalizeEndpoint(endpoint, useSSL);
    _assertCredentialTransportSecure(baseUrl, useSSL);
    return HttpBlobStorage(
      baseUrl: baseUrl,
      prefix: 'blobs/$vaultId/',
      httpClient: httpClient,
      auth: BasicHttpBlobAuth(username: username, password: password),
    );
  }
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
  final uri = Uri.parse('$scheme://$e/');
  if (isBlockedBlobHost(uri.host)) {
    throw ArgumentError(
      'External storage endpoint host "${uri.host}" is not allowed '
      '(cloud-metadata / loopback address).',
    );
  }
  return uri;
}

/// Blocks the clearly-dangerous SSRF targets for a user-supplied BYO endpoint —
/// cloud metadata (169.254.169.254 / link-local), loopback, and localhost —
/// while deliberately ALLOWING private LAN ranges (10/172.16/192.168), since a
/// self-hosted S3/MinIO/WebDAV on a LAN is a legitimate BYO target. dart2js-safe
/// (pure string checks; no dart:io / InternetAddress). Package-public for tests.
bool isBlockedBlobHost(String host) {
  var h = host.toLowerCase().trim();
  if (h.startsWith('[') && h.contains(']')) {
    h = h.substring(1, h.indexOf(']')); // unwrap [::1]
  }
  if (h.isEmpty || h == 'localhost' || h.endsWith('.localhost')) return true;
  if (h == '0.0.0.0' || h == '::' || h == '::1') return true;
  if (h.startsWith('127.')) return true; // loopback
  if (h.startsWith('169.254.')) return true; // link-local incl. metadata
  if (h.startsWith('fe80') || h.startsWith('::ffff:127.')) return true; // v6
  return false;
}

/// RFC-1918 private-LAN host — the user's own trusted network, where plaintext
/// http with credentials is their call. Public hosts are not. dart2js-safe.
/// Package-public for tests.
bool isPrivateLanHost(String host) {
  var h = host.toLowerCase().trim();
  if (h.startsWith('[') && h.contains(']')) {
    h = h.substring(1, h.indexOf(']'));
  }
  if (h.startsWith('10.') || h.startsWith('192.168.')) return true;
  final m = RegExp(r'^172\.(\d{1,3})\.').firstMatch(h);
  if (m != null) {
    final second = int.tryParse(m.group(1)!) ?? -1;
    if (second >= 16 && second <= 31) return true;
  }
  return false;
}

/// Refuses to carry credentials over plaintext http:// to a PUBLIC host — the
/// password (WebDAV Basic) or the signed request + all data (S3) would be
/// exposed to anyone on the path. Allowed to a private-LAN host (the user's own
/// trusted network). Loopback/metadata are already rejected by [_normalizeEndpoint].
void _assertCredentialTransportSecure(Uri uri, bool useSSL) {
  if (!useSSL && !isPrivateLanHost(uri.host)) {
    throw ArgumentError(
      'Refusing to send credentials over plaintext http:// to public host '
      '"${uri.host}". Use https, or a private-LAN endpoint.',
    );
  }
}
