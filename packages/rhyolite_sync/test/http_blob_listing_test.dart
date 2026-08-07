import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhyolite_sync/src/remote/http_blob_auth.dart';
import 'package:rhyolite_sync/src/remote/http_blob_storage.dart';
import 'package:test/test.dart';

/// The listing responses are parsed by a hand-rolled extractor rather than an
/// XML dependency (one element type, two document shapes, and every dart2js
/// user would pay for the parser). These pin the shapes it must handle.
const _propfindBody = '<?xml version="1.0"?>'
    '<D:multistatus xmlns:D="DAV:">'
    '<D:response><D:href>/dav/blobs/vault-1/</D:href></D:response>'
    '<D:response><D:href>/dav/blobs/vault-1/aabbcc</D:href></D:response>'
    '<D:response><D:href>/dav/blobs/vault-1/ddeeff</D:href></D:response>'
    '<D:response><D:href>/dav/blobs/vault-1/nested/deep</D:href></D:response>'
    '</D:multistatus>';

/// Same document without a namespace prefix and with lowercase tags — servers
/// differ, and the extractor must not care.
const _propfindNoNamespace = '<multistatus>'
    '<response><href>/dav/blobs/vault-1/112233</href></response>'
    '</multistatus>';

String _s3Page({required bool truncated, required String key, String? token}) =>
    '<ListBucketResult>'
    '<Contents><Key>blobs/vault-1/$key</Key></Contents>'
    '<IsTruncated>$truncated</IsTruncated>'
    '${token == null ? '' : '<NextContinuationToken>$token</NextContinuationToken>'}'
    '</ListBucketResult>';

HttpBlobStorage _dav(http.Client client) => HttpBlobStorage(
      baseUrl: Uri.parse('https://dav.example.com/dav/'),
      prefix: 'blobs/vault-1/',
      auth: BasicHttpBlobAuth(username: 'u', password: 'p'),
      backend: HttpBlobBackend.webdav,
      httpClient: client,
    );

HttpBlobStorage _s3(http.Client client) => HttpBlobStorage(
      baseUrl: Uri.parse('https://s3.example.com/bucket'),
      prefix: 'blobs/vault-1/',
      auth: BasicHttpBlobAuth(username: 'u', password: 'p'),
      backend: HttpBlobBackend.s3,
      httpClient: client,
    );

void main() {
  group('WebDAV listing', () {
    test('yields the object names directly under the vault directory',
        () async {
      late http.Request seen;
      final ids = await _dav(MockClient((request) async {
        seen = request;
        return http.Response(_propfindBody, 207);
      })).listBlobIds();

      expect(ids, ['aabbcc', 'ddeeff'],
          reason: 'the collection itself and anything nested are not blobs');
      expect(seen.method, 'PROPFIND');
      expect(seen.headers['depth'], '1');
    });

    test('namespace prefix and tag case are irrelevant', () async {
      final ids = await _dav(
        MockClient((_) async => http.Response(_propfindNoNamespace, 207)),
      ).listBlobIds();

      expect(ids, ['112233']);
    });

    test('percent-encoded hrefs are decoded', () async {
      final ids = await _dav(
        MockClient((_) async => http.Response(
              '<multistatus><response>'
              '<href>/dav/blobs/vault-1/a%2Db%2Dc</href>'
              '</response></multistatus>',
              207,
            )),
      ).listBlobIds();

      expect(ids, ['a-b-c']);
    });

    test('404 on the vault directory is an empty bucket, not a failure',
        () async {
      final ids = await _dav(
        MockClient((_) async => http.Response('', 404)),
      ).listBlobIds();

      expect(ids, isEmpty, reason: 'nothing stored yet is a valid answer');
      expect(ids, isNotNull);
    });

    test('a refused PROPFIND answers null, not a clean bucket', () async {
      final ids = await _dav(
        MockClient((_) async => http.Response('denied', 403)),
      ).listBlobIds();

      expect(ids, isNull,
          reason: 'a bucket we could not read must not read as empty');
    });
  });

  group('S3 listing', () {
    test('follows continuation tokens across pages', () async {
      final queries = <String>[];
      final ids = await _s3(MockClient((request) async {
        queries.add(request.url.query);
        final second =
            request.url.queryParameters['continuation-token'] != null;
        return http.Response(
          second
              ? _s3Page(truncated: false, key: 'two')
              : _s3Page(truncated: true, key: 'one', token: 'tok'),
          200,
        );
      })).listBlobIds();

      expect(ids, ['one', 'two']);
      expect(queries, hasLength(2));
    });

    test('query parameters are sorted, because SigV4 signs them verbatim',
        () async {
      final queries = <String>[];
      await _s3(MockClient((request) async {
        queries.add(request.url.query);
        return http.Response(_s3Page(truncated: false, key: 'one'), 200);
      })).listBlobIds();

      final keys = queries.single.split('&').map((p) => p.split('=').first);
      expect(keys, orderedEquals([...keys]..sort()), reason: queries.single);
    });

    test('keys outside the prefix and nested keys are ignored', () async {
      final ids = await _s3(MockClient((_) async => http.Response(
            '<ListBucketResult>'
            '<Contents><Key>blobs/vault-1/good</Key></Contents>'
            '<Contents><Key>blobs/vault-1/sub/deep</Key></Contents>'
            '<Contents><Key>blobs/other-vault/nope</Key></Contents>'
            '<IsTruncated>false</IsTruncated>'
            '</ListBucketResult>',
            200,
          ))).listBlobIds();

      expect(ids, ['good']);
    });

    test('an error on the first page answers null, not a clean bucket',
        () async {
      final ids = await _s3(
        MockClient((_) async => http.Response('denied', 403)),
      ).listBlobIds();

      expect(ids, isNull);
    });

    test('an error on a later page keeps what was already listed', () async {
      var call = 0;
      final ids = await _s3(MockClient((_) async {
        call++;
        return call == 1
            ? http.Response(
                _s3Page(truncated: true, key: 'one', token: 'tok'), 200)
            : http.Response('boom', 500);
      })).listBlobIds();

      expect(ids, ['one'],
          reason: 'a short listing costs a later sweep, never data — the '
              'sweep only deletes ids it was shown');
    });
  });

  test('a backend with no listing protocol answers null', () async {
    final storage = HttpBlobStorage(
      baseUrl: Uri.parse('https://files.example.com/'),
      prefix: 'blobs/vault-1/',
      auth: BasicHttpBlobAuth(username: 'u', password: 'p'),
      httpClient: MockClient((_) async => http.Response('', 200)),
    );

    expect(await storage.listBlobIds(), isNull);
  });
}
