// ignore_for_file: deprecated_member_use

import 'dart:js_interop';
import 'dart:js_util' as jsu;

import 'app_strings.dart';
import 'en_strings.dart';
import 'ru_strings.dart';

AppStrings _current = const EnStrings();

/// The current locale's strings. Set once at plugin load via [initLocale];
/// defaults to English until then.
AppStrings get S => _current;

/// Selects strings from Obsidian's UI language. Call early in onLoad.
void initLocale() {
  _current = stringsFor(obsidianLanguage());
}

/// Maps a language code to its strings; unshipped languages fall back to English.
AppStrings stringsFor(String lang) => switch (lang) {
      'ru' => const RuStrings(),
      _ => const EnStrings(),
    };

/// Obsidian stores the UI language code in `localStorage['language']`
/// (empty/absent = English) — the standard community-plugin detection.
String obsidianLanguage() {
  try {
    final ls = jsu.getProperty<JSObject?>(jsu.globalThis, 'localStorage');
    if (ls == null) return '';
    final v = jsu.callMethod<Object?>(ls, 'getItem', ['language']);
    return (v is String ? v : '').toLowerCase();
  } catch (_) {
    return '';
  }
}
