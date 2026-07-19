import 'package:rhyolite_sync/src/crypto/passphrase_validator.dart';
import 'package:test/test.dart';

void main() {
  bool ok(String p) => PassphraseValidator.validate(p).isValid;

  group('PassphraseValidator — length & character classes', () {
    test('too short is rejected', () {
      expect(ok('Ab1!xy'), isFalse);
    });
    test('fewer than 3 classes is rejected', () {
      expect(ok('abcdefghijklmnop'), isFalse); // lower only
      expect(ok('abcdefghij123456'), isFalse); // lower + digit only
    });
  });

  group('PassphraseValidator — weak patterns (M2)', () {
    test('dictionary/brand words are rejected despite high charset entropy', () {
      // The old charset-only estimator waved these through (~85 bits).
      for (final weak in const [
        'Password1234!',
        'MyPassw0rd!!',
        'Qwerty123!@#',
        'Welcome2026!',
        'Letmein123!@',
        'RhyoliteVault1!',
        'obsidianNotes9\$',
      ]) {
        expect(ok(weak), isFalse, reason: weak);
      }
    });

    test('numeric / alphabetic sequences are rejected', () {
      expect(ok('Zx9!abcdefgh'), isFalse); // abcdef run
      expect(ok('Zx!q012345678'), isFalse); // 012345 run
      expect(ok('Zx!qHGFEDCBA0'), isFalse); // descending run
    });

    test('long single-character runs are rejected', () {
      expect(ok('Zx9!aaaaBBBB'), isFalse); // aaaa run
      expect(ok('Zx9!Qwe1111\$'), isFalse); // 1111 run
    });
  });

  group('PassphraseValidator — strong passphrases pass', () {
    test('a random mixed passphrase is accepted', () {
      expect(ok('Tr7kLm9wZqB!'), isTrue);
      expect(ok('gH3\$pV8nQ2xW'), isTrue);
    });

    test('a long multi-word passphrase is accepted', () {
      expect(ok('Correct Horse Battery Staple7'), isTrue);
    });
  });
}
