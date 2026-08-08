import 'dart:convert';
import 'dart:typed_data';

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
  }) : _http = httpClient ?? http.Client();

  /// Which backend this is. Only the operations that genuinely differ branch
  /// on it; the object CRUD does not.
  final HttpBlobBackend backend;

  final Uri baseUrl;
  final String prefix;
  final IHttpBlobAuth auth;
  final http.Client _http;

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

  @override
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    if (blobIds.isEmpty) return {};
    final result = <String, Uint8List>{};
    final futures = <Future<void>>[];
    for (final blobId in blobIds) {
      context?.cancellationToken?.throwIfCancelled();
      futures.add(() async {
        try {
          final uri = _objectUri(blobId);
          final response = await _request('GET', uri);
          if (response.statusCode == 200) {
            result[blobId] = response.bodyBytes;
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
    return result;
  }

  /// Maximum simultaneous HTTP requests. WebDAV servers usually cope with
  /// 8 connections per client; tune lower if a real server complains.
  static const int _concurrency = 8;

  @override
  Future<void> deleteMany(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    if (blobIds.isEmpty) return;
    await _runParallel(blobIds, (id) async {
      context?.cancellationToken?.throwIfCancelled();
      try {
        await _request('DELETE', _objectUri(id));
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
        var response = await _request('PUT', _objectUri(blobId), body: bytes);
        if (response.statusCode == _missingParentStatus) {
          // The vault directory is not there. Rebuild the chain and try once
          // more rather than reporting a 409 the user cannot act on — on
          // WebDAV this is the difference between "sync is broken" and a
          // directory that quietly reappears.
          await _ensureDirectories(force: true);
          response = await _request('PUT', _objectUri(blobId), body: bytes);
        }
        if (response.statusCode != 200 &&
            response.statusCode != 201 &&
            response.statusCode != 204) {
          firstError ??= Exception(
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

  @override
  Future<Set<String>> exists(
    List<String> blobIds, {
    RpcContext? context,
  }) async {
    if (blobIds.isEmpty) return {};
    final present = <String>{};
    await _runParallel(blobIds, (id) async {
      context?.cancellationToken?.throwIfCancelled();
      try {
        final response = await _request('HEAD', _objectUri(id));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          present.add(id);
        }
      } catch (_) {
        // Treat probe failure as "unknown" — conservatively absent, so the
        // caller may re-upload (idempotent, content-addressed) rather than
        // skip a possibly-missing blob.
      }
    });
    return present;
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
      final uri = baseUrl.replace(queryParameters: {
        if (token != null) 'continuation-token': token,
        'list-type': '2',
        'max-keys': '1000',
        'prefix': prefix,
      });
      final http.Response response;
      try {
        response = await _request('GET', uri);
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
    var allPresent = true;
    for (final segment in segments) {
      path += '$segment/';
      final uri = baseUrl.resolve(path);
      try {
        final response = await _request('MKCOL', uri);
        if (response.statusCode != 201 &&
            response.statusCode != 405 &&
            response.statusCode != 301) {
          allPresent = false;
        }
      } catch (_) {
        allPresent = false;
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

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Uint8List? body,
    Map<String, String>? extraHeaders,
  }) async {
    final headers = auth.sign(method, uri, body);
    if (body != null) {
      headers['content-length'] = body.length.toString();
    }
    if (extraHeaders != null) headers.addAll(extraHeaders);

    final request = http.Request(method, uri);
    request.headers.addAll(headers);
    if (body != null) request.bodyBytes = body;

    try {
      final streamed = await _http.send(request);
      return http.Response.fromStream(streamed);
    } catch (e) {
      throw Exception('HTTP $method $uri failed: $e');
    }
  }
}
