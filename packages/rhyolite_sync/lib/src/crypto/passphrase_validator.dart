import 'dart:math';

/// Why a passphrase was rejected.
///
/// A code, not a sentence: the engine decides WHAT is wrong, the host says it
/// in the user's language. The plugin ships in English and Russian, and a
/// message hardcoded here would arrive in English regardless.
enum PassphraseWeakness {
  /// Shorter than the minimum length.
  tooShort,

  /// Fewer than three of: lowercase, uppercase, digits, symbols.
  tooFewCharacterClasses,

  /// Contains a common word or brand — see [PassphraseValidationResult.word].
  commonWord,

  /// Contains a run like `abcd` or `4321`.
  sequence,

  /// Contains a run of identical characters like `aaaa`.
  repetition,

  /// Passes the shape checks but is still too predictable for the amount of
  /// material it carries.
  tooPredictable,
}

class PassphraseValidationResult {
  const PassphraseValidationResult({
    required this.isValid,
    this.weakness,
    this.word,
    this.entropyBits,
  });

  final bool isValid;

  /// Null when [isValid].
  final PassphraseWeakness? weakness;

  /// The offending word for [PassphraseWeakness.commonWord] — worth showing,
  /// because "contains a common word" is unhelpful until the user knows which.
  final String? word;

  /// Upper-bound estimate, for diagnostics only.
  ///
  /// Deliberately NOT for display: it is charset-cardinality arithmetic, which
  /// waves through `Password1234!` at ~85 bits. Telling a user "48 bits, aim
  /// for 60" quotes a number this code itself does not trust.
  final double? entropyBits;
}

class PassphraseValidator {
  static const _minLength = 12;
  static const _minEntropy = 60.0;

  static PassphraseValidationResult validate(String passphrase) {
    if (passphrase.length < _minLength) {
      return const PassphraseValidationResult(
        isValid: false,
        weakness: PassphraseWeakness.tooShort,
      );
    }

    final hasLower = passphrase.contains(RegExp(r'[a-z]'));
    final hasUpper = passphrase.contains(RegExp(r'[A-Z]'));
    final hasDigit = passphrase.contains(RegExp(r'[0-9]'));
    final hasSpecial = passphrase.contains(RegExp(r'[^a-zA-Z0-9]'));
    final classCount = [
      hasLower,
      hasUpper,
      hasDigit,
      hasSpecial,
    ].where((b) => b).length;

    if (classCount < 3) {
      return const PassphraseValidationResult(
        isValid: false,
        weakness: PassphraseWeakness.tooFewCharacterClasses,
      );
    }

    // The charset-cardinality entropy below is only an UPPER BOUND: it happily
    // waves through dictionary + pattern passphrases ("Password1234!" scores
    // ~85 bits despite near-zero real entropy). The vault key is derived solely
    // from this passphrase over a server-known salt (the vaultId), so a weak
    // passphrase is the realistic offline break. Reject the obvious weak shapes
    // (common words/brands, keyboard/numeric sequences, long single-char runs)
    // before trusting the entropy estimate.
    final shape = _weakShape(passphrase);
    if (shape != null) return shape;

    final entropy = _estimateEntropy(
      passphrase,
      hasLower,
      hasUpper,
      hasDigit,
      hasSpecial,
    );
    if (entropy < _minEntropy) {
      return PassphraseValidationResult(
        isValid: false,
        weakness: PassphraseWeakness.tooPredictable,
        entropyBits: entropy,
      );
    }

    return PassphraseValidationResult(isValid: true, entropyBits: entropy);
  }

  /// Common weak base words / brands. Kept small (compiled into the shipped
  /// dart2js bundle) — a full dictionary belongs in a zxcvbn-style library.
  static const _denylist = <String>[
    'password',
    'passwort',
    'passw0rd',
    'motdepasse',
    'parool',
    'пароль',
    'qwerty',
    'qwertz',
    'azerty',
    'йцукен',
    'asdf',
    'zxcv',
    'admin',
    'root',
    'welcome',
    'letmein',
    'iloveyou',
    'monkey',
    'dragon',
    'master',
    'login',
    'secret',
    'changeme',
    'default',
    'sunshine',
    'princess',
    'football',
    'baseball',
    'superman',
    'trustno1',
    'whatever',
    'starwars',
    'rhyolite',
    'obsidian',
    'vault',
  ];

  /// Rejects the obvious weak shapes, or null when none matches.
  static PassphraseValidationResult? _weakShape(String passphrase) {
    final lower = passphrase.toLowerCase();
    for (final word in _denylist) {
      if (lower.contains(word)) {
        return PassphraseValidationResult(
          isValid: false,
          weakness: PassphraseWeakness.commonWord,
          word: word,
        );
      }
    }
    if (_hasRun(lower, sequential: true)) {
      return const PassphraseValidationResult(
        isValid: false,
        weakness: PassphraseWeakness.sequence,
      );
    }
    if (_hasRun(lower, sequential: false)) {
      return const PassphraseValidationResult(
        isValid: false,
        weakness: PassphraseWeakness.repetition,
      );
    }
    return null;
  }

  /// True when [s] contains a run of >= 4 characters that are either strictly
  /// sequential by code point ([sequential] = true; ascending or descending,
  /// e.g. "abcd"/"4321") or all identical ([sequential] = false, e.g. "aaaa").
  static bool _hasRun(String s, {required bool sequential}) {
    const runLen = 4;
    if (s.length < runLen) return false;
    final units = s.codeUnits;
    var asc = 1, desc = 1, same = 1;
    for (var i = 1; i < units.length; i++) {
      final d = units[i] - units[i - 1];
      asc = d == 1 ? asc + 1 : 1;
      desc = d == -1 ? desc + 1 : 1;
      same = d == 0 ? same + 1 : 1;
      if (sequential && (asc >= runLen || desc >= runLen)) return true;
      if (!sequential && same >= runLen) return true;
    }
    return false;
  }

  static double _estimateEntropy(
    String passphrase,
    bool hasLower,
    bool hasUpper,
    bool hasDigit,
    bool hasSpecial,
  ) {
    int charsetSize = 0;
    if (hasLower) charsetSize += 26;
    if (hasUpper) charsetSize += 26;
    if (hasDigit) charsetSize += 10;
    if (hasSpecial) charsetSize += 32; // conservative estimate
    return passphrase.length * log(charsetSize) / log(2);
  }
}
