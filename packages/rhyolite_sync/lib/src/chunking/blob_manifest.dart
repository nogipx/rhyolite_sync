/// One chunk inside a [BlobManifest]. The order field matters because
/// reassembly concatenates chunks in increasing [order].
class ChunkRef {
  final String hash;
  final int size;
  final int order;

  const ChunkRef({
    required this.hash,
    required this.size,
    required this.order,
  });

  Map<String, dynamic> toJson() => {
        'hash': hash,
        'size': size,
        'order': order,
      };

  factory ChunkRef.fromJson(Map<String, dynamic> json) => ChunkRef(
        hash: json['hash'] as String,
        size: json['size'] as int,
        order: json['order'] as int,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChunkRef &&
          hash == other.hash &&
          size == other.size &&
          order == other.order;

  @override
  int get hashCode => Object.hash(hash, size, order);

  @override
  String toString() => 'ChunkRef(hash: $hash, size: $size, order: $order)';
}

/// Ordered list of chunks that make up one file's content, plus the
/// total reassembled size for an integrity check at download time.
class BlobManifest {
  final List<ChunkRef> chunks;
  final int totalSize;

  const BlobManifest({
    required this.chunks,
    required this.totalSize,
  });

  List<String> get chunkHashes => chunks.map((c) => c.hash).toList();

  Map<String, dynamic> toJson() => {
        'chunks': chunks.map((c) => c.toJson()).toList(),
        'totalSize': totalSize,
      };

  factory BlobManifest.fromJson(Map<String, dynamic> json) => BlobManifest(
        chunks: (json['chunks'] as List)
            .map((c) => ChunkRef.fromJson(c as Map<String, dynamic>))
            .toList(),
        totalSize: json['totalSize'] as int,
      );

  @override
  String toString() =>
      'BlobManifest(chunks: ${chunks.length}, totalSize: $totalSize)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! BlobManifest) return false;
    if (totalSize != other.totalSize) return false;
    if (chunks.length != other.chunks.length) return false;
    for (var i = 0; i < chunks.length; i++) {
      if (chunks[i] != other.chunks[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(totalSize, Object.hashAll(chunks));
}

class ManifestDiff {
  final List<String> addedChunkHashes;
  final List<String> removedChunkHashes;
  final List<String> unchangedChunkHashes;

  const ManifestDiff({
    required this.addedChunkHashes,
    required this.removedChunkHashes,
    required this.unchangedChunkHashes,
  });

  bool get hasChanges =>
      addedChunkHashes.isNotEmpty || removedChunkHashes.isNotEmpty;
}

class DiffManifestsUseCase {
  const DiffManifestsUseCase();

  ManifestDiff call({
    required BlobManifest? oldManifest,
    required BlobManifest newManifest,
  }) {
    final oldHashes = oldManifest?.chunkHashes.toSet() ?? <String>{};
    final newHashes = newManifest.chunkHashes.toSet();

    return ManifestDiff(
      addedChunkHashes: newHashes.difference(oldHashes).toList(),
      removedChunkHashes: oldHashes.difference(newHashes).toList(),
      unchangedChunkHashes: newHashes.intersection(oldHashes).toList(),
    );
  }
}
