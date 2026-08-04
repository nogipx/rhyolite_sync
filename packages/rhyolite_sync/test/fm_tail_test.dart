import 'dart:convert';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_store.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_tail.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_codec.dart';
import 'package:rhyolite_sync/src/frontmatter/fm_state.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_parser.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_document.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_render.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

int _wall = 5000;
Hlc at(String node) => Hlc(++_wall, 0, node);

FmState build(String region, {String node = 'device-a', FmState? onto}) =>
    applyDiskFrontmatter(
      onto ?? FmMapState(entries: const {}, fmHlc: at(node), trailHlc: at(node)),
      parseFrontmatterRegion(region),
      at(node),
    );

void main() {
  group('fm codec', () {
    test('round-trips every value shape', () {
      final state = build(
        '# lead\n'
        'text: hello\n'
        'num: 42\n'
        'flag: true\n'
        'day: 2026-08-03\n'
        'tags:\n  - work\n  - home\n'
        'publish:\n  nested: yes\n'
        '# trail\n',
      );
      final decoded = decodeFmState(encodeFmState(state));
      expect(renderRegion(materializeFm(decoded)),
          renderRegion(materializeFm(state)));
    });

    test('tombstones survive the trip — a delete that did not would undo', () {
      final base = build('x: 1\ny: 2\n');
      final deleted = applyDiskFrontmatter(
        base,
        parseFrontmatterRegion('y: 2\n'),
        at('device-a'),
      );
      final decoded = decodeFmState(encodeFmState(deleted)) as FmMapState;
      expect(decoded.entries['x'], isNotNull, reason: 'the tombstone is state');
      expect(decoded.entries['x']!.isLive, isFalse);
      // And it still beats a peer that never saw the delete.
      expect(
        (materializeFm(joinFm(decoded, base)) as FmMap).entries.map((e) => e.key),
        ['y'],
      );
    });

    test('equal states encode to IDENTICAL bytes', () {
      // The property the blob id rests on. Two devices with the same state
      // that emit different bytes disagree about blobRef, push at each other
      // forever and lose chunk dedup.
      final one = build('a: 1\nb: 2\ntags:\n  - x\n  - y\n');
      final copy = decodeFmState(encodeFmState(one));
      expect(encodeFmState(copy), encodeFmState(one));
    });

    test('node-id order in the pool does not leak into the bytes', () {
      // Same logical state, but the two devices wrote in the opposite order,
      // so each meets the node ids in a different sequence.
      final ab = build('b: 2\n', node: 'zzz-device', onto: build('a: 1\n', node: 'aaa-device'));
      final ba = decodeFmState(encodeFmState(ab));
      expect(encodeFmState(ba), encodeFmState(ab));

      final pool = CborCodec.decode(encodeFmState(ab))['n'] as List;
      expect(pool, [...pool]..sort(), reason: 'the pool must be sorted');
    });

    test('interning keeps the clocks smaller than the data', () {
      const device = '11111111-2222-4333-8444-555555555555';
      final state = build(
        'a: 1\nb: 2\nc: 3\nd: 4\ne: 5\ntags:\n  - one\n  - two\n  - three\n',
        node: device,
      );
      final bytes = encodeFmState(state);
      // Six keys and three items carry ~20 clocks. Written out in full that is
      // 20 x 36 bytes of device id alone; the pool holds it once.
      expect(bytes.length, lessThan(600),
          reason: 'encoded ${bytes.length} bytes — interning is not working');
      expect(utf8.decode(bytes, allowMalformed: true).split(device).length - 1, 1,
          reason: 'the device id must appear exactly once');
    });

    test('a version this build does not know is refused, not guessed', () {
      final bytes = CborCodec.encode({'v': 99, 'n': <String>[], 's': 0});
      expect(() => decodeFmState(bytes), throwsA(isA<FmDecodeException>()));
    });

    test('a clock pointing outside the pool is refused', () {
      final bytes = CborCodec.encode({
        'v': fmCodecVersion,
        'n': <String>['only-one'],
        's': 0,
        'h': [1, 0, 7],
        't': '',
        'th': [1, 0, 0],
        'e': <String, dynamic>{},
      });
      expect(() => decodeFmState(bytes), throwsA(isA<FmDecodeException>()));
    });
  });

  group('the frontmatter tail', () {
    Uint8List blobOf(String text, FmState? fm) {
      final tree = seedFugueText(text);
      final blob = FugueStore.encodeBlob(tree);
      return fm == null ? blob : appendFmTail(blob, fm);
    }

    test('an OLD decoder reads the tree and never notices the tail', () {
      // The property the design rests on. Pinned against the library itself in
      // convergent_trailing_bytes_contract_test.dart — this one checks it end
      // to end, through a real tail rather than filler bytes.
      const note = '---\ntags:\n  - work\n---\n\nbody\n';
      final plain = blobOf(note, null);
      final tailed = blobOf(note, build('tags:\n  - work\n'));

      expect(FugueStore.tryDecodeBlob(plain)!.values.join(), note);
      expect(FugueStore.tryDecodeBlob(tailed)!.values.join(), note,
          reason: 'same text, tail or no tail');
      expect(tailed.length, greaterThan(plain.length));
    });

    test('the blob still classifies as an ordinary fugue blob', () {
      final tailed = blobOf('---\nx: 1\n---\nbody\n', build('x: 1\n'));
      expect(classifyBlob(tailed, isTextPath: true), BlobKind.fugue);
      expect(
        utf8.decode(materializeFileContent(tailed, 'n.md')!),
        '---\nx: 1\n---\nbody\n',
      );
    });

    test('round-trips the state', () {
      final fm = build('title: Note\ntags:\n  - work\n  - home\n');
      final read = readFmTail(blobOf('---\nx\n---\n', fm));
      expect(renderRegion(materializeFm(read!)), renderRegion(materializeFm(fm)));
    });

    test('a blob without a tail answers null, not an error', () {
      expect(readFmTail(blobOf('plain note\n', null)), isNull);
      expect(hasFmTail(blobOf('plain note\n', null)), isFalse);
    });

    test('a coincidental sentinel is refused rather than trusted', () {
      // Four bytes can collide. Refusing costs nothing because the caller
      // falls back to what the text says.
      final bogus = Uint8List.fromList([
        ...blobOf('x\n', null),
        0xFF, 0xFF, 0xFF, 0xFF, // nonsense length
        0x00, 0x66, 0x6D, 0x31, // \0fm1
      ]);
      expect(readFmTail(bogus), isNull);
    });

    test('a payload version this build cannot read answers null', () {
      final blob = blobOf('x\n', null);
      final future = CborCodec.encode({'v': 99, 'n': <String>[], 's': 0});
      final len = ByteData(4)..setUint32(0, future.length, Endian.little);
      final bytes = Uint8List.fromList([
        ...blob,
        ...future,
        ...len.buffer.asUint8List(),
        0x00, 0x66, 0x6D, 0x31,
      ]);
      expect(readFmTail(bytes), isNull, reason: 'degrade, never throw');
      // And the note is still readable, which is the point.
      expect(FugueStore.tryDecodeBlob(bytes)!.values.join(), 'x\n');
    });
  });
}