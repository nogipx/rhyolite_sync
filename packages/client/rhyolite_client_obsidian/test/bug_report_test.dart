import 'package:rhyolite_client_obsidian/src/diagnostics/bug_report.dart';
import 'package:test/test.dart';

final _at = DateTime.utc(2026, 8, 30, 1, 22, 33);

BugReport _report({
  List<BugReportSection> sections = const [],
  String userDescription = '',
  String? logNotice,
  bool pathsRedacted = false,
}) =>
    BugReport(
      generatedAt: _at,
      sections: sections,
      userDescription: userDescription,
      logNotice: logNotice,
      pathsRedacted: pathsRedacted,
    );

void main() {
  test('the file name sorts chronologically and reads in a chat list', () {
    // The marker is what keeps the report off the server and off the user's
    // other devices, so the name is load-bearing, not cosmetic.
    expect(_report().archiveName,
        'rhyolite-report-20260830-012233.rhyolite-log.gz');
  });

  test('renders sections and rows in the order given', () {
    final text = _report(sections: [
      const BugReportSection('Environment', [('Plugin', '3.15.5')]),
      const BugReportSection('Vault', [('Files', '120'), ('Conflicts', '0')]),
    ]).render();

    expect(text.indexOf('## Environment'), lessThan(text.indexOf('## Vault')));
    expect(text, contains('- Plugin: 3.15.5'));
    expect(text.indexOf('- Files: 120'), lessThan(text.indexOf('- Conflicts: 0')));
  });

  test('a section with no rows is omitted entirely', () {
    final text = _report(
      sections: [const BugReportSection('Account', [])],
    ).render();
    expect(text, isNot(contains('## Account')));
  });

  test('compact drops unknown values rather than reporting them as blank', () {
    final section = BugReportSection.compact('Account', [
      ('Email', 'a@b.c'),
      ('Plan', null),
      ('Ends', '   '),
    ]);
    expect(section.fields, [('Email', 'a@b.c')]);
  });

  test('the description the user typed is included', () {
    final text = _report(userDescription: 'sync stops after an hour').render();
    expect(text, contains('## What happened'));
    expect(text, contains('sync stops after an hour'));
  });

  test('a log notice explains an empty log instead of leaving it ambiguous',
      () {
    final text = _report(logNotice: 'The log file could not be read.').render();
    expect(text, contains('The log file could not be read.'));
  });


  group('redaction', () {
    test('strips bearer tokens', () {
      expect(
        redactSecrets('Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc'),
        'Authorization: Bearer <redacted>',
      );
    });

    test('strips PASETO session tokens but keeps the version marker', () {
      expect(
        redactSecrets('token v4.public.SGVsbG8gd29ybGQ signature'),
        'token v4.public.<redacted> signature',
      );
    });

    test('strips credential-shaped json values', () {
      final text = redactSecrets(
        '{"accessToken": "abc123def", "refresh_token":"zzz9999"}',
      );
      expect(text, isNot(contains('abc123def')));
      expect(text, isNot(contains('zzz9999')));
      expect(text, contains('<redacted>'));
    });

    test('strips passphrases and storage keys', () {
      expect(redactSecrets('passphrase=hunter2000'), isNot(contains('hunter2000')));
      expect(
        redactSecrets('secretAccessKey: wJalrXUtnFEMI/K7MDENG'),
        isNot(contains('wJalrXUtnFEMI')),
      );
    });

    test('keeps the hashes and ids that make a report debuggable', () {
      const line = 'blobRef=e3b0c44298fc1c149afbf4c8996fb924'
          '27ae41e4649b934ca495991b7852b855 path=/Notes/Daily.md';
      expect(redactSecrets(line), line);
    });


    test('applies to every field, not only the log', () {
      final text = _report(
        sections: [
          const BugReportSection('Auth', [('Header', 'Bearer abcdefghij')]),
        ],
        userDescription: 'my password=letmein12',
      ).render();
      expect(text, isNot(contains('abcdefghij')));
      expect(text, isNot(contains('letmein12')));
    });
  });
}
