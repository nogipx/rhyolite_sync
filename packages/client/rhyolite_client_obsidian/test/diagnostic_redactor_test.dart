import 'package:rhyolite_client_obsidian/src/diagnostics/diagnostic_redactor.dart';
import 'package:test/test.dart';

void main() {
  final r = DiagnosticRedactor(salt: 'vault-1');

  group('what a pseudonym keeps', () {
    test('the extension', () {
      expect(r.redactPath('Daily.md'), endsWith('.md'));
      expect(r.redactPath('Notes/photo.PNG'), endsWith('.PNG'));
    });

    test('the depth and the separators', () {
      final out = r.redactPath('Work/Projects/Q3 plan.md');
      expect(out.split('/'), hasLength(3));
    });

    test('a leading slash — engine paths arrive rooted', () {
      expect(r.redactPath('/Notes/Daily.md'), startsWith('/'));
    });

    test('compound extensions, which decide the sync path', () {
      // .excalidraw.md is what forces a file onto the binary conflict-copy
      // path. Hiding it would hide why the file behaves as it does.
      expect(
        r.redactPath('Drawings/Plan.excalidraw.md'),
        endsWith('.excalidraw.md'),
      );
      expect(r.redactPath('backup.tar.gz'), endsWith('.tar.gz'));
    });

    test('which files share a folder', () {
      final a = r.redactPath('Work/a.md');
      final b = r.redactPath('Work/b.md');
      expect(a.split('/').first, b.split('/').first);
    });

    test('that two mentions of one file are one file', () {
      expect(r.redactPath('Notes/Daily.md'), r.redactPath('Notes/Daily.md'));
    });
  });

  group('what a pseudonym hides', () {
    test('the note title', () {
      final out = r.redactPath('Personal/Therapy notes.md');
      expect(out, isNot(contains('Therapy')));
      expect(out, isNot(contains('Personal')));
    });

    test('folder names, at every depth', () {
      final out = r.redactPath('Medical/2026/Results.pdf');
      expect(out, isNot(contains('Medical')));
      expect(out, isNot(contains('2026')));
    });

    test('a date in the name, which is not an extension', () {
      final out = r.redactPath('2026.08.30.md');
      expect(out, endsWith('.md'));
      expect(out, isNot(contains('08')));
    });

    test('different vaults produce unrelated pseudonyms', () {
      final other = DiagnosticRedactor(salt: 'vault-2');
      expect(
        r.redactPath('Notes/Daily.md'),
        isNot(other.redactPath('Notes/Daily.md')),
      );
    });
  });

  test('an extension-less path still loses every segment', () {
    final out = r.redactPath('Work/Projects');
    expect(out, isNot(contains('Work')));
    expect(out, isNot(contains('Projects')));
    expect(out.split('/'), hasLength(2));
  });

  group('an endpoint url', () {
    test('keeps the scheme — ws vs wss decides whether iOS talks at all', () {
      expect(r.redactUrl('wss://vault.example.org:8443'), startsWith('wss://'));
      expect(r.redactUrl('ws://vault.example.org:8443'), startsWith('ws://'));
    });

    test('keeps the port — the other half of "cannot connect"', () {
      expect(r.redactUrl('wss://vault.example.org:8443'), contains(':8443'));
    });

    test('hides the host, which on self-host is the user\'s own machine', () {
      final out = r.redactUrl('wss://vault.example.org:8443');
      expect(out, isNot(contains('example')));
      expect(out, isNot(contains('vault')));
    });

    test('says whether the host was a name or an address', () {
      expect(r.redactUrl('wss://vault.example.org'), contains('<host:'));
      expect(r.redactUrl('wss://192.168.1.10:8443'), contains('<ip:'));
    });

    test('keeps localhost — it identifies nobody and is a real bug', () {
      // "this phone is pointed at 127.0.0.1" should be readable at a glance.
      expect(r.redactUrl('ws://localhost:8765'), 'ws://localhost:8765');
      expect(r.redactUrl('ws://127.0.0.1:8765'), 'ws://127.0.0.1:8765');
    });

    test('drops a credential in userinfo but reports that there was one', () {
      final out = r.redactUrl('wss://alice:hunter2@vault.example.org:8443');
      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('alice')));
      expect(out, contains('<userinfo>@'));
    });

    test('drops a token in the query but reports that there was one', () {
      final out = r.redactUrl('wss://vault.example.org/sync?token=abc123');
      expect(out, isNot(contains('abc123')));
      expect(out, contains('?<query>'));
      expect(out, contains('/<path>'));
    });

    test('the same endpoint yields the same pseudonym', () {
      expect(
        r.redactUrl('wss://a.example.org:8443'),
        r.redactUrl('wss://a.example.org:8443'),
      );
    });

    test('an unparseable url yields no fragments of itself', () {
      expect(r.redactUrl('not a url at all'), '<unparseable-url>');
    });
  });

  test("Obsidian's own config tree is left alone", () {
    // Plugin ids and theme names, never note titles — and settings-sync
    // problems are unreadable without them.
    const path = '.obsidian/plugins/dataview/main.js';
    expect(r.redactPath(path), path);
  });

  test('a name with spaces is redacted whole', () {
    // The reason paths are declared rather than detected: nothing in the text
    // of `superseded for Notes/Q3 plan.md` says where the name begins.
    final out = r.redactPath('Notes/Q3 plan.md');
    expect(out, isNot(contains('Q3')));
    expect(out, isNot(contains('plan')));
    expect(out, endsWith('.md'));
  });
}
