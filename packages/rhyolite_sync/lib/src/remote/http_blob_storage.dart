import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Which backend a [HttpBlobStorage] is talking to.
///
/// Storing and fetching an object is the same four HTTP verbs everywhere,
/// which is why one class serves them all. This names the places where that
/// stops being true: enumeration (`list-type=2` vs `PROPFIND`) and whether
/// parent collections have to be created at all.
enum HttpBlobBackend {
  /// Anything not identified more precisely — a plain HTTP file server.
  /// Cannot be enumerated, and is sent MKCOL on the chance it is a WebDAV
  /// server we were not told about.
  generic,

  /// S3 and compatibles. Keys are flat: the slashes in `blobs/<id>` are
  /// characters, not directories.
  s3,

  /// WebDAV. Slashes are real collections, which have to exist before a PUT.
  webdav,
}

/// [IBlobStorage] that stores blobs as HTTP objects at `<baseUrl>/<prefix><blobId>`.
///
/// Works with any HTTP-based backend: S3, WebDAV, Cloudflare R2,
/// Backblaze B2, plain HTTP file servers -- as long as:
/// - PUT `/<key>` stores an object
/// - GET `/<key>` returns the object bytes
///
/// Authentication is delegated to [IHttpBlobAuth].
class HttpBlobStorage implements IBlobStorage, IListableBlobStorage {
  HttpBlobStorage({
    required this.baseUrl,
    required this.prefix,
    required this.auth,
    this.backend = HttpBlobBackend.generic,
    http.Client? httpClient,
    LogScope? logger,
  }) : _http = httpClient ?? http.Client(),
       _log = logger ?? LogScope.noop;

  /// Which backend this is. Only the operations that genuinely differ branch
  /// on it; the object CRUD does not.
  final HttpBlobBackend backend;

  final Uri baseUrl;
  final String prefix;
  final IHttpBlobAuth auth;
  final http.Client _http;

  /// Optional, because this class is constructed in tests and by callers that
  /// have no logger. Silent by default, never absent.
  final LogScope _log;

  /// Set only once the whole [prefix] chain has really been created (or was
  /// already there). It used to be set unconditionally after the first
  /// attempt, so one failed MKCOL — a blip, an auth token not yet live, a
  /// server briefly down — permanently disabled directory creation for the
  /// session, and every upload after it failed against a directory nothing
  /// would ever create.
  bool _dirsCreated = false;

  /// De-duplicates concurrent creation: uploads run [_concurrency]-wide, so a
  /// burst of 409s would otherwise fire one MKCOL chain per in-flight upload.
  Future<void>? _dirsInFlight;

  /// WebDAV answers a PUT whose parent collection is absent with 409 Conflict
  /// (RFC 4918 §9.7.1). That is the vault directory being gone — never created,
  /// or removed under us by the user tidying their storage.
  static const int _missingParentStatus = 409;

  /// Statuses that mean "later", not "no".
  ///
  /// 429 is the standard one; S3 and its compatibles also answer 503 SlowDown
  /// under the same conditions, and both carry the same instruction. Treating
  /// them as failures is how a rate-limited backend ended a startup pass: five
  /// throttles in a row trip the systemic-failure guard, which is the right
  /// response to a refusal and the wrong one to a queue.
  ///
  /// 500/502/504 are here because hosted WebDAV really does answer that way
  /// under load. One real pass saw two of 188 groups fail on a 500 while every
  /// group around them succeeded — sporadic, server-side, and gone by the next
  /// attempt. Without a retry those two notes simply did not sync, and the log
  /// line explaining why scrolled past.
  ///
  /// 501, 505 and 507 are deliberately absent. They say the server will not do
  /// this — unimplemented, wrong protocol, out of space — and repeating the
  /// request four times only delays finding out.
  static const Set<int> _throttleStatuses = {429, 500, 502, 503, 504};

  /// Attempts per request when throttled. Small on purpose — the pass has its
  /// own retry in the shape of the next startup, and a client that waits out
  /// an overloaded backend forever is just a slower way of not syncing.
  static const int _maxThrottleAttempts = 4;

