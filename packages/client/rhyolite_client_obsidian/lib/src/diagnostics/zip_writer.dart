import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart' show gzipEncode;

/// One file to put in the archive.
class ZipEntry {
  const ZipEntry(this.name, this.text);

  /// Path inside the archive, `/` separated.
  final String name;
  final String text;
}

/// Builds a ZIP archive with deflated entries.
///
/// ZIP rather than a single gzip stream because gzip has no notion of files:
/// making one artifact out of many meant concatenating them, which is what
/// forced a size cap and erased the boundaries that say which file and which
/// session a reader is looking at. ZIP is also the one container every desktop
/// and both phones open without installing anything.
///
/// The compression is not implemented here. A gzip stream is a 10-byte header,
/// the raw deflate data, and an 8-byte trailer holding the CRC32 and the
/// uncompressed size — which are exactly the two fields a ZIP entry needs. So
/// [gzipEncode], already tuned per platform (native Compression Streams on the
/// web, zlib on the VM), is called per entry and its output is unwrapped.
/// Writing a deflate implementation, or a CRC32, to achieve the same would be
/// a second thing to get wrong.
///
/// Entries are compressed one at a time, so peak memory is one log file plus
/// the archive being built — never the whole log set at once. That is the
/// point: it is what lets the report carry everything without a cap.
Future<Uint8List> buildZip(List<ZipEntry> entries) async {
  final out = BytesBuilder(copy: false);
  final directory = BytesBuilder(copy: false);
  var count = 0;

  for (final entry in entries) {
    final nameBytes = utf8.encode(entry.name);
    final raw = utf8.encode(entry.text);
    final deflated = await _rawDeflate(raw);

    final offset = out.length;
    final local = BytesBuilder(copy: false)
      ..add(_u32(0x04034b50)) // local file header
      ..add(_u16(20)) // version needed: 2.0, deflate
      // Bit 11: the name is UTF-8. Without it a non-ASCII name is read in the
      // unpacker's local codepage.
      ..add(_u16(0x0800))
      ..add(_u16(deflated.method))
      ..add(_u16(0)) // modification time — not tracked
      ..add(_u16(0)) // modification date
      ..add(_u32(deflated.crc))
      ..add(_u32(deflated.bytes.length))
      ..add(_u32(raw.length))
      ..add(_u16(nameBytes.length))
      ..add(_u16(0)) // no extra field
      ..add(nameBytes)
      ..add(deflated.bytes);
    out.add(local.takeBytes());

    directory
      ..add(_u32(0x02014b50)) // central directory header
      ..add(_u16(20)) // version made by
      ..add(_u16(20)) // version needed
      ..add(_u16(0x0800))
      ..add(_u16(deflated.method))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(deflated.crc))
      ..add(_u32(deflated.bytes.length))
      ..add(_u32(raw.length))
      ..add(_u16(nameBytes.length))
      ..add(_u16(0)) // extra
      ..add(_u16(0)) // comment
      ..add(_u16(0)) // disk number
      ..add(_u16(0)) // internal attributes
      ..add(_u32(0)) // external attributes
      ..add(_u32(offset))
      ..add(nameBytes);
    count++;
  }

  final dirBytes = directory.takeBytes();
  final dirOffset = out.length;
  out
    ..add(dirBytes)
    ..add(_u32(0x06054b50)) // end of central directory
    ..add(_u16(0)) // this disk
    ..add(_u16(0)) // disk with the directory
    ..add(_u16(count))
    ..add(_u16(count))
    ..add(_u32(dirBytes.length))
    ..add(_u32(dirOffset))
    ..add(_u16(0)); // no comment
  return out.takeBytes();
}

/// Deflate data plus the CRC32 and method a ZIP entry needs.
class _Deflated {
  const _Deflated(this.bytes, this.crc, this.method);

  final Uint8List bytes;
  final int crc;

  /// 8 = deflate, 0 = stored. Stored is the fallback for the case where the
  /// gzip output cannot be unwrapped: a bigger archive still opens.
  final int method;
}

/// Compresses with [gzipEncode] and unwraps the gzip framing.
Future<_Deflated> _rawDeflate(List<int> raw) async {
  try {
    final gz = await gzipEncode(Uint8List.fromList(raw));
    final start = _gzipBodyStart(gz);
    if (start > 0 && gz.length >= start + 8) {
      final body = Uint8List.sublistView(gz, start, gz.length - 8);
      // The trailer's CRC32 is over the uncompressed data — the same value
      // ZIP stores, so it never has to be computed here.
      final crc =
          gz[gz.length - 8] |
          (gz[gz.length - 7] << 8) |
          (gz[gz.length - 6] << 16) |
          (gz[gz.length - 5] << 24);
      return _Deflated(body, crc, 8);
    }
  } catch (_) {
    // Fall through to stored.
  }
  return _Deflated(Uint8List.fromList(raw), _crc32(raw), 0);
}

/// Where the deflate data begins in a gzip stream, or -1 if this is not one.
///
/// Parsed rather than assumed to be 10 bytes: the optional FEXTRA, FNAME,
/// FCOMMENT and FHCRC fields are permitted, and a producer that emits a
/// filename would otherwise put its bytes into the deflate stream.
int _gzipBodyStart(Uint8List gz) {
  if (gz.length < 18 || gz[0] != 0x1f || gz[1] != 0x8b || gz[2] != 8) return -1;
  final flg = gz[3];
  var i = 10;
  if (flg & 0x04 != 0) {
    // FEXTRA: two length bytes, then that many bytes.
    if (i + 2 > gz.length) return -1;
    i += 2 + (gz[i] | (gz[i + 1] << 8));
  }
  for (final bit in [0x08, 0x10]) {
    // FNAME, FCOMMENT: NUL-terminated.
    if (flg & bit == 0) continue;
    while (i < gz.length && gz[i] != 0) {
      i++;
    }
    i++;
  }
  if (flg & 0x02 != 0) i += 2; // FHCRC
  return i < gz.length ? i : -1;
}

/// Only reached when the gzip framing could not be unwrapped and an entry is
/// stored uncompressed.
int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Uint8List _u16(int v) => Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF]);

Uint8List _u32(int v) => Uint8List.fromList([
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
]);
