import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhyolite_sync/src/remote/http_blob_auth.dart';
import 'package:rhyolite_sync/src/remote/http_blob_storage.dart';
import 'package:test/test.dart';

/// Models a WebDAV server that refuses a PUT with 409 Conflict until the
/// parent collection has been created with MKCOL — the behaviour RFC 4918
/// §9.7.1 prescribes and Nextcloud/ownCloud implement.
class _FakeWebDav {
  _FakeWebDav({this.mkcolFailsUntilAttempt = 0});

  final collections = <String>{};
  final objects = <String, Uint8List>{};
  final log = <String>[];

  /// MKCOL answers 503 for the first N attempts. Models the blip that used to
  /// latch directory creation off for the whole session.
  final int mkcolFailsUntilAttempt;
  int mkcolAttempts = 0;

  http.Client get client => MockClient((request) async {
        final method = request.method;
        final path = request.url.path;
        log.add('$method $path');
        switch (method) {
          case 'MKCOL':
            mkcolAttempts++;
            if (mkcolAttempts <= mkcolFailsUntilAttempt) {
              return http.Response('busy', 503);
            }
            final created = collections.add(path);
            return http.Response('', created ? 201 : 405);
          case 'PUT':
            final parent = path.substring(0, path.lastIndexOf('/') + 1);
            if (!collections.contains(parent)) {
              return http.Response('parent collection missing', 409);
            }
            objects[path] = request.bodyBytes;
            return http.Response('', 201);
          default:
            return http.Response('', 404);
        }
      });
}

HttpBlobStorage _storage(_FakeWebDav dav) => HttpBlobStorage(
      baseUrl: Uri.parse('https://dav.example.com/remote.php/dav/'),
      prefix: 'blobs/vault-1/',
      auth: BasicHttpBlobAuth(username: 'u', password: 'p'),
      backend: HttpBlobBackend.webdav,
      httpClient: dav.client,
    );

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('HttpBlobStorage on WebDAV', () {
    test('creates the vault directory before the first upload', () async {
      final dav = _FakeWebDav();
      await _storage(dav).upload([(_bytes('hello'), 'blob-a')]);

      expect(dav.objects, hasLength(1));
      expect(
        dav.collections,
        containsAll([
          '/remote.php/dav/blobs/',
          '/remote.php/dav/blobs/vault-1/',
        ]),
      );
    });

    test('a 409 mid-session rebuilds the directory and retries the upload',
        () async {
      final dav = _FakeWebDav();
      final storage = _storage(dav);
      await storage.upload([(_bytes('first'), 'blob-a')]);
      expect(dav.objects, hasLength(1));

      // The user deletes the vault folder from their WebDAV UI. The next PUT
      // gets a 409 against a storage instance that believes it already made
      // the directory.
      dav.collections.clear();
      dav.log.clear();

      await storage.upload([(_bytes('second'), 'blob-b')]);

      expect(dav.objects.keys.any((p) => p.endsWith('blob-b')), isTrue,
          reason: 'the retry after MKCOL must land');
      expect(dav.log.where((l) => l.startsWith('MKCOL')), isNotEmpty,
          reason: 'the 409 must trigger a rebuild, not just be reported');
    });

    test('a MKCOL blip is recovered by the 409 retry, within the same upload',
        () async {
      // Both segments fail on the first chain; the PUT then 409s, the retry
      // rebuilds, and the upload lands. Before the fix the first chain latched
      // "created" and the PUT failed with a 409 nothing would ever resolve.
      final dav = _FakeWebDav(mkcolFailsUntilAttempt: 2);
      await _storage(dav).upload([(_bytes('payload'), 'blob-a')]);

      expect(dav.objects.keys.any((p) => p.endsWith('blob-a')), isTrue);
      expect(dav.mkcolAttempts, greaterThan(2),
          reason: 'the failed chain must be retried, not trusted');
    });

    test('an unconfirmed directory chain is retried on the NEXT upload too',
        () async {
      // A WebDAV server that keeps erroring on MKCOL. Nothing ever confirmed
      // the collection, so the latch must stay open — this is the regression
      // where one blip disabled directory creation for the whole session.
      var mkcols = 0;
      final client = MockClient((request) async {
        if (request.method == 'MKCOL') {
          mkcols++;
          return http.Response('busy', 503);
        }
        return http.Response('', 201);
      });
      final storage = HttpBlobStorage(
        baseUrl: Uri.parse('https://dav.example.com/'),
        prefix: 'blobs/vault-1/',
        auth: BasicHttpBlobAuth(username: 'u', password: 'p'),
        backend: HttpBlobBackend.webdav,
        httpClient: client,
      );

      await storage.upload([(_bytes('one'), 'blob-a')]);
      final afterFirst = mkcols;
      await storage.upload([(_bytes('two'), 'blob-b')]);

      expect(afterFirst, 2);
      expect(mkcols, greaterThan(afterFirst),
          reason: 'an unconfirmed directory must not be assumed to exist');
    });

    test('S3 is never sent MKCOL — it has no directories to create', () async {
      var mkcols = 0;
      final client = MockClient((request) async {
        if (request.method == 'MKCOL') mkcols++;
        return http.Response('', 200);
      });
      final storage = HttpBlobStorage(
        baseUrl: Uri.parse('https://s3.example.com/bucket'),
        prefix: 'blobs/vault-1/',
        auth: BasicHttpBlobAuth(username: 'u', password: 'p'),
        backend: HttpBlobBackend.s3,
        httpClient: client,
      );

      await storage.upload([(_bytes('one'), 'blob-a')]);
      await storage.upload([(_bytes('two'), 'blob-b')]);

      expect(mkcols, 0,
          reason: 'two wasted round trips per upload batch, forever');
    });

    test('a concurrent burst of uploads makes one directory chain, not eight',
        () async {
      final dav = _FakeWebDav();
      await _storage(dav).upload([
        for (var i = 0; i < 8; i++) (_bytes('b$i'), 'blob-$i'),
      ]);

      expect(dav.objects, hasLength(8));
      // Two segments in the prefix: blobs/ and vault-1/.
      expect(dav.mkcolAttempts, 2,
          reason: 'eight parallel uploads must not fire eight MKCOL chains');
    });

    test('no retry storm: a 409 that survives the rebuild is reported once',
        () async {
      // A server that always 409s (misconfigured path, no MKCOL support).
      final client = MockClient((request) async => request.method == 'PUT'
          ? http.Response('nope', 409)
          : http.Response('', 201));
      final storage = HttpBlobStorage(
        baseUrl: Uri.parse('https://dav.example.com/'),
        prefix: 'blobs/vault-1/',
        auth: BasicHttpBlobAuth(username: 'u', password: 'p'),
        httpClient: client,
      );

      await expectLater(
        storage.upload([(_bytes('x'), 'blob-a')]),
        throwsA(isA<Exception>()),
      );
    });
  });
}
