import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Portable gzip, and the default everywhere except the web.
///
/// On the Dart VM `package:archive` delegates to `dart:io`'s zlib, so this is
/// already native there. On the web it falls back to its own Deflate in Dart —
/// single-threaded and roughly two orders of magnitude slower, which is exactly
/// what `gzip_codec_web.dart` exists to avoid. This file stays the fallback for
/// web engines without the Compression Streams API.
String get gzipBackendName => 'archive';

Future<Uint8List> gzipEncode(Uint8List bytes) async =>
    Uint8List.fromList(GZipEncoder().encode(bytes));

/// Returns null when [bytes] are not a gzip stream — blobs uploaded before the
/// gzip layer existed must pass through untouched, so a decode failure is an
/// expected answer rather than an error.
Future<Uint8List?> gzipDecode(Uint8List bytes) async {
  try {
    return Uint8List.fromList(GZipDecoder().decodeBytes(bytes));
  } catch (_) {
    return null;
  }
}
