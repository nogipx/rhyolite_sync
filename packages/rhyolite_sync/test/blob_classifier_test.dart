import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_store.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_text_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

/// A blob in a tag this build has no decoder for — what a NEWER client writes.
///
/// Not `\0doc1`: that one exists now. This is the shape of whatever comes
/// after it.
Uint8List _futureTag() => _bytes([
      0x00, 0x78, 0x79, 0x7A, 0x39, // \0xyz9
      0xA1, 0x61, 0x78, 0x01, // arbitrary payload
    ]);

void main() {
  group('classifyBlob', () {
    test('a Fugue blob is recognised regardless of path classification', () {
      final blob = FugueStore.encodeBlob(FugueTextSync.seedFromText('hi'));
      // Path-independent: a note reclassified binary (.excalidraw.md, a
      // force-binary suffix) still holds a magic-prefixed blob.
      expect(classifyBlob(blob, isTextPath: true), BlobKind.fugue);
      expect(classifyBlob(blob, isTextPath: false), BlobKind.fugue);
    });

    test('an unknown tag on a text path is refused, not written', () {
      expect(classifyBlob(_futureTag(), isTextPath: true),
          BlobKind.unknownTagged);
    });

    test('NUL-leading binaries are NOT mistaken for an unknown tag', () {
      // The reason the unknownTagged test is gated on the text path: these are
      // ordinary files, and refusing them would break content this feature has
      // no business touching.
      final ttf = _bytes([0x00, 0x01, 0x00, 0x00, 0x00, 0x0F]);
      final ico = _bytes([0x00, 0x00, 0x01, 0x00, 0x01, 0x00]);
      final wasm = _bytes([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00]); // \0asm
      for (final b in [ttf, ico, wasm]) {
        expect(classifyBlob(b, isTextPath: false), BlobKind.binary);
      }
    });

    test('a legacy Sequence blob is told apart from genuine plain text', () {
      final legacy = CborCodec.encode({
        'v': 1,
        'chars': <dynamic>[],
      });
      expect(classifyBlob(legacy, isTextPath: true), BlobKind.legacySequence);

      final plain = _bytes(utf8.encode('# just a note\n\nbody'));
      expect(classifyBlob(plain, isTextPath: true), BlobKind.plainText);
    });

    test('the legacy probe never runs on a binary path', () {
      // Same bytes, different verdict: the probe is a full CBOR/JSON decode
      // and binary blobs are large, so it stays off that path.
      final legacy = CborCodec.encode({'v': 1, 'chars': <dynamic>[]});
      expect(classifyBlob(legacy, isTextPath: false), BlobKind.binary);
    });

    test('empty bytes are plain text on a text path, binary otherwise', () {
      expect(classifyBlob(_bytes([]), isTextPath: true), BlobKind.plainText);
      expect(classifyBlob(_bytes([]), isTextPath: false), BlobKind.binary);
    });
  });

  group('materializeFileContent refuses what it cannot read', () {
    test('an unknown tag yields null instead of the raw bytes', () {
      // Before the classifier this fell through to `return bytes`, and the
      // callers (history restore, backup restore, conflict copy) wrote the
      // serialised state into the vault.
      expect(materializeFileContent(_futureTag(), 'notes/a.md'), isNull);
    });

    test('an unknown tag on a binary path still passes through', () {
      final b = _futureTag();
      expect(materializeFileContent(b, 'fonts/x.ttf'), same(b));
    });
  });
}
