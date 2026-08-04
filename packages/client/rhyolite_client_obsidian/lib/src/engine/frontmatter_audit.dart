import 'package:rhyolite_sync/src/frontmatter/frontmatter_document.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_parser.dart';
import 'package:rhyolite_sync/src/frontmatter/frontmatter_split.dart';

/// Compares our frontmatter recogniser against Obsidian's own, over the real
/// vault.
///
/// The recogniser has to agree with js-yaml — the parser Obsidian runs — or our
/// idea of a file differs from what the user is looking at, and every later
/// argument about correctness rests on nothing. That agreement has been argued
/// for and unit-tested against invented strings; it has never been measured
/// against notes we did not write.
///
/// This is the only instrument that can measure it, because the authority is
/// in the runtime next to us. It is an ORACLE, not an implementation: the
/// engine cannot parse via Obsidian, since the same code has to run in the CLI
/// and two parsers would give one file two different blob ids.
///
/// Dev builds only. It walks every note in the vault and is useless to anyone
/// not working on the parser.
///
/// Split from its Obsidian binding on purpose: the judgement below — which
/// differences are disagreements and which are the recogniser working as
/// designed — is the part worth testing, and it cannot be tested at all from a
/// file that imports a JS-only package.
class FrontmatterAuditResult {
  final List<String> regionDisagreements = [];
  final List<String> keyDisagreements = [];
  final List<String> valueDisagreements = [];

  int notes = 0;
  int withFrontmatter = 0;
  int asRaw = 0;
  int withOpaque = 0;
  int withComments = 0;

  bool get clean =>
      regionDisagreements.isEmpty &&
      keyDisagreements.isEmpty &&
      valueDisagreements.isEmpty;

  String summary() {
    final b = StringBuffer()
      ..writeln('notes scanned      $notes')
      ..writeln('with frontmatter   $withFrontmatter')
      ..writeln('  parsed as raw    $asRaw')
      ..writeln('  with opaque keys $withOpaque')
      ..writeln('  with comments    $withComments')
      ..writeln('')
      ..writeln('region boundary disagreements: ${regionDisagreements.length}')
      ..writeln('key set disagreements:         ${keyDisagreements.length}')
      ..writeln('value disagreements:           ${valueDisagreements.length}');
    for (final group in [
      ('REGION', regionDisagreements),
      ('KEYS', keyDisagreements),
      ('VALUES', valueDisagreements),
    ]) {
      for (final line in group.$2.take(20)) {
        b.writeln('  ${group.$1}: $line');
      }
      if (group.$2.length > 20) {
        b.writeln('  ${group.$1}: …and ${group.$2.length - 20} more');
      }
    }
    return b.toString();
  }
}

/// What Obsidian read out of one note: whether it saw a region at all, and the
/// properties it produced.
///
/// [values] is keyed the same as [keys] and holds the JS value verbatim —
/// String, num, bool, or List. Anything else arrives as null and is skipped
/// rather than reported, since a shape we cannot compare is not evidence of
/// disagreement.
typedef ObsidianFrontmatter = ({
  bool hasRegion,
  List<String> keys,
  Map<String, Object?> values,
});

