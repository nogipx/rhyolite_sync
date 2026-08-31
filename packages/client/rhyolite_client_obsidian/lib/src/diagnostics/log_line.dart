/// Renders a [LogRecord] as the text the on-disk log stores.
///
/// Line-oriented on purpose. A bug report ships the *tail* of the log, and a
/// tail only reads correctly if one record is one line: cut the file anywhere
/// and every whole line you keep is still a whole record. So anything that
/// would smuggle a newline into the middle of a record — a message built from
/// user text, a `data` value — is escaped rather than embedded.
///
/// Errors and stack traces are the deliberate exception. They are worth far
/// more readable than escaped, so they go on continuation lines marked by a
/// leading tab. That keeps them recognisable as continuations: a tail that
/// starts inside a stack trace is visibly a fragment and not a fresh event.
library;

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_dart/rpc_dart.dart';

import 'diagnostic_redactor.dart';

const _levelLabels = <RpcLogLevel, String>{
  RpcLogLevel.internal: 'INT',
  RpcLogLevel.trace: 'TRC',
  RpcLogLevel.debug: 'DBG',
  RpcLogLevel.info: 'INF',
  RpcLogLevel.warning: 'WRN',
  RpcLogLevel.error: 'ERR',
  RpcLogLevel.fatal: 'FTL',
};

/// Marks a continuation line (error text, stack frames). Also the reason the
/// reader can tell a wrapped record from the next record.
const continuationPrefix = '\t';

/// Formats [record] for the log file. Returns an empty string for records that
/// carry nothing on their own — a span *start* says only that work began, and
/// the matching [LogSpan] repeats all of it with a duration attached.
///
/// [redactor] decides how a [LogPath] in the record's data is rendered. Pass
/// one for a destination the user may share — the on-device sink behind bug
/// reports — and omit it for a development console, where the real path is the
/// entire value of the line.
///
/// [seq] is the record's session-scoped number, written as a `#1234` prefix.
/// It does two jobs: the problems file cites it to point back here, and a jump
/// in it shows exactly how many records were dropped when a session outgrew
/// its slot — the accounting is the gap itself, needing no separate tally that
/// could disagree with the file.
String formatLogRecord(
  LogRecord record, {
  DiagnosticRedactor? redactor,
  int? seq,
}) {
  final body = switch (record) {
    LogEvent e => _formatEvent(e, redactor),
    LogSpan s => _formatSpan(s, redactor),
    LogSpanStart() => '',
  };
  if (body.isEmpty || seq == null) return body;
  return '#$seq $body';
}

/// Whether a record belongs in the cross-session problems file.
bool isProblem(LogRecord record) =>
    record is LogEvent && record.level.index >= RpcLogLevel.warning.index;

String _formatEvent(LogEvent e, DiagnosticRedactor? redactor) {
  final b = StringBuffer()
    ..write(formatStamp(e.timestamp))
    ..write(' ')
    ..write(_levelLabels[e.level] ?? '???')
    ..write(' ')
    ..write(e.scope);
  final tag = e.tag;
  if (tag != null && tag.isNotEmpty) b.write('[$tag]');
  b
    ..write(': ')
    ..write(escapeInline(e.message));

  _writeFields(b, e.data, redactor);
  _writeCorrelation(b, traceId: e.traceId, requestId: e.requestId, spanId: e.spanId);
  _writeFailure(b, error: e.error, stackTrace: e.stackTrace);
  return b.toString();
}

String _formatSpan(LogSpan s, DiagnosticRedactor? redactor) {
  final b = StringBuffer()
    ..write(formatStamp(s.timestamp))
    // Spans have no level of their own. They are completion notices, which is
    // what `info` means everywhere else in this codebase.
    ..write(' INF ')
    ..write(s.scope)
    ..write(': span ')
    ..write(escapeInline(s.name))
    ..write(' ')
    ..write(s.status.name)
    ..write(' ')
    ..write(s.duration.inMilliseconds)
    ..write('ms');

  _writeFields(b, s.data, redactor);
  _writeCorrelation(b, traceId: s.traceId, spanId: s.spanId, parentSpanId: s.parentSpanId);
  _writeFailure(b, error: s.error, stackTrace: s.stackTrace);
  return b.toString();
}

void _writeFields(
  StringBuffer b,
  Map<String, Object>? data,
  DiagnosticRedactor? redactor,
) {
  if (data == null || data.isEmpty) return;
  for (final entry in data.entries) {
    b.write(' ${entry.key}=${escapeInline(renderField(entry.value, redactor))}');
  }
}

/// Renders one `data` value. [LogPath] and [LogUrl] are the only values this
/// treats specially, and they are special precisely because they were declared
/// to be — no inspection of the text decides anything.
String renderField(Object value, DiagnosticRedactor? redactor) => switch (value) {
      // A config path is declared exempt at the call site — see LogPath.config.
      LogPath(isConfigRelative: true, :final value) => value,
      LogPath(:final value) =>
        redactor == null ? value : redactor.redactPath(value),
      LogUrl(:final value) =>
        redactor == null ? value : redactor.redactUrl(value),
      _ => '$value',
    };

void _writeCorrelation(
  StringBuffer b, {
  String? traceId,
  String? requestId,
  String? spanId,
  String? parentSpanId,
}) {
  if (traceId != null && traceId.isNotEmpty) b.write(' traceId=$traceId');
  if (requestId != null && requestId.isNotEmpty) b.write(' requestId=$requestId');
  if (spanId != null && spanId.isNotEmpty) b.write(' spanId=$spanId');
  if (parentSpanId != null && parentSpanId.isNotEmpty) {
    b.write(' parentSpanId=$parentSpanId');
  }
}

void _writeFailure(StringBuffer b, {Object? error, StackTrace? stackTrace}) {
  if (error != null) {
    b.write('\n${_continuation('! $error')}');
  }
  if (stackTrace != null) {
    final trace = stackTrace.toString().trimRight();
    if (trace.isNotEmpty) b.write('\n${_continuation(trace)}');
  }
}

/// Indents every line of [text] so it reads as a continuation of the record
/// above it.
String _continuation(String text) => text
    .split('\n')
    .map((line) => '$continuationPrefix${line.trimRight()}')
    .join('\n');

/// Full UTC ISO-8601 on every line, deliberately, despite costing 24 bytes on
/// a line that averages a hundred.
///
/// A shorter time-of-day stamp with the date stated once was tried and
/// reverted. Two things broke. A report ships the *tail* of a session, so the
/// line carrying the date is exactly the line a cut removes — leaving stamps
/// belonging to no particular day, which is worse than verbose because it
/// reads as certain. And the primary use of these timestamps is lining a
/// client log up against the server's: pasting a stamp from one into a search
/// of the other has to just work, with no arithmetic and no scrolling to find
/// what day it is.
///
/// UTC, always. Local time would make two devices' logs — the whole point of a
/// sync report — impossible to interleave.
String formatStamp(DateTime timestamp) => timestamp.toUtc().toIso8601String();

/// The UTC calendar day a record belongs to. A log segment rolls when this
/// changes, so a session left running for a week is still filed by day.
String utcDay(DateTime timestamp) {
  final t = timestamp.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

/// Flattens [value] to a single line. Newlines and tabs would otherwise forge
/// a record boundary, since that is exactly how records are separated.
String escapeInline(String value) => value
    .replaceAll('\\', r'\\')
    .replaceAll('\r\n', r'\n')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\n')
    .replaceAll('\t', r'\t');
