import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync/src/sync_v3/state_record_codec.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class _IdentityCipher implements IVaultCipher {
  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async => plaintext;
  @override
  Future<Uint8List> decrypt(Uint8List ciphertext) async => ciphertext;
}

/// Rebuilds the pull record from a put item, as the server would.
StateRecord _asRecord(StatePutItem item, int seq) => StateRecord(
      fileId: item.fileId,
      encryptedState: item.encryptedState,
      blobRef: item.blobRef,
      hlcPacked: item.hlcPacked,
      contextPacked: item.contextPacked,
      serverSeq: seq,
      tombstone: item.tombstone,
      chunks: item.chunks,
    );

void main() {
  test('encode -> decode round-trips a FileState and its causal context',
      () async {
    final codec = StateRecordCodec(cipher: _IdentityCipher());
    final hlc = Hlc(1234, 7, 'device-A');
    final ctx = CausalContext.from({'device-A': hlc});
    final state = FileState(
      fileId: 'file-1',
      path: 'notes/a.md',
      blobRef: 'manifest-hash',
      sizeBytes: 42,
      hlc: hlc,
      tombstone: false,
      chunks: const ['c1', 'c2'],
    );

    final item = await codec.encode(state, ctx);
    expect(item.fileId, 'file-1');
    expect(item.blobRef, 'manifest-hash');
    expect(item.chunks, const ['c1', 'c2']);

    final decoded = await codec.decode(_asRecord(item, 1));
    expect(decoded.value.fileId, state.fileId);
    expect(decoded.value.path, state.path);
    expect(decoded.value.blobRef, state.blobRef);
    expect(decoded.value.sizeBytes, state.sizeBytes);
    expect(decoded.value.hlc.pack(), state.hlc.pack());
    expect(decoded.value.tombstone, isFalse);
    expect(decoded.value.chunks, const ['c1', 'c2']);
    expect(decoded.context.pack(), ctx.pack());
  });

  test('tombstone encodes with empty blobRef and no chunks', () async {
    final codec = StateRecordCodec(cipher: _IdentityCipher());
    final state = FileState(
      fileId: 'file-2',
      path: 'gone.md',
      blobRef: 'should-be-dropped',
      sizeBytes: 0,
      hlc: Hlc(5, 0, 'device-B'),
      tombstone: true,
      chunks: const ['x'],
    );

    final item = await codec.encode(state, const CausalContext.empty());
    expect(item.tombstone, isTrue);
    expect(item.blobRef, isEmpty);
    expect(item.chunks, isEmpty);

    final decoded = await codec.decode(_asRecord(item, 2));
    expect(decoded.value.tombstone, isTrue);
  });
}
