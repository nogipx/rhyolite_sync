/// A throttled backend means "later", and the HTTP storage used to hear "no".
///
/// The gRPC storage has always retried the server's RESOURCE_EXHAUSTED with
/// backoff. The HTTP one had nothing, so a BYO S3 or WebDAV backend under load
/// produced a run of ordinary errors — and a run of ordinary errors is exactly
/// what the startup pass's systemic-failure guard ends the pass on. Same
/// signal, opposite outcome, decided by which transport it arrived on.
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rhyolite_sync/src/remote/http_blob_auth.dart';
import 'package:rhyolite_sync/src/remote/http_blob_storage.dart';
import 'package:test/test.dart';

/// Answers [throttleCount] requests with [status] before letting the rest
/// through. Records every attempt so a test can count them.
class _ThrottlingServer {
  _ThrottlingServer({
    required this.throttleCount,
    this.status = 429,
    this.retryAfter,
  });

  final int throttleCount;
  final int status;
  final String? retryAfter;
  int attempts = 0;

  http.Client get client => MockClient((request) async {
    if (request.method == 'MKCOL') return http.Response('', 201);
    attempts++;
    if (attempts <= throttleCount) {
      return http.Response(
        'slow down',
        status,
        headers: retryAfter == null ? const {} : {'retry-after': retryAfter!},
      );
    }
    return http.Response('', request.method == 'GET' ? 200 : 201);
  });
}

HttpBlobStorage _storage(_ThrottlingServer server) => HttpBlobStorage(
  baseUrl: Uri.parse('https://s3.example.com/bucket/'),
  prefix: 'blobs/vault-1/',
  auth: BasicHttpBlobAuth(username: 'u', password: 'p'),
  backend: HttpBlobBackend.s3,
  httpClient: server.client,
);

Uint8List _bytes(String s) => Uint8List.fromList(s.codeUnits);

/// Runs [body] to completion inside fake time, so the backoff waits cost
/// nothing. Returns whether it finished.
bool _runFast(Future<void> Function() body) {
  var done = false;
  Object? error;
  fakeAsync((async) {
    body().then<void>(
      (_) {
        done = true;
      },
      onError: (Object e) {
        error = e;
        done = true;
      },
    );
    // Comfortably past the 1s + 3s + 8s curve and the 30s cap.
    async.elapse(const Duration(minutes: 2));
    async.flushMicrotasks();
  });
  if (error != null) throw error!;
  return done;
}

/// How long [body] took in fake time. Measured AT completion — reading the
/// clock after `elapse` returns just reports how far the test wound it on.
Duration _timeOf(
  Future<void> Function(HttpBlobStorage) body,
  _ThrottlingServer server,
) {
  Duration? took;
  fakeAsync((async) {
    final start = async.elapsed;
    body(_storage(server)).then((_) => took = async.elapsed - start);
    async.elapse(const Duration(minutes: 5));
    async.flushMicrotasks();
  });
  expect(took, isNotNull, reason: 'the call must finish inside fake time');
  return took!;
}

void main() {
  group('a throttled backend is waited out, not reported as a failure', () {
    for (final status in [429, 500, 502, 503, 504]) {
      test('$status is retried until it clears', () {
        // 503 is here because S3 answers SlowDown with it, and 500 because
        // hosted WebDAV answers that way under load: one real pass lost two
        // notes out of 188 to a 500 that every neighbouring group survived.
        // Reading only 429 leaves the commonest BYO backends on the failure
        // path.
        final server = _ThrottlingServer(throttleCount: 2, status: status);
        expect(
          _runFast(() => _storage(server).upload([(_bytes('x'), 'blob-1')])),
          isTrue,
          reason: 'the upload must succeed, not raise',
        );
        expect(server.attempts, 3);
      });
    }

    test('a throttle that never clears gives up bounded', () {
      // Not unbounded patience: the pass has its own retry in the shape of the
      // next startup, and waiting out a saturated backend forever is a slower
      // way of not syncing.
      final server = _ThrottlingServer(throttleCount: 999);
      expect(
        () => _runFast(() => _storage(server).upload([(_bytes('x'), 'b')])),
        throwsA(anything),
      );
      expect(server.attempts, 4);
    });

    test('Retry-After is obeyed in preference to the backoff curve', () {
      // The server knows how long its own queue is; no curve guesses better
      // than being told. Asserted through timing because that is the only
      // observable difference.
      final server = _ThrottlingServer(throttleCount: 1, retryAfter: '5');
      final elapsed = _timeOf(
        (s) => s.upload([(_bytes('x'), 'blob-1')]),
        server,
      );
      // The curve's first step is 1s. Five means the header won.
      expect(elapsed.inSeconds, greaterThanOrEqualTo(5));
      expect(elapsed.inSeconds, lessThan(10));
    });

    test('an absurd Retry-After is capped', () {
      // `Retry-After: 3600` is a legal answer and not one to obey inside a
      // sync pass — the engine would look wedged for an hour.
      final server = _ThrottlingServer(throttleCount: 1, retryAfter: '3600');
      final elapsed = _timeOf(
        (s) => s.upload([(_bytes('x'), 'blob-1')]),
        server,
      );
      expect(elapsed.inSeconds, lessThanOrEqualTo(31));
    });

    test('downloads are throttled the same way', () {
      // A 429 on GET used to be swallowed as "blob absent", which is the
      // silent-data-loss reading of a queue being full.
      final server = _ThrottlingServer(throttleCount: 2);
      late Map<String, Uint8List> got;
      _runFast(() async => got = await _storage(server).download(['blob-1']));
      expect(got.keys, ['blob-1']);
      expect(server.attempts, 3);
    });

    test('a non-throttle status is returned at once, not retried', () {
      // The retry belongs to "later" only. Widening it would turn every 404
      // into four round trips and every wrong password into a stall.
      final server = _ThrottlingServer(throttleCount: 999, status: 404);
      _runFast(() async => await _storage(server).download(['blob-1']));
      expect(server.attempts, 1);
    });

    for (final status in [401, 501, 507]) {
      test('$status is answered once — the server will not do this', () {
        // The line the 5xx retry must not cross. 501 is unimplemented, 507 is
        // out of space, 401 is the wrong password: none improves by being
        // asked again, and repeating it only delays the honest answer.
        final server = _ThrottlingServer(throttleCount: 999, status: status);
        try {
          _runFast(() => _storage(server).upload([(_bytes('x'), 'b')]));
        } catch (_) {
          // Refusals raise; that is the point of them.
        }
        expect(server.attempts, 1);
      });
    }
  });
}
