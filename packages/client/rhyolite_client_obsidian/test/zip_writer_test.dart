@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:rhyolite_client_obsidian/src/diagnostics/zip_writer.dart';
import 'package:test/test.dart';

/// Unzips with the system `unzip`, so the archive is judged by something that
/// did not come out of this repository. A ZIP that only our own reader accepts
/// is not a ZIP.
Future<Map<String, String>> _unzipWithSystemTool(List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp('rhyolite-zip-test');
  try {
    final archive = File('${dir.path}/a.zip')..writeAsBytesSync(bytes);
    final result = await Process.run('unzip', [
      '-o',
      archive.path,
      '-d',
      dir.path,
    ]);
    expect(result.exitCode, 0, reason: 'unzip said: ${result.stderr}');

    final out = <String, String>{};
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      if (f.path == archive.path) continue;
      out[f.path.substring(dir.path.length + 1)] = f.readAsStringSync();
    }
    return out;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  test('the system unzip accepts the archive and reads every entry', () async {
    final bytes = await buildZip([
      const ZipEntry('report.md', '# Rhyolite sync report\n\nhello'),
      const ZipEntry('logs/20260830.head.log', '#1 boot\n#2 connected\n'),
      const ZipEntry('logs/problems.log', '#7 WRN something\n'),
    ]);

    final files = await _unzipWithSystemTool(bytes);
    expect(files.keys, hasLength(3));
    expect(files['report.md'], contains('hello'));
    expect(files['logs/20260830.head.log'], contains('#2 connected'));
    expect(files['logs/problems.log'], contains('#7 WRN'));
  });

  test('content survives compression byte for byte', () async {
    // Highly compressible, so the deflate path is genuinely exercised rather
    // than falling back to stored.
    final body = List.generate(
      2000,
      (i) => '#$i INF engine: reconcile\n',
    ).join();
    final bytes = await buildZip([ZipEntry('logs/big.log', body)]);

    expect(
      bytes.length,
      lessThan(body.length ~/ 4),
      reason: 'entries should be deflated, not stored',
    );
    final files = await _unzipWithSystemTool(bytes);
    expect(files['logs/big.log'], body);
  });

  test('an empty entry round-trips', () async {
    final files = await _unzipWithSystemTool(
      await buildZip([const ZipEntry('empty.log', '')]),
    );
    expect(files['empty.log'], '');
  });

  test('non-ascii content survives', () async {
    // The name is flagged UTF-8 in the header; the body is utf8-encoded.
    const text = 'путь не синхронизируется — проверка\n';
    final files = await _unzipWithSystemTool(
      await buildZip([const ZipEntry('report.md', text)]),
    );
    expect(files['report.md'], text);
    expect(utf8.encode(files['report.md']!).length, utf8.encode(text).length);
  });

  test('an archive with no entries is still a valid archive', () async {
    final bytes = await buildZip([]);
    final dir = await Directory.systemTemp.createTemp('rhyolite-zip-empty');
    try {
      final archive = File('${dir.path}/a.zip')..writeAsBytesSync(bytes);
      // `unzip -t` returns 0 on a valid empty archive; some builds warn, so
      // only a hard failure counts.
      final result = await Process.run('unzip', ['-t', archive.path]);
      expect(result.exitCode, anyOf(0, 1), reason: '${result.stderr}');
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