/// Runs the audit. [readFile] returns a note's text; [obsidianCache] returns
/// what Obsidian parsed, or null when it has nothing cached for that path.
Future<FrontmatterAuditResult> auditFrontmatter({
  required List<String> paths,
  required Future<String> Function(String path) readFile,
  required ObsidianFrontmatter? Function(String path) obsidianCache,
}) async {
  final result = FrontmatterAuditResult();

  for (final path in paths) {
    result.notes++;
    final String text;
    try {
      text = await readFile(path);
    } catch (_) {
      continue;
    }

    final ours = splitFrontmatter(text);
    final theirs = obsidianCache(path);
    if (theirs == null) continue;

    // The boundary first: if we disagree about whether there IS a region, or
    // where it ends, nothing downstream is meaningful.
    if ((ours.region != null) != theirs.hasRegion) {
      result.regionDisagreements.add(
        '$path — we say region=${ours.region != null}, '
        'Obsidian says ${theirs.hasRegion}',
      );
      continue;
    }
    if (ours.region == null) continue;
    result.withFrontmatter++;

    final doc = parseFrontmatterRegion(ours.region!);
    if (doc is FmRaw) {
      result.asRaw++;
      // Raw is a lossless fallback, not an error — but Obsidian showing
      // properties for a region we could not place IS worth seeing.
      if (theirs.keys.isNotEmpty) {
        result.keyDisagreements.add(
          '$path — we fell back to raw, Obsidian read '
          '${theirs.keys.length} propert${theirs.keys.length == 1 ? 'y' : 'ies'}',
        );
      }
      continue;
    }

    final map = doc as FmMap;
    if (map.entries.any((e) => e.value is FmOpaque)) result.withOpaque++;
    if (map.entries.any((e) => e.lead.isNotEmpty) || map.trail.isNotEmpty) {
      result.withComments++;
    }

    final ourKeys = map.entries.map((e) => e.key).toSet();
    final theirKeys = theirs.keys.toSet();
    if (ourKeys.length != theirKeys.length ||
        !ourKeys.containsAll(theirKeys)) {
      final missing = theirKeys.difference(ourKeys);
      final extra = ourKeys.difference(theirKeys);
      result.keyDisagreements.add(
        '$path — missing ${missing.toList()}, extra ${extra.toList()}',
      );
    }

    // Values, and with them types. Comparing key sets alone would miss the
    // failure that actually bites: reading `2026-08-03` as a date where
    // Obsidian reads a string, or `007` as text where it reads seven. The kind
    // decides whether the renderer quotes, so a disagreement there rewrites
    // the user's file into something that means something else.
    for (final entry in map.entries) {
      final theirValue = theirs.values[entry.key];
      final complaint = _compareValue(entry.value, theirValue);
      if (complaint != null) {
        result.valueDisagreements.add('$path [${entry.key}] $complaint');
      }
    }
  }

  return result;
}

/// Compares one value against what Obsidian produced. Null means agreement, or
/// a shape not worth comparing.
String? _compareValue(FmValue ours, Object? theirs) {
  // Opaque is the recogniser declining to model something on purpose, and
  // Obsidian will have produced a map or a multi-line string for it. Not a
  // disagreement — the escape hatch working.
  if (ours is FmOpaque) return null;
  // Absent from the cache: already covered by the key comparison.
  if (theirs == null) return null;

  if (ours is FmList) {
    if (theirs is! List) {
      return 'we read a list, Obsidian read ${theirs.runtimeType}';
    }
    final theirItems = theirs.map(_asText).toList();
    if (ours.items.length != theirItems.length ||
        !_sameOrder(ours.items, theirItems)) {
      return 'list differs: ours ${ours.items}, theirs $theirItems';
    }
    return null;
  }

  final scalar = ours as FmScalar;
  if (theirs is List) return 'we read a scalar, Obsidian read a list';

  switch (scalar.kind) {
    case ScalarKind.boolean:
      if (theirs is! bool) return 'we read a checkbox, Obsidian read "$theirs"';
      if ((scalar.text == 'true') != theirs) {
        return 'checkbox differs: ours ${scalar.text}, theirs $theirs';
      }
    case ScalarKind.number:
      if (theirs is! num) return 'we read a number, Obsidian read "$theirs"';
      if (num.tryParse(scalar.text) != theirs) {
        return 'number differs: ours ${scalar.text}, theirs $theirs';
      }
    case ScalarKind.text:
    case ScalarKind.date:
    case ScalarKind.datetime:
      // js-yaml's core schema has no date type, so dates arrive as strings.
      // What matters is that the TEXT survives; the kind is ours to decide and
      // only affects quoting, which the round-trip tests cover.
      if (theirs is bool || theirs is num) {
        return 'we read text "${scalar.text}", Obsidian read a '
            '${theirs is bool ? 'checkbox' : 'number'} ($theirs)';
      }
      if (_asText(theirs) != scalar.text) {
        return 'text differs: ours "${scalar.text}", theirs "${_asText(theirs)}"';
      }
  }
  return null;
}

String _asText(Object? v) => v is String ? v : '$v';

bool _sameOrder(List<String> a, List<String> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
