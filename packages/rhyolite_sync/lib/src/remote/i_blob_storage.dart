import 'package:rpc_dart/rpc_dart.dart';

/// Abstract blob backend. Concrete implementations: in-memory, local SQLite,
/// gRPC-to-server, WebDAV, S3, and any encryption wrappers. All ids are
/// content hashes (sha256) of plain bytes.
///
/// All methods accept an optional [RpcContext] so the caller can attach a
/// cancellation token. RPC-backed implementations propagate it to the
/// underlying caller (rpc_dart cancels in-flight calls via a wire frame).
/// Local-only implementations may ignore the context — their operations
/// complete in microseconds.
/// The blob backend refused us — wrong credentials, or no permission.
///
/// A distinct type rather than a message to match on, because the difference
/// this carries is not "one upload failed" but "this storage will refuse
/// everything until someone changes its settings". Nothing retries its way out
/// of a 401, and treating it as a transient is how a vault went on pulling
/// every sixteen seconds, looking perfectly healthy, while every edit it made
/// was being dropped.
class BlobStorageRefused implements Exception {
  const BlobStorageRefused(this.statusCode, this.detail);

  final int statusCode;
  final String detail;

  @override
  String toString() =>
      'storage refused the request ($statusCode) — check its credentials'
      '${detail.isEmpty ? '' : ': $detail'}';
}

/// A presence probe could not get an answer for part of the batch.
///
/// Absence is a conclusion, and it may only be drawn from a reply. A probe
/// that never completed — DNS down, socket dropped, the backend answering
/// 5xx — says nothing about whether the blob is there, and the two are not
/// interchangeable: one is a blob to heal, the other is a network to wait out.
///
/// The vault that forced this: a phone whose WebDAV host briefly stopped
/// resolving. Every HEAD threw, each one was counted as "absent", and the
/// verify pass concluded 3274 of 3274 referenced blobs were gone from the
/// backend — warning the user about unrecoverable data loss and starting to
/// re-upload the entire vault over mobile data. Nothing had been lost at all.
///
/// Raised instead of returning a short set, because a caller cannot tell a
/// short set from a complete one.
class BlobProbeIncomplete implements Exception {
  const BlobProbeIncomplete(this.probed, this.unanswered);

  /// How many ids the batch asked about.
  final int probed;

  /// How many of them got no usable reply.
  final int unanswered;

  @override
  String toString() =>
      'storage did not answer $unanswered of $probed presence probe(s) — '
      'absence cannot be concluded, retrying later';
}

abstract interface class IBlobStorage {
  /// Pull blobs by id. Implementations are expected to skip missing ids
  /// silently — the resulting map may have fewer entries than requested.
  Future<Map<String, Uint8List>> download(
    List<String> blobIds, {
    RpcContext? context,
  });

  /// Upload a batch of (bytes, id) pairs. Idempotent: re-uploading the
  /// same id with the same bytes is a no-op for content-addressed
  /// backends.
  Future<void> upload(
    List<(Uint8List bytes, String blobId)> blobs, {
    RpcContext? context,
  });

  /// Remove blobs by id. Idempotent — missing ids are silently skipped.
  /// Best-effort: implementations may continue after individual failures
  /// (e.g. one DELETE 404) and return without throwing.
  Future<void> deleteMany(List<String> blobIds, {RpcContext? context});

  /// Returns the subset of [blobIds] that are durably present in the
  /// backend. Presence probe only — never transfers blob bytes. Used to
  /// detect referenced-but-absent blobs (e.g. a chunk whose upload was
  /// silently lost) so they can be re-uploaded. The local-cache presence
  /// of a chunk must NOT be assumed to imply server presence — this is the
  /// authoritative check.
  ///
  /// An id missing from the result means the backend SAID it does not hold it.
  /// Implementations that cannot get an answer for part of the batch throw
  /// [BlobProbeIncomplete] rather than reporting those ids as absent, and
  /// [BlobStorageRefused] when the backend refuses the probe outright.
  Future<Set<String>> exists(List<String> blobIds, {RpcContext? context});
}

/// A backend that can enumerate what it holds.
///
/// Separate from [IBlobStorage] because most cannot, and the ones that can do
/// it over a protocol of their own (S3 `list-type=2`, WebDAV `PROPFIND`). Only
/// one caller needs it: the bring-your-own orphan sweep, which has to know what
/// is actually in the user's bucket before it can ask the server which of it is
/// dead. Everything else addresses blobs by id and never asks "what is there?".
///
/// Decorators ([GzipBlobStorage], [EncryptedBlobStorage]) forward this when the
/// backend they wrap supports it — the ids are plaintext content hashes at
/// every layer, so listing needs no decoding.
abstract interface class IListableBlobStorage implements IBlobStorage {
  /// Every blob id the backend holds for this vault, or null when it cannot
  /// enumerate at all (protocol unsupported, request refused).
  ///
  /// A short listing is not a hazard and needs no special signal: the sweep
  /// only ever deletes ids it was shown, so missing a page costs a later
  /// sweep, not data. Null exists to keep "I cannot answer" from reading as
  /// "the bucket is empty" in a caller that reports findings to the user.
  Future<List<String>?> listBlobIds({RpcContext? context});
}
