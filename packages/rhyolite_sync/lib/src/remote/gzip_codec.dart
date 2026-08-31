import 'dart:typed_data';

import 'gzip_codec_archive.dart'
    if (dart.library.js_interop) 'gzip_codec_web.dart'
    as impl;

/// Gzip, on whatever the platform does fastest: `dart:io`'s zlib on the VM
/// (via `package:archive`), the Compression Streams API on the web, and Dart's
/// own Deflate only where neither exists.
///
/// Async by contract even where the work is synchronous, so the web path can
/// hand the bytes to the engine and yield instead of blocking the UI thread.
Future<Uint8List> gzipEncode(Uint8List bytes) => impl.gzipEncode(bytes);

/// Decompresses [bytes], or returns null when they are not a gzip stream —
/// blobs stored before the gzip layer existed pass through unchanged.
Future<Uint8List?> gzipDecode(Uint8List bytes) => impl.gzipDecode(bytes);

/// Which implementation this build resolved to. Reported once at startup so a
/// device silently stuck on the slow path is visible in the logs.
String get gzipBackendName => impl.gzipBackendName;
