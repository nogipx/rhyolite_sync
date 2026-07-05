import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Content-defined chunking using a Gear-hash based rolling hash (FastCDC-like).
///
/// Splits binary data into variable-size chunks where boundaries are determined
/// by content, not position. This means a small edit in the middle of a file
/// only affects 1-2 chunks, not everything after the edit point.
class ContentDefinedChunker {
  final int minChunkSize;
  final int avgChunkSize;
  final int maxChunkSize;

  /// Bitmask for the "normal" zone (between min and avg).
  /// More bits set = harder to match = larger chunks on average.
  final int _maskS;

  /// Bitmask for the "eager" zone (between avg and max).
  /// Fewer bits set = easier to match = more likely to cut.
  final int _maskL;

  /// Computes a chunk's content-address id. Defaults to raw `sha256`; the
  /// engine injects a keyed `HMAC-SHA256(vaultSubkey, …)` so blob ids can't be
  /// recomputed from a known plaintext (see [VaultCipher.deriveBlobIdKey]).
  final String Function(Uint8List) _hasher;

  ContentDefinedChunker({
    this.minChunkSize = 512 * 1024,
    this.avgChunkSize = 1024 * 1024,
    this.maxChunkSize = 4 * 1024 * 1024,
    String Function(Uint8List)? blobIdHasher,
  })  : _hasher = blobIdHasher ?? _sha256Hex,
        _maskS = _buildMask(_bitsForAvg(avgChunkSize) + 1),
        _maskL = _buildMask(_bitsForAvg(avgChunkSize) - 1);

  static String _sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

  static int _bitsForAvg(int avg) {
    var bits = 0;
    var v = avg;
    while (v > 1) {
      v >>= 1;
      bits++;
    }
    return bits;
  }

  static int _buildMask(int bits) => (1 << bits) - 1;

  /// Splits [data] into content-defined chunks and returns a [BlobManifest]
  /// plus a map of chunkHash -> chunkBytes.
  ({BlobManifest manifest, Map<String, Uint8List> chunks}) call(
    Uint8List data,
  ) {
    if (data.isEmpty) {
      return (
        manifest: const BlobManifest(chunks: [], totalSize: 0),
        chunks: <String, Uint8List>{},
      );
    }

    final chunkRefs = <ChunkRef>[];
    final chunkMap = <String, Uint8List>{};
    var offset = 0;
    var order = 0;

    while (offset < data.length) {
      final remaining = data.length - offset;

      int chunkEnd;
      if (remaining <= minChunkSize) {
        chunkEnd = data.length;
      } else {
        chunkEnd = _findBoundary(data, offset);
      }

      final chunkBytes = Uint8List.sublistView(data, offset, chunkEnd);
      final hash = _hasher(chunkBytes);

      chunkRefs.add(ChunkRef(hash: hash, size: chunkBytes.length, order: order));
      chunkMap[hash] = chunkBytes;

      offset = chunkEnd;
      order++;
    }

    return (
      manifest: BlobManifest(chunks: chunkRefs, totalSize: data.length),
      chunks: chunkMap,
    );
  }

  int _findBoundary(Uint8List data, int start) {
    final end = data.length;
    var fp = 0;

    // Skip min zone -- no cuts allowed here.
    final minEnd = (start + minChunkSize).clamp(0, end);
    for (var i = start; i < minEnd; i++) {
      fp = (fp << 1) + _gearTable[data[i]];
    }

    // Normal zone (min..avg): use stricter mask -> larger avg chunks.
    final avgEnd = (start + avgChunkSize).clamp(0, end);
    for (var i = minEnd; i < avgEnd; i++) {
      fp = (fp << 1) + _gearTable[data[i]];
      if ((fp & _maskS) == 0) return i + 1;
    }

    // Eager zone (avg..max): use relaxed mask -> more likely to cut.
    final maxEnd = (start + maxChunkSize).clamp(0, end);
    for (var i = avgEnd; i < maxEnd; i++) {
      fp = (fp << 1) + _gearTable[data[i]];
      if ((fp & _maskL) == 0) return i + 1;
    }

    // Hard cut at max.
    return maxEnd;
  }
}

