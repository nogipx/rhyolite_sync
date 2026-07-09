import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Pass-through [IVaultCipher] for tests that exercise the plain (no-E2EE)
/// blob path — encrypt/decrypt are identity, so the blob bytes on the wire are
/// exactly the plain content.
class IdentityCipher implements IVaultCipher {
  @override
  Future<Uint8List> encrypt(Uint8List plaintext) async => plaintext;

  @override
  Future<Uint8List> decrypt(Uint8List ciphertext) async => ciphertext;
}
