import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as pc;
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:cryptography/dart.dart' show DartArgon2id;
import 'package:rhyolite_sync/rhyolite_sync.dart';

/// [IVaultCipher] implementation using AES-256-GCM AEAD.
///
/// AES-GCM is chosen so that on the web (dart2js / Obsidian) `package:crypto`
/// graphy routes through WebCrypto (`crypto.subtle`) — hardware-accelerated via
/// AES-NI / ARM crypto extensions, off the JS path. XChaCha20 has no WebCrypto
/// backend and ran pure-Dart on the UI thread (seconds for multi-MB blobs).
///
/// Key derivation: Argon2id(passphrase, salt=vaultId, m=65536, t=3, p=4).
/// Deterministic — same passphrase + vaultId always produce the same key, so any
/// client can derive it without exchanging a wrappedKey.
///
/// Wire format of [encrypt] output — a versioned envelope:
///   `tag (1 byte) || nonce (12 bytes) || cipherText (N) || mac (16 bytes)`
/// `tag = 0x01` is AES-256-GCM. The tag lets a future cipher change ship a new
/// tag (+ dual-decrypt) WITHOUT a vault wipe; an unknown tag fails loudly
/// ([UnsupportedCipherVersion]) instead of silently mis-decrypting.
///
/// NONCE: AES-GCM's 12-byte nonce is catastrophic to reuse (the "forbidden
/// attack" recovers the auth key → forgery), so nonces are random from a CSPRNG
/// (never a counter). The key is per-vault, bounding the message count.
class VaultCipher implements IVaultCipher {
  static const _verifyPlaintext = 'rhyolite-verify';
  static const _nonceLength = 12;
  static const _macLength = 16;

  /// Envelope tag for AES-256-GCM.
  static const _tagAesGcm = 0x01;

  // Argon2id parameters: 64 MiB memory, 3 iterations, 4 lanes.
  // Provides ~1–2 s KDF time on typical hardware — adequate protection
  // while remaining usable in a browser environment.
  //
  // maxIsolates:1 computes the 4 lanes sequentially in-process rather than in
  // worker isolates. The Argon2id output is byte-identical either way (lanes are
  // an algorithm parameter, not a threading choice — verified against the default
  // path), so vault keys are unaffected. It sidesteps an intermittent SIGSEGV in
  // cryptography's parallel-lane isolate path (DartArgon2State.processBlock) that
  // crashes on CI runners even under `dart test --concurrency=1`. Web has no
  // isolates, so this is a no-op there.
  static final _argon2 = DartArgon2id(
    parallelism: 4,
    memory: 65536, // 64 MiB
    iterations: 3,
    hashLength: 32,
    maxIsolates: 1,
  );

  static final _cipher = crypto.AesGcm.with256bits();

  final Uint8List _keyBytes;

  VaultCipher._(this._keyBytes);

  /// Derives vault cipher from [passphrase] and [vaultId].
  /// Uses vaultId as Argon2id salt — unique per vault, shared between clients.
  static Future<VaultCipher> derive(String passphrase, String vaultId) async {
    final secretKey = await _argon2.deriveKey(
      secretKey: crypto.SecretKey(utf8.encode(passphrase)),
      nonce: utf8.encode(vaultId),
    );
    final keyBytes = await secretKey.extractBytes();
    return VaultCipher._(Uint8List.fromList(keyBytes));
  }

  /// Creates a verification token — encrypt a known constant so the passphrase
  /// can be validated later without storing the raw key.
  Future<String> createVerificationToken() async {
    final bytes = await encrypt(Uint8List.fromList(utf8.encode(_verifyPlaintext)));
    return base64Encode(bytes);
  }

  /// Returns true if [token] decrypts to the known constant — i.e. passphrase is correct.
  Future<bool> verifyToken(String token) async {
    try {
      final bytes = await decrypt(base64Decode(token));
      return utf8.decode(bytes) == _verifyPlaintext;
    } catch (_) {
      return false;
    }
  }

  /// Restores cipher from previously saved raw key bytes (remembered key).
  factory VaultCipher.fromRawKey(Uint8List bytes) => VaultCipher._(bytes);

  /// Raw key bytes — use only for secure persistent storage (e.g. OS keychain).
  Uint8List get rawKeyBytes => _keyBytes;

  /// Derives a separate 32-byte HMAC subkey used to content-address blob ids.
  ///
  /// Blob ids are `HMAC-SHA256(subkey, plaintextChunk)` instead of a raw
  /// `sha256(plaintextChunk)`. Without the subkey a server/storage operator
  /// cannot recompute the chunk hashes of a candidate plaintext, so it can no
  /// longer confirm that a vault stores a *known* file (the confirmed-file
  /// oracle). Within-vault dedup is unaffected — every device of the vault
  /// derives the same subkey from the same passphrase-derived key.
  ///
  /// Key separation: this is one HKDF-Expand block over the AES key
  /// (`T(1) = HMAC(PRK, info || 0x01)`, RFC 5869), so the AES-GCM key is never
  /// reused directly as an HMAC key. The AES key is already a high-entropy
  /// Argon2id output, so it is a sound PRK for a single-block expansion.
  Uint8List deriveBlobIdKey() {
    final info = <int>[...utf8.encode('rhyolite/blob-id/v1'), 0x01];
    return Uint8List.fromList(pc.Hmac(pc.sha256, _keyBytes).convert(info).bytes);
  }

  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async {
    final secretKey = crypto.SecretKey(_keyBytes);
    final secretBox = await _cipher.encrypt(plaintext, secretKey: secretKey);
    final body = secretBox.concatenation(); // nonce(12) || ct || mac(16)
    final out = Uint8List(1 + body.length);
    out[0] = _tagAesGcm;
    out.setRange(1, out.length, body);
    return out;
  }

  @override
  Future<Uint8List> decrypt(Uint8List ciphertext) async {
    if (ciphertext.isEmpty) {
      throw const FormatException('empty ciphertext');
    }
    final tag = ciphertext[0];
    if (tag != _tagAesGcm) {
      // Unknown/legacy envelope (e.g. pre-AES-GCM data) — fail loudly instead
      // of feeding it to the wrong cipher.
      throw UnsupportedCipherVersion(tag);
    }
    final body = Uint8List.sublistView(ciphertext, 1);
    if (body.length < _nonceLength + _macLength) {
      throw const FormatException('ciphertext too short for AES-GCM envelope');
    }
    final secretBox = crypto.SecretBox.fromConcatenation(
      body,
      nonceLength: _nonceLength,
      macLength: _macLength,
      copy: false,
    );
    final secretKey = crypto.SecretKey(_keyBytes);
    final plain = await _cipher.decrypt(secretBox, secretKey: secretKey);
    return Uint8List.fromList(plain);
  }
}

/// Thrown by [VaultCipher.decrypt] when the envelope tag is not a cipher this
/// build understands — i.e. data written by a different/older cipher version.
class UnsupportedCipherVersion implements Exception {
  const UnsupportedCipherVersion(this.tag);

  /// The unrecognised envelope tag byte.
  final int tag;

  @override
  String toString() =>
      'UnsupportedCipherVersion: envelope tag 0x${tag.toRadixString(16)} '
      'is not supported by this build';
}
