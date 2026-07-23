import 'dart:convert';
import 'dart:typed_data';

import '../chunking/file_type_detector.dart';
import 'fugue_store.dart';

/// Turns a downloaded content-addressed blob into the readable, on-disk file
/// bytes.
///
/// Text content is stored as the Fugue CRDT serialization (magic `\0fg1`), NOT
/// the raw document — so for a text path we project the tree to plain text. A
/// legacy pre-Fugue Sequence blob is not document text and returns null (the
/// caller should treat that version as unavailable rather than show CBOR
/// garbage). A genuine pre-Fugue plain-text blob, and any binary blob, pass
/// through unchanged.
///
/// This is the single source of "blob -> file content" — history restore,
/// backup restore and the backup diff view all go through it, so none of them
/// ever writes/shows the raw `\0fg1` serialization.
Uint8List? materializeFileContent(Uint8List bytes, String path) {
  // A magic-prefixed Fugue blob is always text-projectable, regardless of the
  // path's current classification: a file synced as Fugue but now classified
  // binary (e.g. .excalidraw.md) must still project, never surface raw \0fg1.
  final fugue = FugueStore.tryDecodeBlob(bytes);
  if (fugue != null) {
    return Uint8List.fromList(utf8.encode(fugue.values.join()));
  }
  // The legacy Sequence probe is a full CBOR/JSON decode and only relevant to
  // the pre-Fugue text rollout — keep it gated on the text classification.
  if (const FileTypeDetector().isText(path) &&
      FugueStore.isLegacySequenceBlob(bytes)) {
    return null;
  }
  return bytes;
}
