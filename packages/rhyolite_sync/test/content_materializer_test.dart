import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_store.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_text_sync.dart';
import 'package:test/test.dart';

void main() {
  test('a text path projects the Fugue blob to plain text (not \\0fg1 bytes)',
      () async {
    final blob = FugueStore.encodeBlob(FugueTextSync.seedFromText('hello world'));
    // The raw blob carries the magic header — must NOT reach disk / the diff.
    expect(blob.sublist(0, 4), [0x00, 0x66, 0x67, 0x31]);

    final out = materializeFileContent(blob, 'notes/a.md');
    expect(utf8.decode(out!), 'hello world');
  });

  test('a binary path passes the blob through unchanged', () {
    final bytes = Uint8List.fromList([0, 1, 2, 255, 254]);
    expect(materializeFileContent(bytes, 'img/pic.png'), same(bytes));
  });

  test('a genuine pre-Fugue plain-text blob on a text path passes through', () {
    final bytes = Uint8List.fromList(utf8.encode('legacy plain'));
    expect(utf8.decode(materializeFileContent(bytes, 'a.txt')!), 'legacy plain');
  });
}
