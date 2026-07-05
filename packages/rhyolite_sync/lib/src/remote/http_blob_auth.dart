import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Generates auth headers for HTTP blob requests.
abstract interface class IHttpBlobAuth {
  Map<String, String> sign(String method, Uri uri, Uint8List? body);
}

/// HTTP Basic authentication (username:password).
/// Used by most WebDAV servers.
class BasicHttpBlobAuth implements IHttpBlobAuth {
  BasicHttpBlobAuth({required this.username, required this.password});

  final String username;
  final String password;

  @override
  Map<String, String> sign(String method, Uri uri, Uint8List? body) => {
        'authorization': 'Basic ${base64Encode(utf8.encode('$username:$password'))}',
      };
}

/// HTTP Bearer token authentication.
class BearerHttpBlobAuth implements IHttpBlobAuth {
  BearerHttpBlobAuth({required this.token});

  final String token;

  @override
  Map<String, String> sign(String method, Uri uri, Uint8List? body) => {
        'authorization': 'Bearer $token',
      };
}

/// AWS Signature V4 authentication for S3-compatible services.
class S3HttpBlobAuth implements IHttpBlobAuth {
  S3HttpBlobAuth({
    required this.accessKey,
    required this.secretKey,
    this.region = 'us-east-1',
  });

  final String accessKey;
  final String secretKey;
  final String region;

  @override
  Map<String, String> sign(String method, Uri uri, Uint8List? body) {
    final now = DateTime.now().toUtc();
    final dateStamp = _dateStamp(now);
    final amzDate = _amzDate(now);
    final payloadHash = _sha256Hex(body ?? Uint8List(0));

    final headers = <String, String>{
      'host': uri.host,
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payloadHash,
    };

    final signedHeaderKeys = headers.keys.toList()..sort();
    final signedHeadersStr = signedHeaderKeys.join(';');

    final canonicalHeaders = StringBuffer();
    for (final key in signedHeaderKeys) {
      canonicalHeaders.writeln('$key:${headers[key]}');
    }

    final canonicalRequest = [
      method,
      uri.path.isEmpty ? '/' : uri.path,
      uri.query,
      canonicalHeaders.toString(),
      signedHeadersStr,
      payloadHash,
    ].join('\n');

    final credentialScope = '$dateStamp/$region/s3/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      _sha256Hex(utf8.encode(canonicalRequest)),
    ].join('\n');

    final signingKey = _deriveSigningKey(secretKey, dateStamp, region, 's3');
    final signature = _hmacSha256Hex(signingKey, utf8.encode(stringToSign));

    headers['authorization'] =
        'AWS4-HMAC-SHA256 Credential=$accessKey/$credentialScope, '
        'SignedHeaders=$signedHeadersStr, '
        'Signature=$signature';

    return headers;
  }

  static List<int> _deriveSigningKey(
    String secretKey,
    String dateStamp,
    String region,
    String service,
  ) {
    final kDate = _hmacSha256(utf8.encode('AWS4$secretKey'), utf8.encode(dateStamp));
    final kRegion = _hmacSha256(kDate, utf8.encode(region));
    final kService = _hmacSha256(kRegion, utf8.encode(service));
    return _hmacSha256(kService, utf8.encode('aws4_request'));
  }

  static List<int> _hmacSha256(List<int> key, List<int> data) =>
      Hmac(sha256, key).convert(data).bytes;

  static String _hmacSha256Hex(List<int> key, List<int> data) =>
      Hmac(sha256, key).convert(data).toString();

  static String _sha256Hex(List<int> data) => sha256.convert(data).toString();

  static String _dateStamp(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}'
      '${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}';

  static String _amzDate(DateTime t) =>
      '${_dateStamp(t)}T'
      '${t.hour.toString().padLeft(2, '0')}'
      '${t.minute.toString().padLeft(2, '0')}'
      '${t.second.toString().padLeft(2, '0')}Z';
}
