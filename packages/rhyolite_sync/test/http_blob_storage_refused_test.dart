/// A refused backend has to be distinguishable from a failed transfer.
///
/// The vault that forced this: BYO WebDAV, one wrong character in the
/// password. Every PUT came back 401 and every GET came back 401, and both
/// were indistinguishable from ordinary trouble — a lost upload, an absent
/// blob. The plugin retried on schedule, reported nothing, and showed a green
/// dot for an hour while not one byte reached the server.
///
/// Nothing retries its way out of a 401. It is a missing precondition, and it
/// needs a type of its own so a caller can name it and offer the fix.
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhyolite_sync/src/remote/http_blob_auth.dart';
import 'package:rhyolite_sync/src/remote/http_blob_storage.dart';
import 'package:rhyolite_sync/src/remote/i_blob_storage.dart';
import 'package:test/test.dart';

HttpBlobStorage _storage(int status) => HttpBlobStorage(
  baseUrl: Uri.parse('https://dav.example.com/dav/'),
  prefix: 'blobs/vault-1/',
  auth: BasicHttpBlobAuth(username: 'u', password: 'wrong'),
  backend: HttpBlobBackend.webdav,
  httpClient: MockClient((request) async {
    // MKCOL succeeds so the test is about the object call, not about
    // directory creation, which is deliberately failure-tolerant.
    if (request.method == 'MKCOL') return http.Response('', 201);
    return http.Response('denied', status);
  }),
);

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  group('a 401/403 is a refusal, not a failed transfer', () {
    for (final status in [401, 403]) {
      test('upload reports $status as a refusal', () async {
        await expectLater(
          _storage(status).upload([(_bytes('hello'), 'blob-1')]),
          throwsA(
            isA<BlobStorageRefused>().having(
              (e) => e.statusCode,
              'statusCode',
              status,
            ),
          ),
        );
      });

      test('download reports $status instead of an empty map', () async {
        // The dangerous one. download() swallows every error so a missing
        // blob reads as absent — correct for a 404, and for a 401 it turns
        // "the backend refuses to talk to you" into "your vault is empty".
        await expectLater(
          _storage(status).download(['blob-1']),
          throwsA(isA<BlobStorageRefused>()),
        );
      });
    }

    test('a 404 stays an absent blob, not a refusal', () async {
      // The other side of the same line: absence is ordinary and heals
      // itself. Widening the refusal to every non-200 would turn every
      // missing chunk into a start block.
      expect(await _storage(404).download(['blob-1']), isEmpty);
    });

    test('a 500 stays an ordinary upload failure', () async {
      await expectLater(
        _storage(500).upload([(_bytes('hello'), 'blob-1')]),
        throwsA(isNot(isA<BlobStorageRefused>())),
      );
    });

    test('a 403 alongside a served blob is about that blob', () async {
      // S3 answers a request for a key that is NOT THERE with 403 rather than
      // 404 whenever the caller lacks s3:ListBucket — routine for a tight BYO
      // bucket policy. Read as a refusal, one absent chunk stops the pull and
      // tells the user their credentials are wrong when they are not.
      final storage = HttpBlobStorage(
        baseUrl: Uri.parse('https://dav.example.com/dav/'),
        prefix: 'blobs/vault-1/',
        auth: BasicHttpBlobAuth(username: 'u', password: 'p'),
        backend: HttpBlobBackend.webdav,
        httpClient: MockClient((request) async {
          final id = request.url.pathSegments.last;
          return id == 'blob-2'
              ? http.Response('denied', 403)
              : http.Response.bytes(_bytes('hello'), 200);
        }),
      );
      final got = await storage.download(['blob-1', 'blob-2']);
      expect(got.keys, ['blob-1']);
    });

    test('the ambiguity, once seen, is carried to a lone 403', () async {
      // A download batch is often one large chunk, so it has no success of its
      // own to weigh the 403 against — while the probe that ran before it had
      // 128. Uncarried, the same backend reads as ambiguous to exists() and as
      // a refusal to download(), which is the reading that stops the pull.
      var servedOne = true;
      final storage = HttpBlobStorage(
        baseUrl: Uri.parse('https://dav.example.com/dav/'),
        prefix: 'blobs/vault-1/',
        auth: BasicHttpBlobAuth(username: 'u', password: 'p'),
        backend: HttpBlobBackend.webdav,
        httpClient: MockClient((request) async {
          final id = request.url.pathSegments.last;
          if (servedOne && id == 'blob-1') {
            return http.Response.bytes(_bytes('hello'), 200);
          }
          return http.Response('denied', 403);
        }),
      );
      // The probe sees a 403 next to a success and records the ambiguity.
      await expectLater(
        storage.exists(['blob-1', 'blob-2']),
        throwsA(isNot(isA<BlobStorageRefused>())),
      );
      // Now a batch of one, all 403, and no success anywhere in it.
      servedOne = false;
      expect(await storage.download(['blob-2']), isEmpty);
    });

    test('a 401 is never excused by a served blob', () async {
      // No demotion for 401: it says no valid credentials were presented, and
      // that is true whatever else the batch managed to fetch.
      final storage = HttpBlobStorage(
        baseUrl: Uri.parse('https://dav.example.com/dav/'),
        prefix: 'blobs/vault-1/',
        auth: BasicHttpBlobAuth(username: 'u', password: 'wrong'),
        backend: HttpBlobBackend.webdav,
        httpClient: MockClient((request) async {
          final id = request.url.pathSegments.last;
          return id == 'blob-2'
              ? http.Response('denied', 401)
              : http.Response.bytes(_bytes('hello'), 200);
        }),
      );
      await expectLater(
        storage.download(['blob-1', 'blob-2']),
        throwsA(isA<BlobStorageRefused>()),
      );
    });

    test('the message names the cause and the fix', () async {
      // It reaches the user through the start block verbatim, so "401" alone
      // is not enough — it has to say which knob to turn.
      const refused = BlobStorageRefused(401, 'Unauthorized');
      expect('$refused', contains('401'));
      expect('$refused', contains('credentials'));
    });
  });
}
