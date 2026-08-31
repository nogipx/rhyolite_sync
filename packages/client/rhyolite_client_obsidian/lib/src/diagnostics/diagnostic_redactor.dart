import 'dart:convert';

import 'package:crypto/crypto.dart' as pc;

/// Replaces the human-readable parts of a vault path with stable pseudonyms,
/// keeping everything about it that is worth debugging.
///
/// `Work/Projects/Q3 plan.md` becomes `a1b2c3/d4e5f6/7a8b9c.md`. What survives
/// is the shape: how deep the file sits, which files share a folder, and what
/// type it is. What does not survive is the only part that says anything about
/// the person — what they called it.
///
/// Segment-wise rather than whole-path, because most sync bugs are about
/// relationships between files. Two paths in one folder still visibly share a
/// folder; a rename still visibly keeps its directory. Hashing the whole path
/// to one opaque token would throw all of that away for no extra privacy.
///
/// Pseudonyms are salted with the vaultId, so they are stable across reports
/// from the same vault — a bug reported twice about one file is recognisably
/// about one file — and unrelated between vaults.
///
/// This class only ever redacts a path it was *handed*. It does not search
/// text for things that look like paths: in `superseded for Notes/Q3 plan.md`
/// nothing in the text says whether the name begins at `Q3` or at `plan`, and
/// a guess is either a leak or a mangled message. Paths reach the log as
/// [LogPath] values instead, so the output layer knows exactly which bytes are
/// a path.
class DiagnosticRedactor {
  DiagnosticRedactor({required String salt}) : _salt = salt;

  final String _salt;
  final Map<String, String> _cache = {};

  /// Paths under Obsidian's own config tree are left alone. They hold plugin
  /// ids and theme names, never note titles, and settings-sync problems are
  /// unreadable without them. The line drawn here is "the user's own words",
  /// not "anything with a slash in it".
  static const configDirPrefixes = <String>['.obsidian/', '/.obsidian/'];

  /// Redacts one path. Extension-less paths (folder filters, for one) are
  /// handled too — every segment is hashed and nothing is kept.
  String redactPath(String path) {
    if (path.isEmpty) return path;
    for (final prefix in configDirPrefixes) {
      if (path.startsWith(prefix)) return path;
    }
    return _cache.putIfAbsent(path, () {
      final leading = path.startsWith('/') ? '/' : '';
      final trailing = path.endsWith('/') ? '/' : '';
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) return path;

      final out = <String>[];
      for (var i = 0; i < segments.length; i++) {
        final last = i == segments.length - 1;
        out.add(last ? _redactLeaf(segments[i]) : _hash(segments[i]));
      }
      return '$leading${out.join('/')}$trailing';
    });
  }

  /// The final segment: hash the name, keep the extension.
  String _redactLeaf(String name) {
    final ext = extensionOf(name);
    if (ext.isEmpty) return _hash(name);
    return '${_hash(name.substring(0, name.length - ext.length))}$ext';
  }

  /// The extension, including compound ones like `.excalidraw.md` and
  /// `.tar.gz`. Compound suffixes have to survive intact: `.excalidraw.md` is
  /// what puts a file on the force-binary path, so a report that hid it would
  /// hide the reason the file behaves the way it does.
  ///
  /// The inner suffix must be alphabetic, which keeps `2026.08.30.md` from
  /// giving up its date as though it were a format marker.
  static String extensionOf(String name) {
    final lastDot = name.lastIndexOf('.');
    if (lastDot <= 0) return '';
    final last = name.substring(lastDot);
    if (!_isAlphaSuffix(last, maxLength: 5)) return '';

    final head = name.substring(0, lastDot);
    final prevDot = head.lastIndexOf('.');
    if (prevDot > 0) {
      final prev = head.substring(prevDot);
      if (_isAlphaSuffix(prev, maxLength: 13)) return '$prev$last';
    }
    return last;
  }

  /// A `.suffix` of purely alphabetic characters within a length bound.
  static bool _isAlphaSuffix(String suffix, {required int maxLength}) {
    if (suffix.length < 2 || suffix.length > maxLength) return false;
    for (var i = 1; i < suffix.length; i++) {
      final c = suffix.codeUnitAt(i);
      final isAlpha = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
      if (!isAlpha) return false;
    }
    return true;
  }

  /// Redacts an endpoint URL, keeping only its shape.
  ///
  /// `wss://vault.example.org:8443/sync?token=abc` becomes
  /// `wss://<host:a1b2c3>:8443/<path>?<query>`.
  ///
  /// Scheme and port survive because they are most of what an endpoint bug is
  /// about — `ws` where `wss` was needed is invisible to the user and fatal on
  /// iOS, and a wrong port is the other half of "cannot connect". The host is
  /// hashed: on self-host it is the user's own machine, frequently a home
  /// address. Userinfo and the query string are dropped to markers rather than
  /// hashed, since a credential is the likeliest thing in them and marking
  /// their presence is all a reader needs.
  ///
  /// `localhost` and loopback are kept verbatim. They identify nobody, and
  /// "this phone is pointed at 127.0.0.1" is a real bug worth reading at a
  /// glance.
  String redactUrl(String url) {
    if (url.isEmpty) return url;
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) {
      // Unparseable, so nothing can be safely kept — and the fact that it did
      // not parse is itself the finding.
      return '<unparseable-url>';
    }

    final b = StringBuffer();
    if (uri.hasScheme) b.write('${uri.scheme}://');
    if (uri.userInfo.isNotEmpty) b.write('<userinfo>@');
    b.write(_host(uri.host));
    if (uri.hasPort) b.write(':${uri.port}');
    if (uri.path.isNotEmpty && uri.path != '/') b.write('/<path>');
    if (uri.hasQuery) b.write('?<query>');
    if (uri.hasFragment) b.write('#<fragment>');
    return b.toString();
  }

  String _host(String host) {
    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower == '127.0.0.1' || lower == '::1') {
      return lower;
    }
    return _isIpLiteral(lower)
        ? '<ip:${_hash(lower)}>'
        : '<host:${_hash(lower)}>';
  }

  /// Rough enough: an IPv4 literal, or anything with a colon (IPv6). Only
  /// decides which label the pseudonym carries, so a wrong guess costs a word.
  static bool _isIpLiteral(String host) {
    if (host.contains(':')) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      final n = int.tryParse(p);
      return n != null && n >= 0 && n <= 255;
    });
  }

  /// Six hex characters. Short enough to read a path at a glance, wide enough
  /// that two names in one vault will not collide.
  String _hash(String value) =>
      pc.sha256.convert(utf8.encode('$_salt $value')).toString().substring(0, 6);
}
