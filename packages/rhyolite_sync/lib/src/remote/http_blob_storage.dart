import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// [IBlobStorage] that stores blobs as HTTP objects at `<baseUrl>/<prefix><blobId>`.
///
/// Works with any HTTP-based backend: S3, WebDAV, Cloudflare R2,
/// Backblaze B2, plain HTTP file servers -- as long as:
/// - PUT `/<key>` stores an object
/// - GET `/<key>` returns the object bytes
///
/// Authentication is delegated to [IHttpBlobAuth].
class HttpBlobStorage implements IBlobStorage {
  HttpBlobStorage({
    required this.baseUrl,
    required this.prefix,
    required this.auth,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final Uri baseUrl;
  final String prefix;
  final IHttpBlobAuth auth;
  final http.Client _http;
  bool _dirsCreated = false;

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
        final response = await _request('PUT', _objectUri(blobId), body: bytes);
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

  /// Ensures parent directories exist for WebDAV backends.
  /// Sends MKCOL for each path segment in [prefix]. Ignores 405 (already
  /// exists / not supported) and 301 (redirect, common on non-WebDAV servers).
  Future<void> _ensureDirectories() async {
    if (_dirsCreated) return;
    final segments = prefix.split('/').where((s) => s.isNotEmpty).toList();
    var path = '';
    for (final segment in segments) {
      path += '$segment/';
      final uri = baseUrl.resolve(path);
      try {
        final response = await _request('MKCOL', uri);
        // 201 = created, 405 = exists or not supported, 301 = redirect
        if (response.statusCode != 201 &&
            response.statusCode != 405 &&
            response.statusCode != 301) {
          // Ignore errors -- S3 doesn't need MKCOL, WebDAV does.
        }
      } catch (_) {
        // Ignore -- best effort.
      }
    }
    _dirsCreated = true;
  }

  Uri _objectUri(String blobId) => baseUrl.resolve('$prefix$blobId');

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Uint8List? body,
  }) async {
    final headers = auth.sign(method, uri, body);
    if (body != null) {
      headers['content-length'] = body.length.toString();
    }

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