/// Gear hash lookup table -- 256 random 32-bit values, one per byte value.
/// Standard table used in FastCDC implementations.
const _gearTable = <int>[
  0x5C95C078, 0x22408989, 0x2D48A214, 0x12842087, 0x530F8AFB, 0x474536B9,
  0x2963B4F1, 0x44CB738B, 0x4EA7403D, 0x4D606B6E, 0x074EC5D3, 0x3AF39D18,
  0x726C4D43, 0x60A91127, 0x2B79C236, 0x478A8B2C, 0x6D835023, 0x08B0EE36,
  0x6B1F116A, 0x2D04C72F, 0x3C86BCC2, 0x1C8B06B3, 0x57E8E53F, 0x3CD0E137,
  0x5E7E7BC2, 0x264CA8F1, 0x3E9D4D76, 0x23A74C3C, 0x1A5B8B2D, 0x0C6E0B39,
  0x2BA5C723, 0x3F7E0D47, 0x1F2D8B79, 0x0AB4C3F2, 0x7C8D593A, 0x4F2E1F4C,
  0x09D4A68F, 0x2D1B3D5E, 0x6E7C4A21, 0x14A5B367, 0x7C2D12AE, 0x5F3E1B82,
  0x3C0E9D47, 0x2A8B4F15, 0x1E5D67C3, 0x6F0A3B59, 0x4D7C2E81, 0x0B3F5A47,
  0x5C1E8D23, 0x3A4F7B69, 0x2E0D4C15, 0x7B3A5E82, 0x1D6C4F37, 0x4A2B8D59,
  0x0F7E3C41, 0x6D5A1B73, 0x3B8E4F25, 0x2C1D7A49, 0x5E4B3C87, 0x1A0F6D53,
  0x7C3E2B15, 0x4D8A5F69, 0x0E2C7B31, 0x6F1D4A83, 0x3A5E8C47, 0x2B0F7D59,
  0x5C4A3E21, 0x1D8B6F73, 0x4E2C5A35, 0x0F7D3B89, 0x6A1E4C57, 0x3B8F7D29,
  0x2C5A1E41, 0x5D0B4F83, 0x1E7C3A65, 0x4F2D8B37, 0x0A5E7C49, 0x6B1F3D81,
  0x3C4A5E23, 0x2D8B0F75, 0x5E1C4A39, 0x0F7D2B87, 0x6A3E5C51, 0x1B4F8D63,
  0x4C2A7E35, 0x3D5B0F49, 0x2E8C4A71, 0x5F1D3B83, 0x0A4E7C55, 0x6B2F5D27,
  0x3C8A1E69, 0x2D4B7F31, 0x5E0C3A43, 0x1F7D4B85, 0x4A2E8C67, 0x3B5F1D39,
  0x2C0A4E71, 0x6D3B7F53, 0x1E4C5A25, 0x4F8D2B89, 0x0A1E6C47, 0x5B3F7D61,
  0x3C2A5E33, 0x2D8B4F75, 0x4E1C3A87, 0x0F5D2B49, 0x6A4E7C21, 0x1B3F8D63,
  0x5C2A1E45, 0x3D4B5F37, 0x2E0C7A89, 0x4F3D8B51, 0x1A5E4C73, 0x6B2F1D35,
  0x3C8A7E47, 0x0D4B3F69, 0x5E1C2A81, 0x2F7D5B53, 0x4A0E8C25, 0x1B3F4D87,
  0x6C5A2E49, 0x3D0B7F61, 0x2E4C1A33, 0x5F8D3B75, 0x0A1E5C37, 0x4B2F6D89,
  0x3C4A7E51, 0x1D5B0F73, 0x6E2C3A45, 0x2F8D4B67, 0x4A1E7C39, 0x0B3F5D81,
  0x5C2A4E53, 0x3D8B1F25, 0x2E4C6A87, 0x4F0D3B49, 0x1A5E2C61, 0x6B7F4D33,
  0x3C0A8E75, 0x2D4B5F47, 0x5E1C7A69, 0x0F3D2B81, 0x6A4E8C53, 0x1B5F3D25,
  0x4C2A0E87, 0x3D7B4F59, 0x2E8C1A71, 0x5F0D6B43, 0x0A4E3C65, 0x6B1F7D37,
  0x3C5A2E89, 0x2D0B8F51, 0x4E7C4A23, 0x1F3D5B75, 0x6A2E0C47, 0x0B4F7D69,
  0x5C1A3E31, 0x3D8B5F83, 0x2E4C2A55, 0x4F0D6B27, 0x1A7E3C49, 0x6B5F4D71,
  0x3C0A2E93, 0x2D8B7F65, 0x5E4C1A37, 0x0F3D5B89, 0x6A2E4C51, 0x1B0F7D23,
  0x4C5A3E85, 0x3D2B8F57, 0x2E7C4A29, 0x5F1D6B41, 0x0A3E5C63, 0x6B4F2D35,
  0x3C8A1E77, 0x2D5B7F49, 0x4E0C3A61, 0x1F7D4B83, 0x6A2E8C55, 0x0B3F5D27,
  0x5C4A1E69, 0x3D2B0F31, 0x2E8C7A43, 0x4F5D3B85, 0x1A0E6C57, 0x6B7F2D79,
  0x3C4A5E41, 0x2D1B8F63, 0x5E0C4A35, 0x0F7D3B87, 0x6A2E5C59, 0x1B4F0D21,
  0x4C3A7E73, 0x3D5B2F45, 0x2E8C4A67, 0x5F1D7B39, 0x0A0E3C81, 0x6B4F5D53,
  0x3C2A8E25, 0x2D7B1F47, 0x4E5C3A69, 0x1F0D4B31, 0x6A7E2C83, 0x0B3F8D55,
  0x5C1A4E27, 0x3D5B7F49, 0x2E0C2A71, 0x4F8D6B43, 0x1A3E5C65, 0x6B4F1D37,
  0x3C7A2E89, 0x2D0B8F51, 0x5E4C5A23, 0x0F1D3B75, 0x6A7E2C47, 0x1B5F4D69,
  0x4C0A3E81, 0x3D2B7F53, 0x2E8C1A25, 0x5F4D6B87, 0x0A3E5C49, 0x6B1F7D61,
  0x3C5A0E33, 0x2D4B8F75, 0x4E1C7A37, 0x0F3D2B59, 0x6A5E4C21, 0x1B0F7D63,
  0x4C3A2E85, 0x3D8B5F57, 0x2E4C7A29, 0x5F0D1B41, 0x0A3E6C73, 0x6B5F2D45,
  0x3C8A4E67, 0x2D1B7F39, 0x4E0C3A51, 0x1F7D5B83, 0x6A4E2C55, 0x0B3F8D27,
  0x5C1A5E69, 0x3D2B4F31, 0x2E8C7A43, 0x4F5D0B65, 0x1A7E3C87, 0x6B0F4D59,
  0x3C5A2E21, 0x2D4B8F73, 0x5E1C7A45, 0x0F3D5B67, 0x4A2B1E89, 0x7C6D3F41,
  0x1D5E8A63, 0x3B0F4C35, 0x6E2A7D57, 0x2F8B5E29,
];
