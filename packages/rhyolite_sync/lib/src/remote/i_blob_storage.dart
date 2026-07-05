import 'dart:typed_data';

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
  Future<void> deleteMany(
    List<String> blobIds, {
    RpcContext? context,
  });

  /// Returns the subset of [blobIds] that are durably present in the
  /// backend. Presence probe only — never transfers blob bytes. Used to
  /// detect referenced-but-absent blobs (e.g. a chunk whose upload was
  /// silently lost) so they can be re-uploaded. The local-cache presence
  /// of a chunk must NOT be assumed to imply server presence — this is the
  /// authoritative check.
  Future<Set<String>> exists(
    List<String> blobIds, {
    RpcContext? context,
  });
}
