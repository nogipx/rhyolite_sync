import 'dart:typed_data';

/// Symmetric encrypt / decrypt for a single vault. Concrete instances
/// are bound to a vault key derived from a passphrase or recovery code.
abstract interface class IVaultCipher {
  Future<Uint8List> encrypt(Uint8List plaintext);
  Future<Uint8List> decrypt(Uint8List ciphertext);
}
