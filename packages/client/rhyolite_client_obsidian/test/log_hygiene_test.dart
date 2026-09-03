@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// The plugin-side half of the log-hygiene guard. The engine has its own copy
/// (`rhyolite_sync/test/log_path_hygiene_test.dart`); each package has to
/// check itself, because tests run per package and a guard that only covers
/// one of them reads as coverage it does not have.
///
/// This half exists because of a gap the first real bug report exposed: the
/// settings-sync code logged through a `void Function(String)?` callback with
/// no `data:` channel, so neither the redactor nor the engine's guard could
/// see it. Both files now use a [LogScope] like everything else, and the
/// config-tree exemption moved onto the value (`LogPath.config`) where it
/// cannot quietly stop being true.
void main() {
  final logCall = RegExp(
    r'\b(_log|log|logger|_logger)\??\.(call|info|warning|error|debug|trace|fatal)\(',
  );

  /// Names holding a vault-relative path or an endpoint URL.
  final sensitiveVariable = RegExp(
    r'\$\{?[\w.!\[\]()]*\b('
    r'relPath|knownPath|scopedPath|conflictPath|oldPath|newPath|'
    r'targetPath|destPath|\w*\.path|'
    r'\w*[Uu]rl|\w*[Uu]ri|serverUrl|baseUrl|endpoint'
    r')\b',
  );

  test('no log message interpolates a vault path or an endpoint url', () {
    final offenders = <String>[];

    for (final dir in ['lib', 'bin']) {
      final root = Directory(dir);
      if (!root.existsSync()) continue;

      for (final entry in root.listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.dart')) continue;

        final lines = entry.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (!logCall.hasMatch(lines[i])) continue;

          final buffer = StringBuffer();
          for (var j = i; j < lines.length && j < i + 12; j++) {
            buffer.writeln(lines[j]);
            if (lines[j].trimRight().endsWith(');')) break;
          }
          final call = buffer.toString();

          // A path after `data:` is the point; only the message is inspected.
          final dataAt = call.indexOf('data:');
          final message = dataAt == -1 ? call : call.substring(0, dataAt);

          final match = sensitiveVariable.firstMatch(message);
          if (match != null) {
            offenders.add('${entry.path}:${i + 1}  ${match.group(0)}');
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Declare it instead of interpolating it:\n'
          "  _log.info('message', data: {'path': LogPath(relPath)});\n"
          "  _log.info('message', data: {'url': LogUrl(serverUrl)});\n"
          'Offending sites:\n${offenders.join('\n')}',
    );
  });
}
