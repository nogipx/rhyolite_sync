import 'dart:convert';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

void main() {
  const detector = FileTypeDetector();

  group('FileTypeDetector .excalidraw handling', () {
    test('.excalidraw.md is forced binary despite the .md suffix', () {
      expect(detector.isText('drawings/board.excalidraw.md'), isFalse);
      expect(detector.shouldChunk('drawings/board.excalidraw.md'), isTrue);
    });

    test('force-binary match is case-insensitive', () {
      expect(detector.isText('Board.Excalidraw.MD'), isFalse);
      expect(detector.shouldChunk('Board.Excalidraw.MD'), isTrue);
    });

    test('legacy standalone .excalidraw stays binary', () {
      expect(detector.isText('board.excalidraw'), isFalse);
      expect(detector.shouldChunk('board.excalidraw'), isTrue);
    });

    test('.canvas is binary (structured JSON, no char-merge)', () {
      expect(detector.isText('boards/plan.canvas'), isFalse);
      expect(detector.shouldChunk('boards/plan.canvas'), isTrue);
    });

    test('a plain .md note is still text', () {
      expect(detector.isText('notes/todo.md'), isTrue);
      expect(detector.shouldChunk('notes/todo.md'), isFalse);
    });

    test('extension detection matches the filename, not a directory segment',
        () {
      // A directory named like the compound suffix must not drag its
      // children onto the binary path.
      expect(detector.isText('foo.excalidraw.md/notes.md'), isTrue);
    });
  });

  group('FileTypeDetector extraBinaryExtensions (synced policy)', () {
    const configured = FileTypeDetector(extraBinaryExtensions: {'foo', 'json'});

    test('a configured extension is forced binary', () {
      expect(configured.isText('data/a.foo'), isFalse);
      expect(configured.shouldChunk('data/a.foo'), isTrue);
    });

    test('overrides a built-in text extension (json -> binary)', () {
      expect(const FileTypeDetector().isText('a.json'), isTrue);
      expect(configured.isText('a.json'), isFalse);
      expect(configured.shouldChunk('a.json'), isTrue);
    });

    test('extensions NOT in the set keep their default classification', () {
      expect(configured.isText('note.md'), isTrue);
      expect(configured.isText('image.png'), isFalse);
    });

    test('the empty default set changes nothing', () {
      expect(const FileTypeDetector().isText('a.json'), isTrue);
      expect(const FileTypeDetector().isText('a.foo'), isFalse); // unknown->bin
    });
  });

  group('materializeFileContent projects Fugue blobs regardless of class', () {
    test('now-binary .excalidraw.md still projects a Fugue-encoded blob', () {
      const drawing = '{"type":"excalidraw","version":2,"elements":[]}';
      final blob = FugueStore.encodeBlob(FugueTextSync.seedFromText(drawing));

      // Sanity: the wire blob is NOT the raw drawing (it carries the magic).
      expect(blob.sublist(0, 4), equals(<int>[0x00, 0x66, 0x67, 0x31]));

      final out = materializeFileContent(blob, 'board.excalidraw.md');
      expect(out, isNotNull);
      expect(utf8.decode(out!), equals(drawing));
    });

    test('a genuine binary blob passes through unchanged', () {
      final raw = utf8.encode('\x89PNG not-really-but-not-fugue');
      final out = materializeFileContent(raw, 'image.png');
      expect(out, equals(raw));
    });
  });
}
