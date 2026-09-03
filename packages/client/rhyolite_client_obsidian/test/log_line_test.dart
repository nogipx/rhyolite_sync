import 'package:rhyolite_client_obsidian/src/diagnostics/log_line.dart';
import 'package:rhyolite_client_obsidian/src/diagnostics/diagnostic_redactor.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _at = DateTime.utc(2026, 8, 30, 1, 22, 33, 123);

LogEvent _event({
  RpcLogLevel level = RpcLogLevel.info,
  String scope = 'plugin',
  String message = 'hello',
  String? tag,
  Map<String, Object>? data,
  Object? error,
  StackTrace? stackTrace,
  String? traceId,
}) => LogEvent(
  scope: scope,
  level: level,
  message: message,
  tag: tag,
  data: data,
  error: error,
  stackTrace: stackTrace,
  traceId: traceId,
  timestamp: _at,
);

void main() {
  test('renders stamp, level, scope and message', () {
    expect(
      formatLogRecord(_event()),
      '2026-08-30T01:22:33.123Z INF plugin: hello',
    );
  });

  test('stamps in UTC regardless of the local zone', () {
    // Two devices' logs have to interleave; local time would make that
    // impossible.
    final local = DateTime.fromMillisecondsSinceEpoch(
      _at.millisecondsSinceEpoch,
    );
    expect(formatLogRecord(_event()), contains(formatStamp(local)));
    expect(formatStamp(local), endsWith('Z'));
  });

  test('a stamp copied from a server log is found by plain search', () {
    // The primary use of these timestamps. No arithmetic, no scrolling up to
    // find which day the line belongs to.
    const serverStamp = '2026-08-30T01:22:33.123Z';
    expect(formatLogRecord(_event()), contains(serverStamp));
  });

  test('every line carries its own date, for lining up against the server', () {
    // A report ships the tail of a session, so a date stated once at the head
    // is exactly what a cut removes. And a stamp copied from a server log has
    // to be findable here by plain search.
    expect(formatStamp(_at), '2026-08-30T01:22:33.123Z');
  });

  test('each level has a distinct label', () {
    final labels = {
      for (final level in RpcLogLevel.values)
        formatLogRecord(_event(level: level)).split(' ')[1],
    };
    expect(labels.length, RpcLogLevel.values.length);
  });

  test('appends tag, data fields and correlation ids', () {
    final line = formatLogRecord(
      _event(tag: 'pull', data: {'files': 3}, traceId: 'abc123'),
    );
    expect(line, contains('plugin[pull]: hello'));
    expect(line, contains('files=3'));
    expect(line, contains('traceId=abc123'));
  });

  group('one record stays one line', () {
    test('newlines in the message are escaped', () {
      final line = formatLogRecord(_event(message: 'a\nb\r\nc'));
      expect(line.contains('\n'), isFalse);
      expect(line, endsWith(r'a\nb\nc'));
    });

    test('newlines in data values are escaped', () {
      final line = formatLogRecord(_event(data: {'path': 'a\nb'}));
      expect(line.contains('\n'), isFalse);
      expect(line, contains(r'path=a\nb'));
    });
  });

  test('error and stack trace go on tab-marked continuation lines', () {
    final line = formatLogRecord(
      _event(
        level: RpcLogLevel.error,
        error: StateError('boom'),
        stackTrace: StackTrace.fromString('#0 first\n#1 second'),
      ),
    );
    final lines = line.split('\n');
    expect(lines.first, startsWith('2026-08-30T01:22:33.123Z ERR'));
    expect(
      lines.skip(1).every((l) => l.startsWith(continuationPrefix)),
      isTrue,
    );
    expect(line, contains('! Bad state: boom'));
    expect(line, contains('#1 second'));
  });

  test('a span renders its outcome and duration', () {
    final line = formatLogRecord(
      LogSpan(
        spanId: 's1',
        scope: 'sync',
        name: 'push',
        startTime: _at,
        endTime: _at.add(const Duration(milliseconds: 250)),
        status: SpanStatus.ok,
      ),
    );
    expect(line, contains('sync: span push ok 250ms'));
    expect(line, contains('spanId=s1'));
  });

  group('a declared path', () {
    final redactor = DiagnosticRedactor(salt: 'vault-1');

    LogEvent withPath(String path) =>
        _event(message: 'text reconcile begin', data: {'path': LogPath(path)});

    test('renders raw when no redactor is given — the dev console', () {
      expect(
        formatLogRecord(withPath('Notes/Q3 plan.md')),
        contains('path=Notes/Q3 plan.md'),
      );
    });

    test('is pseudonymised when a redactor is given — the shared log', () {
      final line = formatLogRecord(
        withPath('Notes/Q3 plan.md'),
        redactor: redactor,
      );
      expect(line, isNot(contains('Q3')));
      expect(line, isNot(contains('plan')));
      expect(line, contains('.md'));
    });

    test('spaces in a name survive redaction whole', () {
      // The point of declaring the path: a scanner could not tell whether the
      // name began at `Q3` or at `plan`, and would have leaked one of them.
      final line = formatLogRecord(
        withPath('A/Q3 plan.md'),
        redactor: redactor,
      );
      expect(line, isNot(contains('Q3 ')));
    });

    test('the same path yields the same pseudonym across records', () {
      final a = formatLogRecord(withPath('Notes/Daily.md'), redactor: redactor);
      final b = formatLogRecord(withPath('Notes/Daily.md'), redactor: redactor);
      expect(a, b);
    });

    test('other data fields are untouched', () {
      final line = formatLogRecord(
        _event(data: {'path': const LogPath('A/b.md'), 'chars': 42}),
        redactor: redactor,
      );
      expect(line, contains('chars=42'));
    });

    test('a config path stays readable — it names a setup, not a note', () {
      // Plugin ids and theme names are what makes a settings-sync failure
      // diagnosable ("15 dirs skipped: no manifest" is nothing without them).
      final line = formatLogRecord(
        _event(
          message: 'config scan skipped',
          data: {'resource': const LogPath.config('plugins/omnisearch')},
        ),
        redactor: redactor,
      );
      expect(line, contains('resource=plugins/omnisearch'));
    });

    test('the exemption is carried by the value, not by the file', () {
      // Same string, both kinds: only the declaration decides. A file-level
      // exemption would have covered both and stopped being true silently.
      final vault = formatLogRecord(
        _event(data: {'p': const LogPath('plugins/omnisearch')}),
        redactor: redactor,
      );
      expect(vault, isNot(contains('omnisearch')));
    });

    test('a plain string field is never treated as a path', () {
      // Only a declared LogPath is special. Nothing here inspects text.
      final line = formatLogRecord(
        _event(data: {'note': 'Notes/Daily.md'}),
        redactor: redactor,
      );
      expect(line, contains('note=Notes/Daily.md'));
    });
  });

  test('a span start renders nothing — the completed span carries it', () {
    expect(
      formatLogRecord(
        LogSpanStart(spanId: 's1', scope: 'sync', name: 'push', timestamp: _at),
      ),
      isEmpty,
    );
  });
}
