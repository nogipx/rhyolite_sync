/// Absence is a conclusion, and it may only be drawn from a reply.
///
/// The vault that forced this: an Android phone, briefly with no network at
/// all, on a BYO WebDAV backend. Every HEAD threw `UnknownHostException` and
/// every throw was counted as "the backend does not hold this blob", so the
/// verify pass concluded that 3274 of 3274 referenced blobs were gone — logged
/// four hundred unrecoverable-data-loss warnings and began re-uploading the
/// whole vault over mobile data. Nothing had been lost.
///
/// The line drawn here: a 404 is knowledge, a thrown request is not, and a
/// status the server would not answer with (405 because HEAD is unimplemented,
/// 5xx after the retries ran out) is not either.
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhyolite_sync/src/remote/http_blob_auth.dart';
import 'package:rhyolite_sync/src/remote/http_blob_storage.dart';
import 'package:rhyolite_sync/src/remote/i_blob_storage.dart';
import 'package:test/test.dart';

HttpBlobStorage _storage(
  Future<http.Response> Function(http.Request) handler,
) => HttpBlobStorage(
  baseUrl: Uri.parse('https://dav.example.com/dav/'),
  prefix: 'blobs/vault-1/',
  auth: BasicHttpBlobAuth(username: 'u', password: 'p'),
  backend: HttpBlobBackend.webdav,
  httpClient: MockClient(handler),
);

/// Answers every request with [status].
HttpBlobStorage _answering(int status) =>
    _storage((_) async => http.Response('', status));

