/// Carries the frontmatter CRDT in the TAIL of an ordinary `\0fg1` blob.
///
/// ```
/// \0fg1 <Fugue tree, exactly as today> <fm: canonical CBOR> <u32 len> \0fm1
/// ```
///
/// The point is that nothing about the blob changes for a client that has
/// never heard of frontmatter state. `FugueTextBinaryCodec.decode` reads as
/// many blocks as its header declares and stops — it never checks whether
/// bytes remain — so an old build decodes the tree, projects the note, and
/// never learns the tail was there. Measured against the version we ship, not
/// assumed.
///
/// That is the whole reason this exists instead of a new blob tag. A new tag
/// is unreadable to every build already installed, which forces a staged
/// rollout, a fleet-wide wait, and a gate that still cannot cover a device
/// dormant longer than the server's 90-day head sweep. A tail costs none of
/// that: one release, and a device that never updates keeps working exactly as
/// it does today.
///
/// The tree therefore holds the FULL note, frontmatter region included, and
/// stays the single answer to "what does this file look like". The tail is the
/// answer to a different question — "how do two frontmatters merge" — and a
/// reader that ignores it degrades to today's character-level merge rather
/// than to nothing.
///
/// Written at the END, with the length before the sentinel, because the tree's
/// own length is not recoverable from the front: the decoder consumes what it
/// needs and does not report how much that was.
library;

import 'dart:typed_data';

import 'fm_codec.dart';
import 'fm_state.dart';

/// Marks a blob as carrying frontmatter state. Leading NUL for the same reason
/// the blob magic has one — it cannot occur in text.
const _sentinel = <int>[0x00, 0x66, 0x6D, 0x31]; // \0fm1
const _trailerLength = 4 + 4; // u32 length + sentinel

/// Appends [fm] to an already-encoded `\0fg1` blob.
Uint8List appendFmTail(Uint8List fugueBlob, FmState fm) {
  final payload = encodeFmState(fm);
  final out = Uint8List(fugueBlob.length + payload.length + _trailerLength);
  var at = 0;
  out.setRange(at, at += fugueBlob.length, fugueBlob);
  out.setRange(at, at += payload.length, payload);
  final len = ByteData(4)..setUint32(0, payload.length, Endian.little);
  out.setRange(at, at += 4, len.buffer.asUint8List());
  out.setRange(at, at += _sentinel.length, _sentinel);
  return out;
}

/// Reads the frontmatter state out of [blob], or null when there is none.
///
/// Null covers every "not for us" case: a blob written before this existed, a
/// blob an old client re-encoded (dropping the tail), a coincidental byte
/// match, and a payload version this build cannot read. All of them mean the
/// same thing to the caller — fall back to what the note's text says — so none
/// of them throws.
FmState? readFmTail(Uint8List blob) {
  if (blob.length < _trailerLength) return null;
  final sentinelAt = blob.length - _sentinel.length;
  for (var i = 0; i < _sentinel.length; i++) {
    if (blob[sentinelAt + i] != _sentinel[i]) return null;
  }
  final lengthAt = sentinelAt - 4;
  final payloadLength = ByteData.sublistView(blob, lengthAt, sentinelAt)
      .getUint32(0, Endian.little);
  final payloadStart = lengthAt - payloadLength;
  // A tree whose last bytes happen to look like the trailer would give a
  // nonsense offset. Refusing here rather than trusting it is why a false
  // positive costs nothing.
  if (payloadStart < 0) return null;
  try {
    return decodeFmState(Uint8List.sublistView(blob, payloadStart, lengthAt));
  } on FmDecodeException {
    return null;
  } catch (_) {
    // The sentinel matched by accident and the slice is not CBOR at all.
    return null;
  }
}

/// True when [blob] carries a tail this build can read.
bool hasFmTail(Uint8List blob) => readFmTail(blob) != null;
