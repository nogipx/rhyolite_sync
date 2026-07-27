import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'gzip_codec_archive.dart' as portable;

/// Gzip through the browser's native Compression Streams API.
///
/// The portable encoder runs Deflate in Dart, which on dart2js is
/// single-threaded, synchronous and slow enough to freeze the UI for hundreds
/// of milliseconds per megabyte — the dominant cost of every blob upload, and
/// the reason a plugin set took minutes to sync. `CompressionStream` hands the
/// same work to the engine's native zlib, like `AesGcm` already hands
/// encryption to WebCrypto.
///
/// Availability is checked at runtime (Safari only gained it in 16.4), and any
/// failure permanently drops this session back to the portable path — a slow
/// upload beats a broken one.
/// Reports what is ACTUALLY in use, not what this build was compiled for —
/// a device silently on the slow fallback is the thing worth seeing in a log.
String get gzipBackendName =>
    _supported ? 'compression-streams' : 'archive (no native support)';

@JS('globalThis')
external JSObject get _global;

@JS('CompressionStream')
extension type _CompressionStream._(JSObject _) implements JSObject {
  external factory _CompressionStream(String format);
}

@JS('DecompressionStream')
extension type _DecompressionStream._(JSObject _) implements JSObject {
  external factory _DecompressionStream(String format);
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts);
  external _ReadableStream stream();
}

extension type _ReadableStream._(JSObject _) implements JSObject {
  external _ReadableStream pipeThrough(JSObject transform);
}

@JS('Response')
extension type _Response._(JSObject _) implements JSObject {
  external factory _Response(JSAny? body);
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

/// Set to false the first time the native path misbehaves, so one failure
/// costs one operation rather than being re-attempted forever.
bool _nativeUsable = true;

bool get _supported =>
    _nativeUsable &&
    _global.has('CompressionStream') &&
    _global.has('DecompressionStream') &&
    _global.has('Response') &&
    _global.has('Blob');

Future<Uint8List> _pipe(Uint8List bytes, JSObject transform) async {
  final blob = _Blob([bytes.toJS].toJS);
  final piped = blob.stream().pipeThrough(transform);
  final buffer = await _Response(piped).arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

Future<Uint8List> gzipEncode(Uint8List bytes) async {
  if (!_supported) return portable.gzipEncode(bytes);
  try {
    return await _pipe(bytes, _CompressionStream('gzip'));
  } catch (_) {
    _nativeUsable = false;
    return portable.gzipEncode(bytes);
  }
}

Future<Uint8List?> gzipDecode(Uint8List bytes) async {
  if (!_supported) return portable.gzipDecode(bytes);
  // Blobs predating the gzip layer must pass through, and asking the native
  // decoder about them costs a stream teardown per blob. The two-byte magic
  // answers it for free.
  if (bytes.length < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b) return null;
  try {
    return await _pipe(bytes, _DecompressionStream('gzip'));
  } catch (_) {
    // The magic says gzip, so this is corruption or a native path that lied
    // about itself. Give the portable decoder a turn before giving up.
    return portable.gzipDecode(bytes);
  }
}
