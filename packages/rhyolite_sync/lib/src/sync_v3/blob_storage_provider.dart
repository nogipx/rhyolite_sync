import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Owns the remote blob backend for one engine run: which one it is, the hub
/// in front of it, and the key its ids are derived with.
///
/// Extracted from the engine because the three belong together and were three
/// unrelated-looking fields there. They share one lifetime — the hub caches a
/// backend built from the current config and endpoint, and the id key is
/// derived from the current cipher — so a change to either invalidates both,
/// and nothing in the engine said so.
///
/// [reset] is that statement. Called from `stop()`, it disposes the hub and
/// forgets the key, so the next run derives its own. Leaving the key memoised
/// across a cipher change is how stored and recomputed blob ids diverged
/// before (L1-7): the hub was rebuilt and the key was not.
class BlobStorageProvider {
  BlobStorageProvider({
    required IBlobStorage? Function() buildInner,
    required IVaultCipher? Function() cipher,
  }) : _buildInner = buildInner,
       _cipher = cipher;

  final IBlobStorage? Function() _buildInner;
  final IVaultCipher? Function() _cipher;

  BlobTransferHub? _hub;
  Uint8List? _idKey;
  bool _idKeyResolved = false;

  /// The backend, wrapped in a hub that dedups concurrent fetches of one blob,
  /// caps in-flight inner calls and can be cancelled wholesale.
  ///
  /// Null only when neither an external blob config nor an endpoint is
  /// available — the engine cannot reach any backend yet.
  IBlobStorage? get remote {
    final cached = _hub;
    if (cached != null) return cached;
    final inner = _buildInner();
    if (inner == null) return null;
    return _hub = BlobTransferHub(inner: inner);
  }

  /// Per-vault HMAC subkey for content-addressing blob ids.
  ///
  /// Null when the cipher is not a [VaultCipher] — a test fake — in which case
  /// ids fall back to a raw sha256. Every producer must share this one: a
  /// stored id and a recomputed id that disagree mean a file re-uploads
  /// forever.
  Uint8List? get idKey {
    if (!_idKeyResolved) {
      final c = _cipher();
      _idKey = c is VaultCipher ? c.deriveBlobIdKey() : null;
      _idKeyResolved = true;
    }
    return _idKey;
  }

  /// Ends this run's backend. The next [remote] builds a fresh one and the
  /// next [idKey] re-derives.
  void reset() {
    _hub?.dispose();
    _hub = null;
    _idKey = null;
    _idKeyResolved = false;
  }
}
