import 'dart:math';

class PassphraseValidationResult {
  const PassphraseValidationResult({required this.isValid, this.error});

  final bool isValid;
  final String? error;
}

class PassphraseValidator {
  static const _minLength = 12;
  static const _minEntropy = 60.0;

  static PassphraseValidationResult validate(String passphrase) {
    if (passphrase.length < _minLength) {
      return const PassphraseValidationResult(
        isValid: false,
        error: 'Passphrase must be at least 12 characters.',
      );
    }

    final hasLower = passphrase.contains(RegExp(r'[a-z]'));
    final hasUpper = passphrase.contains(RegExp(r'[A-Z]'));
    final hasDigit = passphrase.contains(RegExp(r'[0-9]'));
    final hasSpecial = passphrase.contains(RegExp(r'[^a-zA-Z0-9]'));
    final classCount = [hasLower, hasUpper, hasDigit, hasSpecial].where((b) => b).length;

    if (classCount < 3) {
      return const PassphraseValidationResult(
        isValid: false,
        error: 'Use at least 3 of: lowercase, uppercase, digits, special characters.',
      );
    }

    // The charset-cardinality entropy below is only an UPPER BOUND: it happily
    // waves through dictionary + pattern passphrases ("Password1234!" scores
    // ~85 bits despite near-zero real entropy). The vault key is derived solely
    // from this passphrase over a server-known salt (the vaultId), so a weak
    // passphrase is the realistic offline break. Reject the obvious weak shapes
    // (common words/brands, keyboard/numeric sequences, long single-char runs)
    // before trusting the entropy estimate.
    final weakness = _weaknessReason(passphrase);
    if (weakness != null) {
      return PassphraseValidationResult(isValid: false, error: weakness);
    }

    final entropy = _estimateEntropy(passphrase, hasLower, hasUpper, hasDigit, hasSpecial);
    if (entropy < _minEntropy) {
      return PassphraseValidationResult(
        isValid: false,
        error: 'Passphrase too weak (${entropy.toStringAsFixed(0)} bits). Aim for 60+ bits.',
      );
    }

    return const PassphraseValidationResult(isValid: true);
  }

  /// Common weak base words / brands. Kept small (compiled into the shipped
  /// dart2js bundle) — a full dictionary belongs in a zxcvbn-style library.
  static const _denylist = <String>[
    'password', 'passwort', 'passw0rd', 'motdepasse', 'parool', 'пароль',
    'qwerty', 'qwertz', 'azerty', 'йцукен', 'asdf', 'zxcv',
    'admin', 'root', 'welcome', 'letmein', 'iloveyou', 'monkey', 'dragon',
    'master', 'login', 'secret', 'changeme', 'default', 'sunshine', 'princess',
    'football', 'baseball', 'superman', 'trustno1', 'whatever', 'starwars',
    'rhyolite', 'obsidian', 'vault',
  ];

  /// Returns a human-readable reason when [passphrase] matches an obvious weak
  /// pattern, else null.
  static String? _weaknessReason(String passphrase) {
    final lower = passphrase.toLowerCase();
    for (final word in _denylist) {
      if (lower.contains(word)) {
        return 'Passphrase contains a common word or pattern ("$word"). '
            'Use unrelated random words or a longer, unpredictable phrase.';
      }
    }
    if (_hasRun(lower, sequential: true)) {
      return 'Avoid sequences like "abcd" or "1234" — they add almost no '
          'strength.';
    }
    if (_hasRun(lower, sequential: false)) {
      return 'Avoid repeated characters like "aaaa" or "1111".';
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
