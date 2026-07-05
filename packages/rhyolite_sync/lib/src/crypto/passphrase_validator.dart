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

    final entropy = _estimateEntropy(passphrase, hasLower, hasUpper, hasDigit, hasSpecial);
    if (entropy < _minEntropy) {
      return PassphraseValidationResult(
        isValid: false,
        error: 'Passphrase too weak (${entropy.toStringAsFixed(0)} bits). Aim for 60+ bits.',
      );
    }

    return const PassphraseValidationResult(isValid: true);
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
