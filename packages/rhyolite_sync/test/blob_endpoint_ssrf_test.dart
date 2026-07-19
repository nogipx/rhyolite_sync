import 'package:rhyolite_sync/src/remote/s3_blob_storage.dart';
import 'package:test/test.dart';

void main() {
  group('isBlockedBlobHost — BYO endpoint SSRF guard', () {
    test('blocks cloud-metadata / loopback / localhost', () {
      for (final h in const [
        '169.254.169.254', // AWS/GCP metadata
        '169.254.170.2',
        '127.0.0.1',
        '127.1.2.3',
        'localhost',
        'foo.localhost',
        '0.0.0.0',
        '::1',
        '::',
        'fe80::1',
        '',
      ]) {
        expect(isBlockedBlobHost(h), isTrue, reason: h);
      }
    });

    test('allows public hosts and private LAN (legit self-hosted BYO)', () {
      for (final h in const [
        's3.amazonaws.com',
        'minio.example.com',
        '10.0.0.5', // LAN MinIO
        '172.16.3.4',
        '192.168.1.100',
        'storage.local',
        '203.0.113.7',
      ]) {
        expect(isBlockedBlobHost(h), isFalse, reason: h);
      }
    });
  });

  group('isPrivateLanHost', () {
    test('RFC-1918 ranges are private', () {
      for (final h in const ['10.0.0.1', '172.16.0.1', '172.31.255.255',
        '192.168.0.1']) {
        expect(isPrivateLanHost(h), isTrue, reason: h);
      }
    });
    test('public + out-of-range 172 are not private', () {
      for (final h in const ['s3.example.com', '203.0.113.7', '172.15.0.1',
        '172.32.0.1']) {
        expect(isPrivateLanHost(h), isFalse, reason: h);
      }
    });
  });

  group('credentials over plaintext http (#7)', () {
    WebDavBlobConfig dav(String endpoint, {required bool ssl}) =>
        WebDavBlobConfig(
            endpoint: endpoint, username: 'u', password: 'p', useSSL: ssl);
    S3BlobConfig s3(String endpoint, {required bool ssl}) => S3BlobConfig(
        endpoint: endpoint,
        bucket: 'b',
        accessKey: 'ak',
        secretKey: 'sk',
        useSSL: ssl);

    test('WebDAV Basic over http:// to a PUBLIC host is refused', () {
      expect(
        () => dav('dav.example.com', ssl: false).createBlobStorage(vaultId: 'v'),
        throwsArgumentError,
      );
    });

    test('S3 over http:// to a PUBLIC host is refused', () {
      expect(
        () => s3('s3.example.com', ssl: false).createBlobStorage(vaultId: 'v'),
        throwsArgumentError,
      );
    });

    test('https to a public host is allowed', () {
      expect(dav('dav.example.com', ssl: true).createBlobStorage(vaultId: 'v'),
          isNotNull);
      expect(s3('s3.example.com', ssl: true).createBlobStorage(vaultId: 'v'),
          isNotNull);
    });

    test('http to a private-LAN host is allowed (self-hosted)', () {
      expect(dav('192.168.1.10:8080', ssl: false).createBlobStorage(vaultId: 'v'),
          isNotNull);
      expect(s3('10.0.0.9:9000', ssl: false).createBlobStorage(vaultId: 'v'),
          isNotNull);
    });
  });
}
