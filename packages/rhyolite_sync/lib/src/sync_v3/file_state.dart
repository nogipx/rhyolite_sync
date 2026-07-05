import 'dart:convert';

import 'package:convergent/convergent.dart';

/// One file's metadata as held in the FileStateStore.
///
/// One TaggedValue<FileState> in the file's MvRegister (Δ-state CRDT,
/// doc §4). Concurrent edits produce multiple TaggedValues; the resolver
/// (doc §6) collapses them back to one.
class FileState {
  /// Stable, deterministic file id (UUID v5 of vaultId + relPath).
  final String fileId;

  /// Relative path within the vault.
  final String path;

  /// sha256 of the encrypted manifest blob. The manifest is itself a blob
  /// containing the ordered list of chunk hashes that make up the file.
  /// Empty string for tombstones.
  final String blobRef;

  final int sizeBytes;

  /// HLC at the moment the writer produced this state.
  final Hlc hlc;

  /// True if this entry represents a deletion. Path / blobRef are still
  /// retained so consumers can act on the deletion correctly.
  final bool tombstone;

  /// Plain list of chunk hashes that this file references. Persisted both
  /// locally and (plain) on the server so blob GC can compute the live
  /// chunk set without decrypting manifests. Empty for tombstones.
  final List<String> chunks;

  const FileState({
    required this.fileId,
    required this.path,
    required this.blobRef,
    required this.sizeBytes,
    required this.hlc,
    this.tombstone = false,
    this.chunks = const [],
  });

  FileState copyWith({
    String? path,
    String? blobRef,
    int? sizeBytes,
    Hlc? hlc,
    bool? tombstone,
    List<String>? chunks,
  }) =>
      FileState(
        fileId: fileId,
        path: path ?? this.path,
        blobRef: blobRef ?? this.blobRef,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        hlc: hlc ?? this.hlc,
        tombstone: tombstone ?? this.tombstone,
        chunks: chunks ?? this.chunks,
      );

  /// Schema version for both the local persisted [toJson] form and the
  /// encrypted [toWirePayload] form. Incremented on any breaking change.
  /// Decoders reject unknown versions explicitly so a forced wipe is the
  /// observable failure mode, not silent corruption.
  ///
  /// v2: blob ids switched from raw `sha256(plain)` to keyed
  /// `HMAC(vaultSubkey, plain)`. A v1 blobRef is not reproducible under v2, so
  /// the bump forces a clean re-chunk rather than mixing the two id schemes in
  /// one vault.
  static const int schemaVersion = 2;

  Map<String, dynamic> toJson() => {
        'v': schemaVersion,
        'fileId': fileId,
        'path': path,
        'blobRef': blobRef,
        'sizeBytes': sizeBytes,
        'hlc': hlc.pack(),
        if (tombstone) 'tombstone': true,
        if (chunks.isNotEmpty) 'chunks': chunks,
      };

  factory FileState.fromJson(Map<String, dynamic> json) {
    final v = (json['v'] as int?) ?? 1;
    if (v != schemaVersion) {
      throw FormatException(
        'FileState schema v$v not supported (expected v$schemaVersion)',
      );
    }
    return FileState(
      fileId: json['fileId'] as String,
      path: json['path'] as String,
      blobRef: json['blobRef'] as String,
      sizeBytes: json['sizeBytes'] as int,
      hlc: Hlc.unpack(json['hlc'] as String),
      tombstone: (json['tombstone'] as bool?) ?? false,
      chunks: (json['chunks'] as List?)?.cast<String>() ?? const [],
    );
  }

  /// The shape of the payload that travels over the wire (encrypted by the
  /// caller). This is what the server stores opaquely. `chunks` is NOT
  /// in here because it is sent as a plain field on the wire envelope so
  /// the server can index it for GC.
  Map<String, dynamic> toWirePayload() => {
        'v': schemaVersion,
        'path': path,
        'blobRef': blobRef,
        'sizeBytes': sizeBytes,
        if (tombstone) 'tombstone': true,
      };

  static Map<String, dynamic> wirePayloadFromBytes(List<int> bytes) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final v = (json['v'] as int?) ?? 1;
    if (v != schemaVersion) {
      throw FormatException(
        'Wire payload schema v$v not supported (expected v$schemaVersion)',
      );
    }
    return json;
  }

  /// Structural equality on every field. Without this, round-trip
  /// decoding produces a fresh object instance per pull and `Set` /
  /// `MvRegister` dedup fails — every pull would inflate the local
  /// register with duplicate TaggedValues that happen to wrap the
  /// same logical value.
  @override
  bool operator ==(Object other) {
    if (other is! FileState) return false;
    if (fileId != other.fileId) return false;
    if (path != other.path) return false;
    if (blobRef != other.blobRef) return false;
    if (sizeBytes != other.sizeBytes) return false;
    if (hlc != other.hlc) return false;
    if (tombstone != other.tombstone) return false;
    if (chunks.length != other.chunks.length) return false;
    for (var i = 0; i < chunks.length; i++) {
      if (chunks[i] != other.chunks[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        fileId,
        path,
        blobRef,
        sizeBytes,
        hlc,
        tombstone,
        Object.hashAll(chunks),
      );
}