  /// Backoff when the server does not say how long to wait.
  static const List<Duration> _throttleBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 8),
  ];

  /// Ceiling on a server-dictated wait. `Retry-After: 3600` is a legal answer
  /// and not one to obey inside a sync pass.
  static const Duration _maxThrottleWait = Duration(seconds: 30);

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    if (blobIds.isEmpty) return {};
    final result = <String, Uint8List>{};
    final futures = <Future<void>>[];
    BlobStorageRefused? refused;
    for (final blobId in blobIds) {
      context?.cancellationToken?.throwIfCancelled();
      futures.add(() async {
        try {
          final uri = _objectUri(blobId);
          final response = await _request('GET', uri, context: context);
          if (response.statusCode == 200) {
            result[blobId] = response.bodyBytes;
          } else if (response.statusCode == 401 || response.statusCode == 403) {
            // Missing and forbidden are the same empty map to the caller, and
            // they mean opposite things: one is a blob to heal, the other is
            // the whole backend saying no. Undifferentiated, a wrong password
            // reads as a vault whose content has evaporated.
            //
            // 401 outranks a 403 already recorded, for the reason [exists]
            // gives: only one of the two is unambiguous, and which of eight
            // workers lands first is a race.
            if (refused == null ||
                (response.statusCode == 401 && refused!.statusCode != 401)) {
              refused = BlobStorageRefused(
                response.statusCode,
                response.reasonPhrase ?? '',
              );
            }
          }
        } catch (_) {
          // Skip blobs that fail to download (e.g. 404).
        }
      }());
      if (futures.length >= 8) {
        await Future.wait(futures);
        futures.clear();
      }
    }
    if (futures.isNotEmpty) await Future.wait(futures);
    // Raised after the whole batch rather than from inside it, so the refusal
    // is reported once for the request instead of racing eight workers — and
    // only when it is about the credentials. A download batch is frequently
    // one large chunk, so `result` alone is thin evidence; [_throwIfRefused]
    // also weighs what this backend has already been seen to do.
    _throwIfRefused(refused, anyAnswered: result.isNotEmpty);
    return result;
  }

  /// Maximum simultaneous HTTP requests. WebDAV servers usually cope with
  /// 8 connections per client; tune lower if a real server complains.
  static const int _concurrency = 8;

  @override
  Future<void> deleteMany(List<String> blobIds, {RpcContext? context}) async {
    if (blobIds.isEmpty) return;
    await _runParallel(blobIds, (id) async {
      context?.cancellationToken?.throwIfCancelled();
      try {
        await _request('DELETE', _objectUri(id), context: context);
      } catch (_) {}
    });
  }

  @override
  Future<void> upload(
    List<(Uint8List bytes, String blobId)> blobs, {
    RpcContext? context,
  }) async {
    if (blobs.isEmpty) return;
    await _ensureDirectories();
    Object? firstError;
    await _runParallel(blobs, (entry) async {
      context?.cancellationToken?.throwIfCancelled();
      final (bytes, blobId) = entry;
      try {
        var response = await _request(
          'PUT',
          _objectUri(blobId),
          body: bytes,
          context: context,
        );
        if (response.statusCode == _missingParentStatus) {
          // The vault directory is not there. Rebuild the chain and try once
          // more rather than reporting a 409 the user cannot act on — on
          // WebDAV this is the difference between "sync is broken" and a
          // directory that quietly reappears.
          await _ensureDirectories(force: true);
          response = await _request(
            'PUT',
            _objectUri(blobId),
            body: bytes,
            context: context,
          );
        }
        if (response.statusCode != 200 &&
            response.statusCode != 201 &&
            response.statusCode != 204) {
          // 401/403 is not a failed upload, it is a refused storage: every
          // later call fails the same way until its settings change. Typed so
          // callers can say that instead of retrying forever behind a healthy
          // looking sync.
          firstError ??=
              (response.statusCode == 401 || response.statusCode == 403)
              ? BlobStorageRefused(
                  response.statusCode,
                  response.reasonPhrase ?? '',
                )
              : Exception(
                  'HTTP blob upload failed for $blobId: '
                  '${response.statusCode} ${response.reasonPhrase}',
                );
        }
      } catch (e) {
        firstError ??= e;
      }
    });
    if (firstError != null) throw firstError!;
  }

  /// Statuses that are an ANSWER of "no such object". Everything else that is
  /// not a 2xx and not a refusal is the backend declining to say.
  ///
  /// A HEAD the server would not serve — 405 because it implements only GET,
  /// 429 or 500 after the throttle retries ran out — used to land in the same
  /// bucket as a 404 and read as an absent blob. It is the opposite: 404 is
  /// knowledge, the rest is its absence.
  static const Set<int> _absentStatuses = {404, 410};

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    if (blobIds.isEmpty) return {};
    final first = await _probeBatch(blobIds, context: context);
    // Raised after the batch rather than from inside it, so one verdict is
    // reported for the request instead of eight workers racing to throw.
    _throwIfRefused(first.refused, anyAnswered: first.present.isNotEmpty);
    if (first.unanswered.isEmpty) return first.present;

    // One retry, of the unanswered ids only. Absence still may not be guessed
    // at, so a single dropped connection would otherwise be enough to send the
    // whole batch back unanswered — and on a backend that drops the odd one,
    // a batch of 128 would then almost never get through and the vault would
    // never finish verifying. Two independent failures for the same id is a
    // different claim from one.
    final second = await _probeBatch(
      first.unanswered.toList(),
      context: context,
    );
    _throwIfRefused(
      second.refused,
      anyAnswered: first.present.isNotEmpty || second.present.isNotEmpty,
    );
    if (second.unanswered.isNotEmpty) {
      throw BlobProbeIncomplete(blobIds.length, second.unanswered.length);
    }
    return first.present..addAll(second.present);
  }

  /// Reports a batch's refusal, but only when it is really about the
  /// credentials rather than about one object.
  ///
  /// 401 is unambiguous: no valid credentials were presented, and it says
  /// nothing about any particular blob. 403 is not. S3 answers a HEAD for a
  /// key that is NOT THERE with 403 rather than 404 whenever the caller lacks
  /// `s3:ListBucket` — which a tight BYO bucket policy routinely does. Read as
  /// a refusal, the first genuinely-missing blob on such a bucket would put a
  /// "check your credentials" block in front of the user and abandon the heal,
  /// which is the exact repair this pass exists to perform.
  ///
  /// So a 403 only counts as a refusal when nothing else was served: one
  /// success proves the credentials work, and demotes it to an object we
  /// could not get a verdict on.
  ///
  /// A demotion is said out loud once, and remembered in
  /// [_forbiddenIsAmbiguous]. The consequence of one is that this backend can
  /// never finish a verify pass — every batch holding a blob it answers 403
  /// for comes back incomplete and is postponed forever — and a repair that
  /// silently never runs is indistinguishable from a vault that never needed
  /// one. `runStorageReupload` (settings → Re-upload) is the manual repair
  /// that does not depend on probing.
  void _throwIfRefused(
    BlobStorageRefused? refused, {
    required bool anyAnswered,
  }) {
    if (refused == null) return;
    if (refused.statusCode == 401 || !(anyAnswered || _forbiddenIsAmbiguous)) {
      throw refused;
    }
    if (_forbiddenIsAmbiguous) return;
    _forbiddenIsAmbiguous = true;
    _log.warning(
      'Blob backend answered HTTP ${refused.statusCode} for a blob while '
      'serving others — it cannot distinguish "absent" from "forbidden", so '
      'blob verification cannot reach a verdict on this storage and will keep '
      'postponing. Re-upload from settings is the repair that does not probe.',
    );
  }

  /// Set the first time a 403 arrived alongside a served request.
  ///
  /// Remembered rather than re-derived per call, because the evidence is not
  /// evenly available. [exists] probes up to 128 ids at a time and will nearly
  /// always have a success to weigh a 403 against; [download] is often called
  /// with a single large chunk and has none. Uncarried, the same backend reads
  /// as ambiguous to one method and as a refusal to the other — and the
  /// refusal is the one that stops a pull to tell the user their credentials
  /// are wrong when they are not.
  ///
  /// One-way and per-instance. The backend is rebuilt each engine run
  /// (`BlobStorageProvider.reset`), so a credential that really did go bad is
  /// judged from scratch on the next start rather than excused by what a
  /// previous run saw.
  bool _forbiddenIsAmbiguous = false;

  /// HEADs every id once and sorts the replies into present, absent (dropped),
  /// unanswered, and refused. Draws no conclusion — [exists] does that.
  Future<
    ({Set<String> present, Set<String> unanswered, BlobStorageRefused? refused})
  >
  _probeBatch(List<String> blobIds, {RpcContext? context}) async {
    final present = <String>{};
    final unanswered = <String>{};
    BlobStorageRefused? refused;
    await _runParallel(blobIds, (id) async {
      // Outside the try on purpose: a cancellation is not a failed probe, and
      // swallowing it here is how a preempted verify pass kept probing.
      context?.cancellationToken?.throwIfCancelled();
      try {
        final response = await _request(
          'HEAD',
          _objectUri(id),
          context: context,
        );
        final status = response.statusCode;
        if (status >= 200 && status < 300) {
          present.add(id);
        } else if (status == 401 || status == 403) {
          // 401 wins over a 403 already recorded: only one of the two is
          // unambiguous, and which arrived first is a race between eight
          // workers. Kept as the batch's verdict either way.
          if (refused == null ||
              (status == 401 && refused!.statusCode != 401)) {
            refused = BlobStorageRefused(status, response.reasonPhrase ?? '');
          }
          // Also unanswered, and not redundantly: [_throwIfRefused] can demote
          // a 403 to "about this object", and then this is the only thing
          // keeping the id out of the absent pile it was never proven to be in.
          unanswered.add(id);
        } else if (!_absentStatuses.contains(status)) {
          unanswered.add(id);
        }
      } catch (_) {
        // No reply at all — DNS, socket, timeout. Recorded, never guessed at:
        // see [BlobProbeIncomplete] for what guessing cost.
        unanswered.add(id);
      }
    });
    return (present: present, unanswered: unanswered, refused: refused);
  }

  /// Run [body] for every element in [items] with at most [_concurrency]
  /// in-flight at a time. Errors are swallowed by the caller's [body]
  /// (we deliberately don't fail the whole batch because deleteMany /
  /// upload are best-effort partial-success-OK operations).
  Future<void> _runParallel<E>(
    List<E> items,
    Future<void> Function(E item) body,
  ) async {
    final running = <Future<void>>[];
    for (final item in items) {
      running.add(body(item));
      if (running.length >= _concurrency) {
        await Future.wait(running);
        running.clear();
      }
    }
    if (running.isNotEmpty) await Future.wait(running);
  }

  @override
  Future<List<String>?> listBlobIds({RpcContext? context}) async {
    switch (backend) {
      case HttpBlobBackend.generic:
        return null;
      case HttpBlobBackend.s3:
        return _listS3(context: context);
      case HttpBlobBackend.webdav:
        return _listWebDav(context: context);
    }
  }

  /// S3 ListObjectsV2, paged by continuation token.
  ///
  /// Query parameters are inserted in sorted order because SigV4 signs the
  /// canonical query string, and [S3HttpBlobAuth] passes `uri.query` through
  /// verbatim — an out-of-order query would sign fine here and be rejected
  /// there.
  Future<List<String>?> _listS3({RpcContext? context}) async {
    final ids = <String>[];
    String? token;
    for (var page = 0; page < _maxListPages; page++) {
      context?.cancellationToken?.throwIfCancelled();
      final uri = baseUrl.replace(
        queryParameters: {
          if (token != null) 'continuation-token': token,
          'list-type': '2',
          'max-keys': '1000',
          'prefix': prefix,
        },
      );
      final http.Response response;
      try {
        response = await _request('GET', uri, context: context);
      } catch (_) {
        return page == 0 ? null : ids;
      }
      if (response.statusCode != 200) return page == 0 ? null : ids;
      final body = response.body;
      for (final key in _extractTag(body, 'Key')) {
        final id = key.startsWith(prefix) ? key.substring(prefix.length) : key;
        if (id.isNotEmpty && !id.contains('/')) ids.add(id);
      }
      final truncated = _extractTag(body, 'IsTruncated').firstOrNull;
      if (truncated?.trim().toLowerCase() != 'true') return ids;
      token = _extractTag(body, 'NextContinuationToken').firstOrNull;
      if (token == null || token.isEmpty) return ids;
    }
    return ids;
  }

  /// WebDAV PROPFIND with `Depth: 1` — one level under the vault directory,
  /// which is exactly where blobs live.
  Future<List<String>?> _listWebDav({RpcContext? context}) async {
    context?.cancellationToken?.throwIfCancelled();
    final dirUri = baseUrl.resolve(prefix);
    final http.Response response;
    try {
      response = await _request(
        'PROPFIND',
        dirUri,
        body: Uint8List.fromList(utf8.encode(_propfindBody)),
        extraHeaders: const {'depth': '1', 'content-type': 'application/xml'},
        context: context,
      );
    } catch (_) {
      return null;
    }
    // 207 Multi-Status is the success case; 404 means the vault directory is
    // not there, which is an empty bucket rather than a failure to answer.
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 207 && response.statusCode != 200) return null;

    final dirPath = dirUri.path;
    final ids = <String>[];
    for (final href in _extractTag(response.body, 'href')) {
      final path = Uri.parse(href.trim()).path;
      if (!path.startsWith(dirPath)) continue;
      final id = Uri.decodeComponent(path.substring(dirPath.length));
      // Skip the collection itself and anything nested below it.
      if (id.isEmpty || id.endsWith('/') || id.contains('/')) continue;
      ids.add(id);
    }
    return ids;
  }

  static const String _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop>'
      '</D:propfind>';

  /// Bound on paging, so a backend that keeps handing back the same
  /// continuation token cannot spin forever.
  static const int _maxListPages = 1000;

  /// Pulls the text of every `<tag>` occurrence, namespace prefix and
  /// attributes ignored.
  ///
  /// A hand-rolled extractor rather than an XML dependency: both responses are
  /// machine-generated, and the two things wanted from them — object keys and
  /// hrefs — are leaf text nodes. Pulling in a parser to read one element type
  /// out of two documents would cost every dart2js user bundle size for
  /// nothing. Values are not entity-decoded, which is safe for the ids here
  /// (hex hashes) and handled by [Uri.decodeComponent] for hrefs.
  static Iterable<String> _extractTag(String xml, String tag) sync* {
    final re = RegExp(
      '<(?:[A-Za-z0-9_.-]+:)?$tag(?:\\s[^>]*)?>([^<]*)</(?:[A-Za-z0-9_.-]+:)?$tag>',
      caseSensitive: false,
    );
    for (final m in re.allMatches(xml)) {
      final value = m.group(1);
      if (value != null) yield value;
    }
  }

  /// Ensures the [prefix] chain (`blobs/<vaultId>/`) exists on the backend.
  ///
  /// [force] re-runs it even when a previous run succeeded — the 409 path uses
  /// it, because "we created it once" says nothing about whether it is there
  /// now. Concurrent callers join the run in flight instead of each starting
  /// their own; MKCOL is idempotent, the round trips are not.
  Future<void> _ensureDirectories({bool force = false}) {
    // S3 has no directories to create: `blobs/<id>` is one flat key. Sending
    // MKCOL there was always pointless, and since the success latch started
    // closing only on a confirmed result it became pointless once per upload
    // batch rather than once per session.
    if (backend == HttpBlobBackend.s3) return Future<void>.value();
    if (_dirsCreated && !force) return Future<void>.value();
    return _dirsInFlight ??= _createDirectories().whenComplete(() {
      _dirsInFlight = null;
    });
  }

  /// Sends MKCOL for each path segment in [prefix]. 201 = created, 405 =
  /// already exists or unsupported, 301 = redirect (common on non-WebDAV
  /// servers). Anything else — or a thrown request — means we do NOT know the
  /// directory is there, so the success latch stays open and the next upload
  /// tries again. S3 needs none of this and answers whatever it likes; its
  /// uploads succeed regardless, so a permanently-open latch costs it one
  /// wasted MKCOL chain per session, not correctness.
  Future<void> _createDirectories() async {
    final segments = prefix.split('/').where((s) => s.isNotEmpty).toList();
    var path = '';
    for (final segment in segments) {
      path += '$segment/';
      final uri = baseUrl.resolve(path);
      try {
        // The status is deliberately not inspected — see the latch note below.
        await _request('MKCOL', uri, retryThrottle: false);
      } catch (_) {
        // Nor is a thrown request fatal: the PUT that follows reports 409 if
        // the collection really is missing, and that is what reopens the latch.
      }
    }
    // Latched whatever happened, and the 409 handler is what reopens it.
    //
    // Three designs were tried. Latching only on a confirmed 201/405/301 looks
    // more careful and is worse: a server that answers MKCOL with anything
    // else — and they vary — can never close the latch, so the chain re-runs
    // before EVERY upload batch, two round trips each, on a backend where the
    // round trip is the whole cost. Never retrying at all is worse still: one
    // failed first attempt and the directory is never created again.
    //
    // Reacting to 409 gets both: one chain per session in the normal case, and
    // a rebuild exactly when a PUT reports the collection missing.
    _dirsCreated = true;
  }

  Uri _objectUri(String blobId) => baseUrl.resolve('$prefix$blobId');

  /// Sends one request, waiting out a throttled backend rather than reporting
  /// it as a failure.
  ///
  /// The gRPC storage has done this all along — it retries the server's
  /// RESOURCE_EXHAUSTED with backoff — and the HTTP one did not, so a BYO
  /// backend under load produced a run of ordinary errors and the startup
  /// pass's systemic-failure guard ended the pass. Same signal, opposite
  /// outcome, purely because of which transport it arrived on.
  ///
  /// Retries stay inside the storage for the same reason they do there: the
  /// object calls are idempotent (content-addressed PUT, GET, HEAD), so a
  /// re-send is always safe, and no caller has to learn what 429 means.
  /// [retryThrottle] is off for the one call whose status is deliberately not
  /// read. MKCOL answers 503 on servers that simply do not implement it, and
  /// backing off four times for a response nobody inspects would put twelve
  /// seconds in front of every upload batch on exactly those servers.
  Future<http.Response> _request(
    String method,
    Uri uri, {
    Uint8List? body,
    Map<String, String>? extraHeaders,
    RpcContext? context,
    bool retryThrottle = true,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final response = await _sendOnce(method, uri, body, extraHeaders);
      if (!retryThrottle ||
          !_throttleStatuses.contains(response.statusCode) ||
          attempt >= _maxThrottleAttempts - 1) {
        return response;
      }
      // Retry-After first: the server knows how long its own queue is, and no
      // backoff curve guesses that better than being told.
      final wait =
          _retryAfter(response) ??
          _throttleBackoff[attempt.clamp(0, _throttleBackoff.length - 1)];
      // Said out loud. Waiting was silent, and a request sitting in backoff
      // looks from the log exactly like one that has hung — the two need
      // opposite responses, and a pull that went quiet for six minutes could
      // not be told apart from a pull that was patiently doing as it was
      // told. Up to four attempts at up to thirty seconds each is minutes of
      // legitimate silence per request.
      _log.warning(
        'Blob backend throttled: HTTP ${response.statusCode}, '
        'waiting ${wait.inMilliseconds}ms before attempt ${attempt + 2} '
        'of $_maxThrottleAttempts',
      );
      await _sleep(wait, context);
    }
  }

  /// How long to wait for a response to BEGIN. A backend that has not
  /// answered at all by now is not answering.
  static const Duration _headersTimeout = Duration(seconds: 30);

  /// How long a transfer may go SILENT before it is treated as dead. Between
  /// chunks, not in total, so a slow-but-moving transfer is left alone.
  static const Duration _idleTimeout = Duration(seconds: 20);

  /// Collects [source] into one buffer, failing if it ever goes quiet for
  /// [_idleTimeout].
  ///
  /// The timer is re-armed by each chunk, so what it measures is silence
  /// rather than duration — a large file crawling in at a few hundred KB/s
  /// keeps resetting it and is never cut off, while a connection that has
  /// simply stopped is caught in twenty seconds instead of never.
  static Future<Uint8List> _readBounded(Stream<List<int>> source) {
    final chunks = <List<int>>[];
    var length = 0;
    final done = Completer<Uint8List>();
    Timer? idle;
    late StreamSubscription<List<int>> sub;

    void fail(Object error, [StackTrace? stack]) {
      if (done.isCompleted) return;
      idle?.cancel();
      unawaited(sub.cancel());
      done.completeError(error, stack);
    }

    void arm() {
      idle?.cancel();
      idle = Timer(
        _idleTimeout,
        () => fail(TimeoutException('no data for ${_idleTimeout.inSeconds}s')),
      );
    }

    sub = source.listen(
      (chunk) {
        chunks.add(chunk);
        length += chunk.length;
        arm();
      },
      onError: fail,
      onDone: () {
        if (done.isCompleted) return;
        idle?.cancel();
        final out = Uint8List(length);
        var offset = 0;
        for (final chunk in chunks) {
          out.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        }
        done.complete(out);
      },
      cancelOnError: true,
    );
    arm();
    return done.future;
  }

  Future<http.Response> _sendOnce(
    String method,
    Uri uri,
    Uint8List? body,
    Map<String, String>? extraHeaders,
  ) async {
    final headers = auth.sign(method, uri, body);
    if (body != null) {
      headers['content-length'] = body.length.toString();
    }
    if (extraHeaders != null) headers.addAll(extraHeaders);

    final request = http.Request(method, uri);
    request.headers.addAll(headers);
    if (body != null) request.bodyBytes = body;

    try {
      // Bounded, because it was not.
      //
      // The invariant is already written down for the gRPC path: a blob
      // transfer on the pull path must be timeout-bounded, since the pull is a
      // single lane and a transfer that never finishes stops everything behind
      // it. It was never applied here, so on BYO storage a stalled response
      // hung its group, the group hung its batch, and the batch hung the pull.
      //
      // IDLE, not total, for the reason the gRPC path gives: a 17 MB
      // attachment over a slow link is slow legitimately, and only true
      // silence is a fault. Measured here at five large blobs in 278 seconds —
      // any total bound tight enough to catch a hang would have cut that.
      //
      // Written with an explicit timer rather than `Stream.timeout`, which
      // never completes under `fakeAsync` — the harness the throttle tests
      // run in. Isolated: `fromStream`, a bare `await for`, and a future
      // timeout all behave; only the stream operator hangs. A bound that
      // cannot be tested is not one worth having.
      final streamed = await _http.send(request).timeout(_headersTimeout);
      final bytes = await _readBounded(streamed.stream);
      return http.Response.bytes(
        bytes,
        streamed.statusCode,
        request: streamed.request,
        headers: streamed.headers,
        isRedirect: streamed.isRedirect,
        persistentConnection: streamed.persistentConnection,
        reasonPhrase: streamed.reasonPhrase,
      );
    } catch (e) {
      throw Exception('HTTP $method $uri failed: $e');
    }
  }

  /// `Retry-After` in delta-seconds, bounded. The HTTP-date form is legal and
  /// deliberately unread: parsing it needs a clock this code has no business
  /// trusting (a device with a skewed clock would compute a wait of hours),
  /// and falling back to the backoff curve is the safe reading of it.
  static Duration? _retryAfter(http.Response response) {
    final raw = response.headers['retry-after'];
    if (raw == null) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds == null || seconds <= 0) return null;
    final wait = Duration(seconds: seconds);
    return wait > _maxThrottleWait ? _maxThrottleWait : wait;
  }

  /// Waits in one-second slices so a preempted background task stops within a
  /// second of being asked, instead of at the end of a thirty-second sleep.
  /// The engine's maintenance tier yields the connection to interactive edits;
  /// an uninterruptible sleep in here would hold it anyway.
  static Future<void> _sleep(Duration total, RpcContext? context) async {
    const slice = Duration(seconds: 1);
    var left = total;
    while (left > Duration.zero) {
      context?.cancellationToken?.throwIfCancelled();
      final step = left < slice ? left : slice;
      await Future<void>.delayed(step);
      left -= step;
    }
    context?.cancellationToken?.throwIfCancelled();
  }
}
