import 'dart:typed_data';

import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_store.dart';
import 'package:rhyolite_core/rhyolite_core.dart';
import 'package:test/test.dart';

/// A contract test against `convergent`, not against our own code.
///
/// Frontmatter state rides after the Fugue tree inside an ordinary `\0fg1`
/// blob (see `fm_tail.dart`). The entire compatibility story rests on one
/// property of somebody else's decoder: it reads as many blocks as its header
/// declares and STOPS, without checking whether bytes remain.
///
/// Nobody promised that. It is true of the version we ship, it was measured
/// rather than assumed, and it could be tightened in a future release by
/// someone who reasonably thinks trailing bytes are corruption. If that
/// happens, every blob we write becomes unreadable to every peer at once —
/// silently, on a routine dependency bump.
///
/// So this file exists to make that bump fail loudly, here, with an
/// explanation. It is deliberately written against the raw codec rather than
/// through `FugueStore.tryDecodeBlob`, which catches the exception and returns
/// null: a swallowed failure would surface as a confusing null dereference
/// somewhere else instead of as the thing that actually broke.
const _whatToDoIfThisFails = '''
convergent's Fugue decoder no longer tolerates bytes after the last block.

That breaks frontmatter sync outright: we append CRDT state to the end of the
blob precisely because old clients ignore it. If the decoder now rejects it,
peers on the new library cannot read blobs written by peers on the old one.

Options, in order of preference:
  1. Restore the tolerance in convergent — trailing bytes are a documented
     extension point for us, not corruption.
  2. Have the decoder report how many bytes it consumed, so the tail can be
     located from the front and the sentinel dropped.
  3. Move the state out of the blob and into an optional FileState field.
     Bigger change: FileState.fromJson must keep its schema version, or every
     already-deployed client starts throwing on every record.
''';

const _codec = FugueTextBinaryCodec();

Uint8List _withTail(Uint8List blob, int tailBytes) =>
    Uint8List.fromList([...blob, ...List.filled(tailBytes, 0xAB)]);

void main() {
  group('convergent contract: trailing bytes after a Fugue tree', () {
    const note = '---\ntags:\n  - work\n---\n\n# Note\n\nbody text\n';

    test('the raw decoder ignores what follows the last block', () {
      final tree = FugueTextSync.seedFromText(note);
      final encoded = _codec.encode(tree);

      for (final tailBytes in [1, 8, 64, 4096]) {
        final Fugue<String> decoded;
        try {
          decoded = _codec.decode(_withTail(encoded, tailBytes));
        } catch (e) {
          fail(
            '$_whatToDoIfThisFails\nDecoder threw on a $tailBytes-byte '
            'tail: $e',
          );
        }
        expect(
          decoded.values.join(),
          note,
          reason:
              'a $tailBytes-byte tail changed the text\n'
              '$_whatToDoIfThisFails',
        );
      }
    });

    test('the decoded tree is identical, not merely equal in text', () {
      // We rely on more than the projection: the tree's dots are what a peer
      // joins against. A decoder that silently dropped or shifted elements
      // while still producing the same string would corrupt merges instead of
      // failing.
      final tree = FugueTextSync.seedFromText(note);
      final plain = _codec.decode(_codec.encode(tree));
      final tailed = _codec.decode(_withTail(_codec.encode(tree), 128));

      expect(
        tailed.elementCount,
        plain.elementCount,
        reason: _whatToDoIfThisFails,
      );
      expect(
        tailed.dots.length,
        plain.dots.length,
        reason: _whatToDoIfThisFails,
      );
      expect(
        _codec.encode(tailed),
        _codec.encode(plain),
        reason: 're-encoding must be byte-identical\n$_whatToDoIfThisFails',
      );
    });

    test('the magic-prefixed blob behaves the same way', () {
      // What actually travels: FugueStore.encodeBlob, magic included.
      final tree = FugueTextSync.seedFromText(note);
      final blob = FugueStore.encodeBlob(tree);

      expect(
        FugueStore.tryDecodeBlob(_withTail(blob, 256))?.values.join(),
        note,
        reason: _whatToDoIfThisFails,
      );
    });

    test('the tolerance is specific, not a decoder that never complains', () {
      // Without this the suite above would pass just as happily against a
      // decoder that swallows everything, and would stop meaning anything.
      // What we depend on is narrow: bytes after the last DECLARED block are
      // ignored; a header that lies is still rejected.
      expect(
        () => _codec.decode(Uint8List.fromList([9, 9, 9, 9, 9, 9, 9, 9])),
        throwsA(isA<Object>()),
        reason: 'an unsupported version byte must still be refused',
      );
      final tree = FugueTextSync.seedFromText(note);
      final truncated = Uint8List.sublistView(
        _codec.encode(tree),
        0,
        _codec.encode(tree).length ~/ 2,
      );
      expect(
        () => _codec.decode(truncated),
        throwsA(isA<Object>()),
        reason: 'a block that runs past the end must still be refused',
      );
    });

    test(
      'we append rather than rewrite, so the prefix stays byte-identical',
      () {
        // The other half of the contract, and ours to keep: whatever we add must
        // leave the bytes an old client reads untouched.
        final tree = FugueTextSync.seedFromText(note);
        final blob = FugueStore.encodeBlob(tree);
        final tailed = _withTail(blob, 32);

        expect(Uint8List.sublistView(tailed, 0, blob.length), blob);
      },
    );
  });
}
