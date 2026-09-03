import 'dart:js_interop';
// ignore_for_file: deprecated_member_use
import 'dart:js_util' as jsu;

import 'package:obsidian_dart/obsidian_dart.dart';

import 'frontmatter_audit.dart';

/// Wires the audit to the live Obsidian app.
Future<FrontmatterAuditResult> auditVault(AppHandle app) {
  final vault = app.vault;
  final files = vault.getMarkdownFiles();
  final byPath = {for (final f in files) f.path: f};

  return auditFrontmatter(
    paths: byPath.keys.toList()..sort(),
    readFile: (path) => vault.read(byPath[path]!),
    obsidianCache: (path) {
      final cache = app.metadataCache.getCache(path);
      if (cache == null) return null;
      final fm = jsu.getProperty<JSObject?>(cache, 'frontmatter');
      if (fm == null) {
        return (
          hasRegion: false,
          keys: const <String>[],
          values: const <String, Object?>{},
        );
      }
      final keys = jsu
          .callMethod<JSArray>(
            jsu.getProperty<JSObject>(jsu.globalThis, 'Object'),
            'keys',
            [fm],
          )
          .toDart
          .map((k) => (k as JSString).toDart)
          .toList();
      // Values come across as plain Dart types for the shapes we compare —
      // String, num, bool, List — and as something opaque for anything else,
      // which the comparison skips rather than guesses at.
      final values = <String, Object?>{
        for (final k in keys) k: _dartify(jsu.getProperty<Object?>(fm, k)),
      };
      return (hasRegion: true, keys: keys, values: values);
    },
  );
}

/// Converts a JS frontmatter value into something comparable, or null when it
/// is a shape the audit does not judge (a nested object, a date instance).
Object? _dartify(Object? v) {
  if (v == null || v is String || v is num || v is bool) return v;
  if (v is List) return v.map(_dartify).toList();
  final asList = jsu.callMethod<bool>(
    jsu.getProperty<JSObject>(jsu.globalThis, 'Array'),
    'isArray',
    [v],
  );
  if (asList) {
    return (v as JSArray).toDart.map((e) => _dartify(jsu.dartify(e))).toList();
  }
  return null;
}
