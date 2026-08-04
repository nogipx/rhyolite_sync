import 'dart:typed_data';

import 'fugue_store.dart';

/// What a downloaded blob's bytes actually are.
///
/// Four places used to answer this question with their own inline chain of
/// probes — the materializer, the disk write path, the tree seed path and the
/// conflict merge. They agreed by accident rather than by construction, and
/// the one that disagreed ([DiskReconciler.writeFileToDisk], which never went
/// through the materializer) is the one that writes to the user's vault.
enum BlobKind {
  /// A magic-prefixed Fugue tree. Project it; never write its bytes.
  fugue,

  /// A pre-Fugue Sequence blob (CBOR/JSON map with `v` + `chars`/`c`) from a
  /// peer that has not upgraded. NOT document text — skip and await a reseed.
  legacySequence,

  /// A genuine pre-Fugue plain-text blob. Write or seed as-is.
  plainText,

  /// A real binary file. Write as-is.
  binary,

  /// NUL-prefixed on a text path, but not a tag this build knows.
  ///
  /// Almost certainly a blob written by a NEWER client in a format that did
  /// not exist when this one was compiled. Every branch must refuse it: write
  /// it to disk and the user finds serialised CRDT state inside their note;
  /// seed a tree from it and this device pushes that garbage back, replacing
  /// the newer state for everybody.
  unknownTagged,
}

/// Raised when a blob cannot be interpreted by this build and the caller has
/// no safe fallback — specifically the tree-seed path, where the alternatives
/// (seed from raw bytes, or seed empty and re-push from disk) both end in this
/// client overwriting a newer format it cannot read.
class UnsupportedBlobFormatException implements Exception {
  const UnsupportedBlobFormatException(this.path);

  final String path;

  @override
  String toString() =>
      'UnsupportedBlobFormatException: $path is stored in a format this '
      'client does not understand — update the client';
}

/// Classifies [bytes] for a file whose path is text ([isTextPath] true) or
/// binary.
///
/// The caller passes the verdict rather than the path because there is no one
/// answer: the reconciler's detector carries the vault-global force-binary
/// policy and the materializer's does not, so the same path classifies
/// differently depending on who is asking. Taking a bool makes that difference
/// visible at each call site instead of hiding it behind a shared lookup.
BlobKind classifyBlob(Uint8List bytes, {required bool isTextPath}) {
  // Path-independent on purpose. A file synced as Fugue but reclassified
  // binary since (`.excalidraw.md`, a force-binary suffix) still holds a
  // magic-prefixed blob, and writing those bytes is never correct.
  if (FugueStore.tryDecodeBlob(bytes) != null) return BlobKind.fugue;

  // Frontmatter state rides in the TAIL of that same blob, so there is no
  // second tag to recognise here — see fm_tail.dart. A build that ignores the
  // tail still classifies the blob correctly, which is the entire point.

  if (isTextPath) {
    // Real notes never start with NUL — that is the whole point of the leading
    // 0x00 in the tag convention (see FugueStore._magic). So on a text path,
    // NUL-prefixed and not `\0fg1` means a tag from the future.
    //
    // Deliberately gated on the text path. Plenty of legitimate binaries open
    // with NUL — TrueType is `00 01 00 00`, ICO is `00 00 01 00`, wasm is
    // literally `\0asm` — and refusing those would break files this has no
    // business touching. The residual case, a tagged blob on a path that is
    // now classified binary, is covered the way `\0fg1` covers it today: by
    // that tag's own decoder running before this test.
    if (bytes.isNotEmpty && bytes[0] == 0x00) return BlobKind.unknownTagged;

    // Full CBOR/JSON decode — kept off the binary path, where blobs are large
    // and the answer is always no.
    if (FugueStore.isLegacySequenceBlob(bytes)) return BlobKind.legacySequence;

    return BlobKind.plainText;
  }

  return BlobKind.binary;
}