void main() {
  group('a presence probe reports what the backend said', () {
    test('a 2xx is a present blob', () async {
      expect(await _answering(200).exists(['blob-1']), {'blob-1'});
    });

    test(
      'a 404 is an absent blob — the answer verify exists to act on',
      () async {
        expect(await _answering(404).exists(['blob-1']), isEmpty);
      },
    );

    test('a 410 is absent too', () async {
      expect(await _answering(410).exists(['blob-1']), isEmpty);
    });
  });

  group('a probe with no answer is not an absent blob', () {
    test(
      'an unreachable backend throws instead of returning an empty set',
      () async {
        // The exact shape of the reported bug: offline, so the request never
        // completes. Returning {} here is what told the caller the vault had
        // evaporated.
        final storage = _storage(
          (_) async => throw http.ClientException('Failed host lookup'),
        );
        await expectLater(
          storage.exists(['blob-1', 'blob-2']),
          throwsA(
            isA<BlobProbeIncomplete>()
                .having((e) => e.probed, 'probed', 2)
                .having((e) => e.unanswered, 'unanswered', 2),
          ),
        );
      },
    );

    test('one unanswered probe poisons the whole batch', () async {
      // A short set is indistinguishable from a complete one, so a partial
      // answer must not be handed back as if it were the truth.
      final storage = _storage((request) async {
        if (request.url.path.endsWith('blob-2')) {
          throw http.ClientException('connection closed');
        }
        return http.Response('', 200);
      });
      await expectLater(
        storage.exists(['blob-1', 'blob-2']),
        throwsA(
          isA<BlobProbeIncomplete>().having(
            (e) => e.unanswered,
            'unanswered',
            1,
          ),
        ),
      );
    });

    test('a probe that fails once and answers on retry is complete', () async {
      // A backend that drops the odd connection must not be able to block the
      // batch forever: one failure is a flake, two for the same id is a fact.
      var attempts = 0;
      final storage = _storage((_) async {
        attempts++;
        if (attempts == 1) throw http.ClientException('connection reset');
        return http.Response('', 200);
      });
      expect(await storage.exists(['blob-1']), {'blob-1'});
      expect(attempts, 2);
    });

    test('only the unanswered ids are retried', () async {
      // The retry is a repair, not a second full pass — re-probing ids the
      // server already answered for doubles the round trips on every batch
      // that hits a single flake.
      final asked = <String>[];
      var failed = false;
      final storage = _storage((request) async {
        final id = request.url.pathSegments.last;
        asked.add(id);
        if (id == 'blob-2' && !failed) {
          failed = true;
          throw http.ClientException('connection reset');
        }
        return http.Response('', 200);
      });
      expect(await storage.exists(['blob-1', 'blob-2', 'blob-3']), {
        'blob-1',
        'blob-2',
        'blob-3',
      });
      // Counted, not sequenced: the batch runs eight-wide, so the order the
      // three arrive in is a race and asserting it would only make the test
      // flaky. What must hold is that exactly one id was asked twice.
      expect(asked, hasLength(4));
      expect(asked.where((id) => id == 'blob-2'), hasLength(2));
      expect(asked.where((id) => id == 'blob-1'), hasLength(1));
      expect(asked.where((id) => id == 'blob-3'), hasLength(1));
    });

    test(
      'a 405 is the server declining to answer, not an absent blob',
      () async {
        // Some backends implement GET and not HEAD. Read as absence, that is a
        // standing instruction to re-upload every blob the vault has, forever.
        await expectLater(
          _answering(405).exists(['blob-1']),
          throwsA(isA<BlobProbeIncomplete>()),
        );
      },
    );

    test('the message says absence was not concluded', () async {
      // It reaches the log verbatim on a device that is merely offline, so it
      // has to read as "waiting", not as "your data is gone".
      const incomplete = BlobProbeIncomplete(128, 128);
      expect('$incomplete', contains('128'));
      expect('$incomplete', contains('absence cannot be concluded'));
    });
  });

  group('a refused probe is a refusal, not absence', () {
    for (final status in [401, 403]) {
      test('$status reports the refusal', () async {
        // Same reasoning as download(): wrong credentials must not read as an
        // empty backend. Checked ahead of BlobProbeIncomplete because the two
        // need opposite responses — one is fixed in settings, one by waiting.
        await expectLater(
          _answering(status).exists(['blob-1']),
          throwsA(
            isA<BlobStorageRefused>().having(
              (e) => e.statusCode,
              'statusCode',
              status,
            ),
          ),
        );
      });
    }

    /// Answers 200 for everything except `blob-2`, which gets [status].
    HttpBlobStorage oneOddOut(int status) => _storage((request) async {
      final id = request.url.pathSegments.last;
      return http.Response('', id == 'blob-2' ? status : 200);
    });

    test(
      'a 403 among successful probes is about the object, not the account',
      () async {
        // S3 answers HEAD for a key that is NOT THERE with 403 rather than 404
        // whenever the caller lacks s3:ListBucket — routine for a tight BYO
        // bucket policy. Read as a refusal, the first genuinely-missing blob
        // would put a "check your credentials" block in front of the user and
        // abandon the heal this pass exists to perform.
        //
        // Reported as unanswered, not absent: one successful HEAD proves the
        // credentials work, and proves nothing about this object either way.
        await expectLater(
          oneOddOut(403).exists(['blob-1', 'blob-2']),
          throwsA(
            isA<BlobProbeIncomplete>().having(
              (e) => e.unanswered,
              'unanswered',
              1,
            ),
          ),
        );
      },
    );

    test('a 401 among successful probes is still a refusal', () async {
      // No demotion for 401: it means no valid credentials were presented and
      // says nothing about any one object, whatever else the batch answered.
      await expectLater(
        oneOddOut(401).exists(['blob-1', 'blob-2']),
        throwsA(isA<BlobStorageRefused>()),
      );
    });

    test('a 401 anywhere in the batch outranks a 403', () async {
      // Which of the two lands first is a race between eight workers, and only
      // one of them is unambiguous. Reporting the 403 would leave the batch
      // demotable and hide a genuinely wrong password behind an object-level
      // answer that happened to arrive sooner.
      final storage = _storage((request) async {
        final id = request.url.pathSegments.last;
        return http.Response('', id == 'blob-1' ? 403 : 401);
      });
      await expectLater(
        storage.exists(['blob-1', 'blob-2']),
        throwsA(
          isA<BlobStorageRefused>().having(
            (e) => e.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
    });
  });

  test('an empty batch asks nothing and answers nothing', () async {
    final storage = _storage((_) async => fail('no request expected'));
    expect(await storage.exists([]), isEmpty);
  });
}
