// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_util' as jsu;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:obsidian_dart/obsidian_dart.dart' show obsidianModule;

/// [http.Client] that bypasses CORS by using platform-native HTTP.
///
/// - Desktop (Electron): uses Node.js `https.request` (always available)
/// - Mobile: uses Obsidian's `requestUrl` API
class ObsidianHttpClient extends http.BaseClient {
  bool get _isElectron => jsu.hasProperty(jsu.globalThis, 'Buffer');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_isElectron) {
      return _sendNodeHttp(request);
    } else {
      return _sendRequestUrl(request);
    }
  }

  // ---------------------------------------------------------------------------
  // Desktop: Node.js http/https module
  // ---------------------------------------------------------------------------

  Future<http.StreamedResponse> _sendNodeHttp(http.BaseRequest request) async {
    final body = request is http.Request ? request.bodyBytes : Uint8List(0);
    final uri = request.url;
    final module = uri.scheme == 'https' ? 'https' : 'http';

    final nodeModule = jsu.callMethod<JSObject>(
      jsu.globalThis, 'require', [module],
    );

    final completer = Completer<http.StreamedResponse>();

    final options = jsu.jsify({
      'hostname': uri.host,
      'port': uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80),
      'path': uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path,
      'method': request.method,
      'headers': request.headers,
    });

    final req = jsu.callMethod<JSObject>(nodeModule, 'request', [
      options,
      jsu.allowInterop((JSObject res) {
        final statusCode = jsu.getProperty<int>(res, 'statusCode');

        final responseHeaders = <String, String>{};
        try {
          final rawHeaders = jsu.getProperty<Object?>(res, 'headers');
          if (rawHeaders != null && rawHeaders is JSObject) {
            final objectCtor =
                jsu.getProperty<JSObject>(jsu.globalThis, 'Object');
            final keys = jsu.callMethod<List<Object?>>(
                objectCtor, 'keys', [rawHeaders]);
            for (final key in keys) {
              if (key is String) {
                final val = jsu.getProperty<Object?>(rawHeaders, key);
                if (val != null) responseHeaders[key] = val.toString();
              }
            }
          }
        } catch (_) {}

        final chunks = <List<int>>[];
        jsu.callMethod<void>(res, 'on', [
          'data',
          jsu.allowInterop((JSAny? chunk) {
            if (chunk == null) return;
            final jsChunk = chunk as JSObject;
            final length = jsu.getProperty<int>(jsChunk, 'length');
            final bytes = Uint8List(length);
            for (var i = 0; i < length; i++) {
              bytes[i] = jsu.callMethod<int>(jsChunk, 'readUInt8', [i]);
            }
            chunks.add(bytes);
          }),
        ]);

        jsu.callMethod<void>(res, 'on', [
          'end',
          jsu.allowInterop(() {
            final builder = BytesBuilder();
            for (final c in chunks) {
              builder.add(c);
            }
            if (!completer.isCompleted) {
              completer.complete(http.StreamedResponse(
                Stream.value(builder.takeBytes()),
                statusCode,
                headers: responseHeaders,
                request: request,
              ));
            }
          }),
        ]);
      }),
    ]);

    jsu.callMethod<void>(req, 'on', [
      'error',
      jsu.allowInterop((JSAny? err) {
        if (!completer.isCompleted) {
          final message = err != null
              ? jsu.getProperty<String>(err as JSObject, 'message')
              : 'unknown error';
          completer.completeError(Exception('Node HTTP error: $message'));
        }
      }),
    ]);

    if (body.isNotEmpty) {
      final nodeBuffer = jsu.callMethod<JSObject>(
        jsu.getProperty<JSObject>(jsu.globalThis, 'Buffer'),
        'from',
        [body.toJS],
      );
      jsu.callMethod<void>(req, 'write', [nodeBuffer]);
    }

    jsu.callMethod<void>(req, 'end', []);
    return completer.future;
  }

  // ---------------------------------------------------------------------------
  // Mobile: Obsidian requestUrl
  // ---------------------------------------------------------------------------

  Future<http.StreamedResponse> _sendRequestUrl(http.BaseRequest request) async {
    final body = request is http.Request ? request.bodyBytes : Uint8List(0);

    final requestUrlFn =
        jsu.getProperty<JSFunction>(obsidianModule(), 'requestUrl');

    final options = jsu.newObject<JSObject>();
    jsu.setProperty(options, 'url', request.url.toString());
    jsu.setProperty(options, 'method', request.method);
    jsu.setProperty(options, 'contentType',
        request.headers['content-type'] ?? 'application/octet-stream');

    final jsHeaders = jsu.newObject<JSObject>();
    request.headers.forEach((key, value) {
      jsu.setProperty(jsHeaders, key, value);
    });
    jsu.setProperty(options, 'headers', jsHeaders);

    if (body.isNotEmpty) {
      final jsArray = body.toJS;
      final arrayBuffer = jsu.getProperty<JSAny>(jsArray, 'buffer');
      jsu.setProperty(options, 'body', arrayBuffer);
    }

    final JSAny? promise = requestUrlFn.callAsFunction(null, options);
    if (promise == null) {
      throw Exception('requestUrl returned null');
    }

    final JSObject result = await jsu.promiseToFuture<JSObject>(promise);

    int status;
    try {
      status = jsu.getProperty<int>(result, 'status');
    } catch (_) {
      status = 0;
    }

    Uint8List responseBytes;
    try {
      final ab = jsu.getProperty<JSAny?>(result, 'arrayBuffer');
      if (ab != null && ab is JSArrayBuffer) {
        responseBytes = ab.toDart.asUint8List();
      } else {
        responseBytes = Uint8List(0);
      }
    } catch (_) {
      responseBytes = Uint8List(0);
    }

    final responseHeaders = <String, String>{};
    try {
      final headersObj = jsu.getProperty<JSAny?>(result, 'headers');
      if (headersObj != null && headersObj is JSObject) {
        final objectCtor =
            jsu.getProperty<JSObject>(jsu.globalThis, 'Object');
        final keys =
            jsu.callMethod<List<Object?>>(objectCtor, 'keys', [headersObj]);
        for (final key in keys) {
          if (key is String) {
            final val = jsu.getProperty<Object?>(headersObj, key);
            if (val != null) responseHeaders[key.toLowerCase()] = val.toString();
          }
        }
      }
    } catch (_) {}

    return http.StreamedResponse(
      Stream.value(responseBytes),
      status,
      headers: responseHeaders,
      request: request,
    );
  }
}
