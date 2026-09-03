import 'package:rhyolite_client_obsidian/src/i18n/app_strings.dart';
import 'package:rhyolite_client_obsidian/src/i18n/language_tag.dart';
import 'package:rhyolite_client_obsidian/src/i18n/ru_strings.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// A Russian Obsidian on iPhone showed an English plugin. Detection read only
// `localStorage['language']`, which Obsidian writes when the language is picked
// EXPLICITLY — and someone whose phone is already Russian never picks anything.
// The reported tag is also regioned there (`ru-RU`), which matched no case.
//
// The probes themselves are JS and cannot run here; the normalisation they all
// funnel through can, and it is the half that silently returned English.
// ---------------------------------------------------------------------------

void main() {
  group('normalizeLanguageTag', () {
    test('a regioned tag reduces to its language', () {
      // navigator.language on a Russian phone.
      expect(normalizeLanguageTag('ru-RU'), 'ru');
      // Underscore form, seen from moment locales.
      expect(normalizeLanguageTag('ru_RU'), 'ru');
      expect(normalizeLanguageTag('en-GB'), 'en');
    });

    test('a bare tag passes through, case and padding are ignored', () {
      expect(normalizeLanguageTag('ru'), 'ru');
      expect(normalizeLanguageTag('RU'), 'ru');
      expect(normalizeLanguageTag('  ru  '), 'ru');
    });

    test('nothing in, nothing out — the caller falls through to the next '
        'source rather than guessing', () {
      expect(normalizeLanguageTag(''), '');
      expect(normalizeLanguageTag('   '), '');
    });
  });

  group('stringsFor', () {
    test('a regioned Russian tag selects Russian, which is the bug this '
        'file exists for', () {
      expect(stringsFor('ru-RU'), isA<RuStrings>());
      expect(stringsFor('ru_RU'), isA<RuStrings>());
      expect(stringsFor('ru'), isA<RuStrings>());
    });

    test('an unshipped language falls back to English rather than failing', () {
      expect(stringsFor('de'), isA<AppStrings>());
      expect(stringsFor('de'), isNot(isA<RuStrings>()));
      expect(stringsFor(''), isNot(isA<RuStrings>()));
    });
  });
}
