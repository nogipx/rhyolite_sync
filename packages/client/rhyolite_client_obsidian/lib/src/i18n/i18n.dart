// ignore_for_file: deprecated_member_use

import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'app_strings.dart';
import 'en_strings.dart';
import 'language_tag.dart';

export 'language_tag.dart' show normalizeLanguageTag, stringsFor;

AppStrings _current = const EnStrings();

/// The current locale's strings. Set once at plugin load via [initLocale];
/// defaults to English until then.
AppStrings get S => _current;

/// Selects strings from Obsidian's UI language. Call early in onLoad.
void initLocale() {
  _current = stringsFor(obsidianLanguage());
}

/// Obsidian's UI language, or empty when nothing can be determined.
///
/// Three sources in decreasing order of authority. The first was once the whole
/// implementation, which is why a phone could show an English plugin inside a
/// Russian Obsidian: `localStorage['language']` is written when the language is
/// picked EXPLICITLY in settings, and someone whose device is already Russian
/// never picks anything — Obsidian follows the system and the key stays absent.
String obsidianLanguage() {
  // 1. An explicit choice in Obsidian's settings. It outranks every guess: a
  //    user running English Obsidian on a Russian system means it.
  final chosen = _readLanguage(() {
    final ls = jsu.getProperty<JSObject?>(jsu.globalThis, 'localStorage');
    if (ls == null) return null;
    return jsu.callMethod<Object?>(ls, 'getItem', ['language']);
  });
  if (chosen.isNotEmpty) return chosen;

  // 2. Obsidian bundles moment and sets its locale to the language it actually
  //    rendered — whether that came from the setting or from the system.
  final moment = _readLanguage(() {
    final m = jsu.getProperty<JSObject?>(jsu.globalThis, 'moment');
    if (m == null) return null;
    return jsu.callMethod<Object?>(m, 'locale', const []);
  });
  if (moment.isNotEmpty) return moment;

  // 3. The system language — what Obsidian follows when the setting was never
  //    touched, which is the normal state on a phone.
  return _readLanguage(() {
    final nav = jsu.getProperty<JSObject?>(jsu.globalThis, 'navigator');
    if (nav == null) return null;
    return jsu.getProperty<Object?>(nav, 'language');
  });
}

/// Runs one probe, normalised, swallowing anything it throws: a source that is
/// absent or hostile must fall through to the next, never abort detection.
String _readLanguage(Object? Function() probe) {
  try {
    final v = probe();
    return v is String ? normalizeLanguageTag(v) : '';
  } catch (_) {
    return '';
  }
}
