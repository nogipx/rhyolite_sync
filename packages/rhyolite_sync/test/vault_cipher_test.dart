// Argon2id at production params (64 MiB, t=3, p=4) runs pure-Dart on the VM and
// is slow on 2-vCPU CI runners; `derive is deterministic` does 3 derivations,
// which can brush past the test package's 30 s default. The params are baked
// into every vault's key and cannot be lowered, so widen the timeout instead.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

void main() {
  Uint8List key32(int seed) =>
      Uint8List.fromList(List.generate(32, (i) => (i + seed) & 0xff));
  final bytes = Uint8List.fromList(utf8.encode('hello vault — секрет 🔐'));

  group('VaultCipher (AES-256-GCM)', () {
    test('round-trips and emits a tagged 12-byte-nonce envelope', () async {
      final c = VaultCipher.fromRawKey(key32(1));
      final env = await c.encrypt(bytes);
      expect(env.first, 0x01, reason: 'AES-GCM envelope tag');
      // tag(1) + nonce(12) + mac(16) over the plaintext.
      expect(env.length, bytes.length + 1 + 12 + 16);
      expect(await c.decrypt(env), bytes);
    });

    test('nonce is random — same plaintext yields different ciphertext',
        () async {
      final c = VaultCipher.fromRawKey(key32(1));
      expect(await c.encrypt(bytes), isNot(equals(await c.encrypt(bytes))));
    });

    test('a different key fails to decrypt', () async {
      final env = await VaultCipher.fromRawKey(key32(1)).encrypt(bytes);
      expect(
        VaultCipher.fromRawKey(key32(2)).decrypt(env),
        throwsA(anything),
      );
    });

    test('unknown envelope tag throws UnsupportedCipherVersion', () async {
      final c = VaultCipher.fromRawKey(key32(1));
      final env = await c.encrypt(bytes);
      env[0] = 0x99; // legacy / foreign cipher tag
      expect(c.decrypt(env), throwsA(isA<UnsupportedCipherVersion>()));
    });

    test('verification token round-trips; wrong key rejects', () async {
      final c = VaultCipher.fromRawKey(key32(1));
      final token = await c.createVerificationToken();
      expect(await c.verifyToken(token), isTrue);
      expect(
        await VaultCipher.fromRawKey(key32(2)).verifyToken(token),
        isFalse,
      );
    });

    test('derive is deterministic per (passphrase, vaultId)', () async {
      final a = await VaultCipher.derive('pw', 'vault-1');
      final b = await VaultCipher.derive('pw', 'vault-1');
      expect(a.rawKeyBytes, b.rawKeyBytes);
      final other = await VaultCipher.derive('pw', 'vault-2');
      expect(a.rawKeyBytes, isNot(equals(other.rawKeyBytes)));
    });
  });
}
