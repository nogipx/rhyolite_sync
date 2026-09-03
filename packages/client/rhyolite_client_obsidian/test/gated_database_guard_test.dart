@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The connection hands out capabilities, not a handle.
//
// One transaction slot, two writers: the data layer holds it across awaits,
// the blob store takes it synchronously. They share a gate, and sharing needs
// an owner — GatedDatabase — which opens the handle, wraps it and drops it.
//
// This test is that abstraction's mechanical failure point, and it exists
// because the alternative was tried. d5de6423 put a correct queue inside the
// data client and shipped; the blob store was constructed six lines below it
// from the same `dbConn.database` and wrote straight past it. Nothing about
// that line read as wrong. A rule nobody can see being broken is not a rule,
// so the handle has to be absent rather than discouraged.
// ---------------------------------------------------------------------------

/// The only file allowed to name it — the one that gives it up.
const _owner = 'lib/src/engine/gated_database.dart';

/// Reaching a raw SQLite handle. `.database` on a DatabaseConnection is the
/// only way to get one in this package.
final _handle = RegExp(r'\.database\b');

Iterable<File> _sources() sync* {
  for (final root in const ['lib', 'bin']) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final e in dir.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.dart')) yield e;
    }
  }
}

void main() {
  test('no file but the owner reaches the raw connection handle', () {
    final offences = <String>[];

    for (final file in _sources()) {
      if (file.path == _owner) continue;
      final lines = file.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final code = line.trimLeft();
        // Comments may name it; the plugin's wiring explains why it does not
        // hold one.
        if (code.startsWith('//') || code.startsWith('///')) continue;
        if (_handle.hasMatch(line)) {
          offences.add('${file.path}:${i + 1}: ${line.trim()}');
        }
      }
    }

    expect(
      offences,
      isEmpty,
      reason:
          'take the capability from GatedDatabase instead. A writer built '
          'from the raw handle shares the connection with everything else and '
          'nothing with the gate, which is the collision that stopped a '
          "user's vault syncing for two days:\n${offences.join('\n')}",
    );
  });

  test('the owner still exists, so the rule above is not vacuous', () {
    expect(
      File(_owner).existsSync(),
      isTrue,
      reason:
          'if the owner is renamed, this guard passes by finding nothing and '
          'silently stops guarding anything',
    );
  });
}
