@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// Guards the invariant that makes bug reports safe to send: a vault path
/// reaches the log as a declared `LogPath` in the record's `data`, never
/// interpolated into the message string.
///
/// It has to be a test rather than a review habit. Redaction happens at the
/// log output, which can only act on what was declared — so a single new
/// `'... $relPath'` silently puts a note title into every report from every
/// user, and nothing else in the system would notice.
void main() {
  final logCall = RegExp(
    r'\b(_log|log|logger|_logger)\??\.(info|warning|error|debug|trace|fatal)\(',
  );

  /// Names that hold a vault-relative path or an endpoint URL. Both are the
  /// user's, and both are redacted at the output — so both must be declared.
  final sensitiveVariable = RegExp(
    r'\$\{?[\w.!\[\]()]*\b('
    r'relPath|knownPath|scopedPath|conflictPath|oldPath|newPath|'
    r'targetPath|destPath|\w*\.path|'
    r'\w*[Uu]rl|\w*[Uu]ri|serverUrl|baseUrl|endpoint'
    r')\b',
  );

  test('no log message interpolates a vault path or an endpoint url', () {
    final offenders = <String>[];

    for (final entry in Directory('lib/src').listSync(recursive: true)) {
      if (entry is! File || !entry.path.endsWith('.dart')) continue;
      final lines = entry.readAsLinesSync();

      for (var i = 0; i < lines.length; i++) {
        if (!logCall.hasMatch(lines[i])) continue;

        // The call as written: up to its closing `);`, capped so an
        // unterminated match cannot swallow the rest of the file.
        final buffer = StringBuffer();
        for (var j = i; j < lines.length && j < i + 12; j++) {
          buffer.writeln(lines[j]);
          if (lines[j].trimRight().endsWith(');')) break;
        }
        final call = buffer.toString();

        // Everything before `data:` is the message. A path is allowed after
        // it — that is the whole point — so only the message is inspected.
        final dataAt = call.indexOf('data:');
        final message = dataAt == -1 ? call : call.substring(0, dataAt);

        final match = sensitiveVariable.firstMatch(message);
        if (match != null) {
          offenders.add('${entry.path}:${i + 1}  ${match.group(0)}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Pass the path as data instead:\n'
          "  _log.info('message', data: {'path': LogPath(relPath)});\n"
          'Offending sites:\n${offenders.join('\n')}',
    );
  });
}
