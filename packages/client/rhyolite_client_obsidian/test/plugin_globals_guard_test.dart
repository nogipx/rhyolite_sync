@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// One mutable top-level slot in the plugin entry point, and it holds the
// session.
//
// This is the mechanical failure point for the whole arrangement. PluginSession
// is only worth having if things actually go on it, and nothing about writing
// `bool _somethingNew = false;` at the top of a 3200-line file reads as wrong —
// which is how there came to be twenty of them, each needing its own line in a
// teardown prologue that a racing reload would run against the wrong instance.
//
// A load's state on the session is disposed with the load. A load's state in a
// global is shared with whatever load comes next.
//
// Immutable top-level values are fine and not matched here: `final` loggers,
// `const` limits and functions are the same for every load by definition.
// ---------------------------------------------------------------------------

const _entryPoint = 'bin/plugin.dart';

/// The one slot allowed, because onUnload has to find the session somehow.
const _allowed = '_session';

/// A top-level mutable variable: no leading whitespace, a type, a name, and
/// then `=` or `;` rather than `(`. The last part is what keeps functions and
/// getters out — `bool _isMobileApp(PluginHandle plugin) {` starts identically.
final _global = RegExp(
  r'^([A-Za-z_][A-Za-z0-9_]*(?:<[^>]*>)?\??)\s+(_[A-Za-z0-9_]*)\s*(=|;)',
);

/// Immutable, and therefore not per-load state.
final _immutable = RegExp(r'^(final|const)\b');

void main() {
  test('the entry point keeps exactly one mutable top-level slot', () {
    final lines = File(_entryPoint).readAsLinesSync();
    final found = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_immutable.hasMatch(line)) continue;
      final match = _global.firstMatch(line);
      if (match == null) continue;
      if (match.group(2) == _allowed) continue;
      found.add('$_entryPoint:${i + 1}: ${line.trim()}');
    }

    expect(
      found,
      isEmpty,
      reason:
          'put it on PluginSession instead — a field is disposed with the load '
          'that made it, a global is inherited by the next one. If it has '
          'rules with other state, give that group its own object (PlanTracker, '
          'RecoveryState) rather than adding a loose field:\n'
          '${found.join('\n')}',
    );
  });

  test('and that slot is still there, so the rule is not vacuous', () {
    final source = File(_entryPoint).readAsStringSync();
    expect(
      source.contains('PluginSession? $_allowed;'),
      isTrue,
      reason:
          'if the slot is renamed or removed this guard passes by finding '
          'nothing and silently stops guarding anything',
    );
  });
}
