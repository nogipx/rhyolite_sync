import 'dart:convert';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

/// Wire codec between a [FileState] (+ its causal context) and the
/// encrypted `StatePutItem` / `StateRecord` envelopes on the sync wire.
///
/// This is the *transport* codec: it owns the encrypt/base64 of the
/// FileState payload. (It is distinct from `FileStateCodec`, which is the
/// local-storage codec the MvRegister persistence layer uses.) Extracted
/// from `StateSyncEngine` so the push and pull paths share one definition
/// and it can be unit-tested in isolation.
class StateRecordCodec {
  StateRecordCodec({required this.cipher});

  final IVaultCipher cipher;

  /// Encode one dirty [state] (written under [contextAtWrite]) into the
  /// encrypted put item the server stores verbatim.
  Future<StatePutItem> encode(
    FileState state,
    CausalContext contextAtWrite,
  ) async {
    final wire = utf8.encode(jsonEncode(state.toWirePayload()));
    final enc = await cipher.encrypt(Uint8List.fromList(wire));
    return StatePutItem(
      fileId: state.fileId,
      encryptedState: base64Encode(enc),
      blobRef: state.tombstone ? '' : state.blobRef,
      hlcPacked: state.hlc.pack(),
      tombstone: state.tombstone,
      contextPacked: contextAtWrite.pack(),
      chunks: state.tombstone ? const [] : state.chunks,
    );
  }

  /// Decode one pulled [record] into a `TaggedValue<FileState>` suitable
  /// for `FileStateStore.applyRemote`. Throws if the payload cannot be
  /// decrypted or parsed (the caller isolates per-record failures).
  Future<TaggedValue<FileState>> decode(StateRecord record) async {
    final encrypted = base64Decode(record.encryptedState);
    final plainBytes = await cipher.decrypt(encrypted);
    final wire = FileState.wirePayloadFromBytes(plainBytes);
    final state = FileState(
      fileId: record.fileId,
      path: wire['path'] as String,
      blobRef: wire['blobRef'] as String? ?? '',
      sizeBytes: (wire['sizeBytes'] as int?) ?? 0,
      hlc: Hlc.unpack(record.hlcPacked),
      tombstone: (wire['tombstone'] as bool?) ?? record.tombstone,
      chunks: record.chunks,
    );
    final ctx = record.contextPacked.isEmpty
        ? const CausalContext.empty()
        : CausalContext.unpack(record.contextPacked);
    return TaggedValue<FileState>(state, state.hlc, context: ctx);
  }
}
