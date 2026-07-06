import 'package:rhyolite_sync/src/sync_v3/path_normalize.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  // Same Russian filename in two Unicode forms, built from code points so the
  // source file's own encoding can't blur the distinction. "й" is composed as
  // U+0439 (NFC) or decomposed as U+0438 (и) + U+0306 (combining breve) (NFD) —
  // exactly the split macOS/APFS introduces. The "Мо"/"список" parts have no
  // canonical decomposition, so only the "й" differs.
  final composed = 'Мо${String.fromCharCode(0x0439)} список.md';
  final decomposed = 'Мо${String.fromCharCodes([0x0438, 0x0306])} список.md';
  const vaultId = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

  group('normalizeVaultPath (NFC)', () {
    test('the two forms are genuinely different byte sequences', () {
      expect(composed == decomposed, isFalse);
      // decomposed carries one extra code unit (the combining breve).
      expect(composed.length + 1, decomposed.length);
    });

    test('composed and decomposed collapse to the same composed string', () {
      expect(normalizeVaultPath(decomposed), composed);
      expect(normalizeVaultPath(composed), composed);
      expect(normalizeVaultPath(decomposed), normalizeVaultPath(composed));
    });

    test('pure ASCII is a no-op', () {
      expect(normalizeVaultPath('notes/todo.md'), 'notes/todo.md');
      expect(normalizeVaultPath('a/b/c.png'), 'a/b/c.png');
    });

    test('same file in either Unicode form yields one fileId', () {
      final idComposed = const Uuid().v5(vaultId, normalizeVaultPath(composed));
      final idDecomposed =
          const Uuid().v5(vaultId, normalizeVaultPath(decomposed));
      expect(idDecomposed, idComposed,
          reason: 'NFC/NFD must collapse to a single identity');
    });

    test('regression guard: without normalization the two forms diverge', () {
      final raw1 = const Uuid().v5(vaultId, composed);
      final raw2 = const Uuid().v5(vaultId, decomposed);
      expect(raw2, isNot(raw1),
          reason: 'proves NFD/NFC really split identity absent the fix');
    });
  });
}
