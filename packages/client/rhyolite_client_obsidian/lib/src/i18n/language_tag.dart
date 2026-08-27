import 'app_strings.dart';
import 'en_strings.dart';
import 'ru_strings.dart';

/// Language selection with no platform behind it.
///
/// Separate from `i18n.dart` because that file reaches into `dart:js_util` to
/// probe Obsidian, which makes it unimportable outside a browser — and the
/// half worth testing is exactly this one: the mapping that quietly answered
/// "English" for a Russian phone.

/// Reduces a BCP-47 tag to its primary subtag: `ru-RU` and `ru_RU` become `ru`.
///
/// Each source reports the language in its own shape — Obsidian's own setting
/// is bare (`ru`), `navigator.language` carries a region (`ru-RU`), moment may
/// return either — so normalising is what lets them be compared at all.
/// Without it a phone reporting `ru-RU` matched no case and fell to English.
String normalizeLanguageTag(String raw) {
  final trimmed = raw.trim().toLowerCase();
  if (trimmed.isEmpty) return '';
  final cut = trimmed.indexOf(RegExp('[-_]'));
  return cut == -1 ? trimmed : trimmed.substring(0, cut);
}

/// Maps a language code to its strings; unshipped languages fall back to
/// English rather than failing.
AppStrings stringsFor(String lang) => switch (normalizeLanguageTag(lang)) {
  'ru' => const RuStrings(),
  _ => const EnStrings(),
};
