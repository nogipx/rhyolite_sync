/// Builds the file a user hands to support.
///
/// This library owns *format and safety*; the caller owns *content*. Keeping
/// the split there means the rules that must hold for every report — one
/// readable document, no credentials, no note text — are enforced in one
/// testable place instead of at each of the couple of dozen call sites that
/// know a fact worth reporting.
library;

/// One titled block of `label: value` rows.
class BugReportSection {
  const BugReportSection(this.title, this.fields);

  final String title;

  /// Ordered, because reading order is part of the format. A map would sort
  /// or hash them into an order nobody chose.
  final List<(String, String)> fields;

  /// Drops rows whose value is null or blank, so an unknown fact is absent
  /// rather than present-and-empty — the second reads as "the plugin measured
  /// this and got nothing", which is a different bug report.
  factory BugReportSection.compact(
    String title,
    List<(String, String?)> fields,
  ) => BugReportSection(title, [
    for (final (label, value) in fields)
      if (value != null && value.trim().isNotEmpty) (label, value.trim()),
  ]);
}

class BugReport {
  const BugReport({
    required this.generatedAt,
    required this.sections,
    this.userDescription = '',
    this.logNotice,
    this.problems = '',
    this.pathsRedacted = false,
  });

  final DateTime generatedAt;
  final List<BugReportSection> sections;

  /// Every retained warning and error, across sessions, each citing where in
  /// the main log it came from. Placed before the log because it is what a
  /// reader looks at first, and it reaches further back than one session.
  final String problems;

  /// What the user typed about the problem. Empty is allowed — a report with
  /// no description is still worth more than no report.
  final String userDescription;

  /// States anything the archive is missing — an unwritable log file, a
  /// session whose middle was dropped. Without it an incomplete report reads
  /// as a complete one, which is a wrong answer rather than a missing one.
  final String? logNotice;

  /// Whether paths in this report are pseudonymised. Purely a note to the
  /// reader: the redaction itself happened at the log output, where a path was
  /// still a declared `LogPath` rather than text to be guessed at.
  final bool pathsRedacted;

  /// Stable, sortable, collision-free within a second, and legible in a
  /// Telegram file list, which is where these names are actually read.
  ///
  /// The `.rhyolite-log` marker is what keeps either form off the server and
  /// off the user's other devices (see `isNeverSynced`).
  String get _baseName {
    final t = generatedAt.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'rhyolite-report-${t.year}${two(t.month)}${two(t.day)}'
        '-${two(t.hour)}${two(t.minute)}${two(t.second)}.rhyolite-log';
  }

  /// The one thing a report is ever delivered as.
  String get archiveName => '$_baseName.gz';

  /// Renders the whole document. Every value passes through [redactSecrets],
  /// including the caller's own fields: the guarantee should not depend on
  /// each call site having remembered.
  ///
  /// Paths are NOT scrubbed here. By the time text reaches this method a path
  /// is indistinguishable from prose, and guessing is either a leak or a
  /// mangled message. They are pseudonymised upstream, at the log output,
  /// where they are still declared `LogPath` values.
  String render() {
    final b = StringBuffer()
      ..writeln('# Rhyolite sync report')
      ..writeln()
      ..writeln('Generated: ${generatedAt.toUtc().toIso8601String()}');
    if (pathsRedacted) {
      // Stated up front, because a reader who does not know the scheme will
      // read `a1b2c3/7d8e9f.md` as corruption rather than as a pseudonym.
      b.writeln(
        'File and folder names are replaced with per-vault pseudonyms; '
        'extensions, folder structure and depth are preserved, and the same '
        'name always yields the same pseudonym.',
      );
    }
    b.writeln();

    final description = userDescription.trim();
    if (description.isNotEmpty) {
      b
        ..writeln('## What happened')
        ..writeln()
        ..writeln(redactSecrets(description))
        ..writeln();
    }

    for (final section in sections) {
      if (section.fields.isEmpty) continue;
      b
        ..writeln('## ${section.title}')
        ..writeln();
      for (final (label, value) in section.fields) {
        b.writeln('- $label: ${redactSecrets(value)}');
      }
      b.writeln();
    }

    final problemText = problems.trim();
    if (problemText.isNotEmpty) {
      b
        ..writeln('## Problems')
        ..writeln()
        ..writeln(
          'Every warning and error still on this device. Each line '
          'names its session and the `#n` to find it under in the log below.',
        )
        ..writeln()
        ..writeln('```')
        ..writeln(_fenceSafe(redactSecrets(problemText)))
        ..writeln('```')
        ..writeln();
    }

    final notice = logNotice?.trim();
    if (notice != null && notice.isNotEmpty) {
      b
        ..writeln('## Completeness')
        ..writeln()
        ..writeln(notice)
        ..writeln();
    }

    b
      ..writeln('## Log')
      ..writeln()
      ..writeln(
        'The raw log files are in `logs/` beside this document, one '
        'file per segment, copied verbatim. A segment is a plugin session or '
        'a UTC day, whichever ended first; `head` holds its opening context '
        'and `tail<n>` the rest, in order. `problems.log` collects every '
        'warning and error across segments, each citing the `#n` to find it '
        'under in its segment.',
      );
    return b.toString();
  }

  /// A log line containing ``` would close the fence early and spill the rest
  /// of the log into the document body.
  static String _fenceSafe(String text) => text.replaceAll('```', "'''");
}

/// Patterns whose *value* is a credential. Matched on the JSON-ish and
/// header-ish shapes these actually appear in, rather than on the bare word,
/// so a log line that merely mentions "passphrase" keeps its meaning.
final _secretPatterns = <RegExp>[
  // Authorization: Bearer <token>, and bare "Bearer <token>".
  RegExp(r'(Bearer\s+)[A-Za-z0-9\-._~+/]{8,}=*', caseSensitive: false),
  // PASETO v4 tokens — the account server's session format.
  RegExp(r'(v4\.(?:public|local)\.)[A-Za-z0-9\-_]{8,}'),
  // "accessToken": "...", refreshToken=..., secretAccessKey: '...'
  RegExp(
    r'''((?:access[_-]?token|refresh[_-]?token|api[_-]?key|secret[_-]?access[_-]?key|access[_-]?key[_-]?id|passphrase|password|secret)["']?\s*[:=]\s*["']?)([^\s,;"'}\]]{4,})''',
    caseSensitive: false,
  ),
];

/// Redacts anything that looks like a credential.
///
/// Deliberately narrow. Blob hashes, file ids and vault ids are long opaque
/// strings too, and they are most of what makes a sync report debuggable — a
/// scrubber wide enough to catch "any long token" would take them with it and
/// leave a report that is safe and useless. Nothing here is a substitute for
/// not logging secrets; it is the second line, for the case where an error
/// message quotes a request that carried one.
String redactSecrets(String text) {
  if (text.isEmpty) return text;
  var out = text;
  for (final pattern in _secretPatterns) {
    out = out.replaceAllMapped(pattern, (m) => '${m.group(1)}<redacted>');
  }
  return out;
}
