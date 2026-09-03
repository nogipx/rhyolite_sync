import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// A blob transfer that never finishes must not be able to stop the pull.
//
// The invariant was written down for the gRPC path and never applied to the
// HTTP one, so on BYO storage a stalled response hung its group, the group
// hung its batch, and the batch hung the pull: one fetch of five blobs
// produced no completion for six minutes while every other file waited.
//
// Idle rather than total, because slow is not the same as dead — the same
// vault legitimately spent 278 seconds on five multi-megabyte blobs.
// ---------------------------------------------------------------------------

/// Serves a body in pieces, on a schedule the test controls.
class _DripClient extends http.BaseClient {
  _DripClient(this.gaps);

  /// Pause before each chunk. The body is one byte per gap.
  final List<Duration> gaps;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final controller = StreamController<List<int>>();
    () async {
      for (final gap in gaps) {
        await Future<void>.delayed(gap);
        controller.add([1]);
      }
      await controller.close();
    }();
    return http.StreamedResponse(controller.stream, 200);
  }
}

HttpBlobStorage _storage(http.Client client) => HttpBlobStorage(
  baseUrl: Uri.parse('https://dav.example.com/'),
  prefix: 'blobs/vault-1/',
  auth: BasicHttpBlobAuth(username: 'u', password: 'p'),
  httpClient: client,
);

void main() {
  test('a transfer that goes silent is cut, not waited on forever', () {
    Object? error;
    var done = false;
    fakeAsync((async) {
      // One byte, then nothing at all — the shape of a stalled response.
      _storage(_DripClient([Duration.zero, const Duration(hours: 1)]))
          .download(['blob-1'])
          .then((_) => done = true)
          .catchError((Object e) {
            error = e;
            return <String, Uint8List>{};
          });
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();
    });

    // download() turns a per-blob failure into an omission rather than a
    // throw, which is the contract its callers rely on. What matters here is
    // that it FINISHED.
    expect(
      done || error != null,
      isTrue,
      reason: 'a stalled transfer must end. Left hanging it holds the group, '
          'the batch and the whole pull behind it',
    );
  });

  test('a slow but moving transfer is left alone', () {
    // Every gap is under the idle bound; the total is far over it. A total
    // timeout would cut this, and cutting it would be wrong.
    Map<String, Uint8List>? got;
    fakeAsync((async) {
      _storage(
        _DripClient(List.filled(30, const Duration(seconds: 15))),
      ).download(['blob-1']).then((r) => got = r);
      async.elapse(const Duration(minutes: 15));
      async.flushMicrotasks();
    });

    expect(
      got,
      isNotNull,
      reason: 'seven and a half minutes of steady progress is a slow link, '
          'not a dead one — only silence is a fault',
    );
    expect(got!['blob-1']!.length, 30);
  });
}
