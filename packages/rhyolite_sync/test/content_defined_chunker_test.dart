import 'dart:math';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

Uint8List _randomBytes(int size, [int seed = 42]) {
  final rng = Random(seed);
  return Uint8List.fromList(List.generate(size, (_) => rng.nextInt(256)));
}

void main() {
  late ContentDefinedChunker chunker;

  setUp(() {
    chunker = ContentDefinedChunker(
      minChunkSize: 1024,
      avgChunkSize: 4096,
      maxChunkSize: 16384,
    );
  });

  group('ContentDefinedChunker', () {
    test('empty input produces empty manifest', () {
      final result = chunker.call(Uint8List(0));
      expect(result.manifest.chunks, isEmpty);
      expect(result.manifest.totalSize, 0);
      expect(result.chunks, isEmpty);
    });

    test('data smaller than minChunkSize produces one chunk', () {
      final data = _randomBytes(512);
      final result = chunker.call(data);
      expect(result.manifest.chunks, hasLength(1));
      expect(result.manifest.totalSize, 512);
      expect(result.chunks.values.first, equals(data));
    });

    test('all chunks are within size bounds', () {
      final data = _randomBytes(256 * 1024);
      final result = chunker.call(data);

      for (final chunk in result.manifest.chunks) {
        // Last chunk may be smaller than min.
        if (chunk.order < result.manifest.chunks.length - 1) {
          expect(
            chunk.size,
            greaterThanOrEqualTo(chunker.minChunkSize),
            reason: 'Chunk ${chunk.order} is smaller than min',
          );
        }
        expect(
          chunk.size,
          lessThanOrEqualTo(chunker.maxChunkSize),
          reason: 'Chunk ${chunk.order} exceeds max',
        );
      }
    });

    test('chunks reassemble to original data', () {
      final data = _randomBytes(200 * 1024);
      final result = chunker.call(data);

      final reassembled = BytesBuilder();
      for (final ref in result.manifest.chunks) {
        reassembled.add(result.chunks[ref.hash]!);
      }
      expect(reassembled.toBytes(), equals(data));
    });

    test('totalSize matches input size', () {
      final data = _randomBytes(100 * 1024);
      final result = chunker.call(data);
      expect(result.manifest.totalSize, data.length);

      final summedSize = result.manifest.chunks.fold<int>(
        0,
        (sum, c) => sum + c.size,
      );
      expect(summedSize, data.length);
    });

    test('chunk order is sequential starting from 0', () {
      final data = _randomBytes(128 * 1024);
      final result = chunker.call(data);
      for (var i = 0; i < result.manifest.chunks.length; i++) {
        expect(result.manifest.chunks[i].order, i);
      }
    });

    test('identical input produces identical manifest', () {
      final data = _randomBytes(64 * 1024);
      final r1 = chunker.call(data);
      final r2 = chunker.call(data);
      expect(r1.manifest, equals(r2.manifest));
    });

    test('small edit only affects nearby chunks', () {
      final data = _randomBytes(256 * 1024);
      final r1 = chunker.call(data);

      // Flip one byte in the middle.
      final modified = Uint8List.fromList(data);
      modified[128 * 1024] ^= 0xFF;
      final r2 = chunker.call(modified);

      // Most chunks should be unchanged.
      final oldHashes = r1.manifest.chunkHashes.toSet();
      final newHashes = r2.manifest.chunkHashes.toSet();
      final unchanged = oldHashes.intersection(newHashes);

      // At least half of chunks should survive a single byte edit.
      expect(
        unchanged.length,
        greaterThan(r1.manifest.chunks.length ~/ 2),
        reason:
            'Too many chunks changed for a single byte edit: '
            '${r1.manifest.chunks.length - unchanged.length} of ${r1.manifest.chunks.length}',
      );
    });

    test('append at end only adds new chunks', () {
      final data = _randomBytes(64 * 1024);
      final r1 = chunker.call(data);

      final extended = Uint8List(data.length + 32 * 1024);
      extended.setRange(0, data.length, data);
      extended.setRange(
        data.length,
        extended.length,
        _randomBytes(32 * 1024, 99),
      );
      final r2 = chunker.call(extended);

      // All original chunk hashes should still be present.
      final oldHashes = r1.manifest.chunkHashes.toSet();
      final newHashes = r2.manifest.chunkHashes.toSet();

      // Most old hashes should survive (boundary effects may change 1 chunk).
      final surviving = oldHashes.intersection(newHashes);
      expect(
        surviving.length,
        greaterThanOrEqualTo(r1.manifest.chunks.length - 1),
        reason: 'Appending should not affect most original chunks',
      );
    });

    test('manifest diff shows only changed chunks', () {
      final data = _randomBytes(256 * 1024);
      final r1 = chunker.call(data);

      final modified = Uint8List.fromList(data);
      modified[128 * 1024] ^= 0xFF;
      final r2 = chunker.call(modified);

      final diff = const DiffManifestsUseCase()(
        oldManifest: r1.manifest,
        newManifest: r2.manifest,
      );

      // Only a few chunks should differ.
      expect(
        diff.addedChunkHashes.length,
        lessThan(r1.manifest.chunks.length ~/ 2),
      );
      expect(
        diff.unchangedChunkHashes.length,
        greaterThan(r1.manifest.chunks.length ~/ 2),
      );
    });

    test('works with default production-sized parameters', () {
      final prodChunker = ContentDefinedChunker();
      final data = _randomBytes(10 * 1024 * 1024); // 10MB
      final result = prodChunker.call(data);

      expect(result.manifest.chunks.length, greaterThan(1));
      expect(result.manifest.totalSize, data.length);

      // Reassemble.
      final reassembled = BytesBuilder();
      for (final ref in result.manifest.chunks) {
        reassembled.add(result.chunks[ref.hash]!);
      }
      expect(reassembled.toBytes(), equals(data));
    });

    test('data exactly at minChunkSize produces one chunk', () {
      final data = _randomBytes(chunker.minChunkSize);
      final result = chunker.call(data);
      // Could be 1 chunk (if no boundary found) or possibly more.
      // At min size, it should always be 1 chunk.
      expect(result.manifest.chunks, hasLength(1));
      expect(result.manifest.chunks.first.size, chunker.minChunkSize);
    });
  });
}
