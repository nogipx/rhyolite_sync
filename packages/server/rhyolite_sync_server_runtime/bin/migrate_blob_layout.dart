// Moves blobs from the old bucket-per-vault layout into one bucket where each
// vault is a key prefix.
//
//   old:  bucket "<vaultId>-blobs"        object "<blobId>"
//   new:  bucket "<MINIO_BUCKET>"          object "<vaultId>_blobs/<blobId>"
//
// Dry run by default; pass --apply to copy. Copies are server-side, so nothing
// travels through this process, and nothing is ever deleted — the old buckets
// stay until someone removes them deliberately, which is the only way back if
// the switch has to be undone.
//
// Same-endpoint only: `copyObject` is an S3 server-side copy, so this changes
// layout in place. Moving to a different provider is a separate job (rclone).
//
// Usage:
//   MINIO_ENDPOINT=... MINIO_ACCESS_KEY=... MINIO_SECRET_KEY=... \
//   fvm dart run bin/migrate_blob_layout.dart [options]
//
// Options:
//   --apply              copy for real (default is a dry run)
//   --concurrency=N      parallel copies, default 12
//   --vault=<id>         restrict to one vault; repeatable
//   --help
import 'dart:async';
import 'dart:io';

import 'package:minio/minio.dart';

/// The suffix every per-vault bucket carried, from when a collection was a
/// bucket: collection `<vaultId>_blobs` normalised to `<vaultId>-blobs`.
const _legacySuffix = '-blobs';

/// An older layout still: the adapter used to take a `bucketPrefix` and the
/// collection was the bare vault id, giving `blobs-<vaultId>`. Two buckets in
/// production are still named this way and they hold live blobs — the same
/// content-addressed keys at the root as every other vault.
///
/// Recognising only the suffix form left them behind silently, which after a
/// switch to the new layout reads as those vaults having no files at all.
const _legacyPrefix = 'blobs-';

/// Copies in flight. Server-side copies cost this process nothing but a socket,
/// so the ceiling is the provider's write rate, not local CPU. Twelve at a
/// ~30 ms round trip is roughly 400 copies/s — comfortably under the 1000 RPS
/// write cap object stores typically impose. Raise with --concurrency if the
/// backend tolerates it; 503s are the sign you went too far.
const _defaultConcurrency = 12;

/// A vault id as both layouts spell it. Used to tell `blobs-<vaultId>` from an
/// unrelated bucket that merely starts the same way: the prefix form has no
/// second marker to check, so the shape of what follows is the only evidence
/// there is. Anything else is reported rather than guessed at.
final _vaultId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// Collection name a vault's blobs live under — and now its key prefix.
String _collectionFor(String vaultId) => '${vaultId}_blobs';

/// The bucket name the old adapter derived from a collection. Reproduced here
/// so a vault id recovered from a bucket name can be checked by rebuilding it:
/// anything that does not round-trip is left alone rather than guessed at.
String _legacyBucketFor(String collection) {
  final normalized = collection
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9-]'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return normalized;
}

class _VaultMigration {
  _VaultMigration(this.vaultId, this.sourceBucket);

  final String vaultId;
  final String sourceBucket;
  int objects = 0;
  int bytes = 0;
  int copied = 0;
  int skipped = 0;
  String? error;
}

// ---------------------------------------------------------------------------
// Progress
// ---------------------------------------------------------------------------

/// Renders a single status line, in place on a terminal and as periodic log
/// lines otherwise.
///
/// The distinction matters because this runs both from a laptop and from a pod:
/// `\r` rewriting is unreadable in `kubectl logs` (every frame becomes its own
/// entry), and a line every five seconds is unreadable on a terminal. Same
/// call site, two behaviours.
class _Progress {
  _Progress() : _terminal = stdout.hasTerminal;

  final bool _terminal;
  DateTime _lastRender = DateTime.fromMillisecondsSinceEpoch(0);
  bool _dirty = false;

  Duration get _interval =>
      _terminal ? const Duration(milliseconds: 120) : const Duration(seconds: 5);

  void render(String line, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastRender) < _interval) return;
    _lastRender = now;
    if (_terminal) {
      stdout.write('\r\x1b[2K$line');
      _dirty = true;
    } else {
      stdout.writeln(line);
    }
  }

  /// Ends the in-place line so ordinary output does not land on top of it.
  void clear() {
    if (_terminal && _dirty) {
      stdout.write('\r\x1b[2K');
      _dirty = false;
    }
  }

  /// A line that must survive the next render — printed above the status line.
  void log(String line) {
    clear();
    stdout.writeln(line);
  }
}

final _progress = _Progress();

/// Set by SIGINT. Every loop checks it and stops at the next object rather than
/// mid-copy; nothing is ever deleted and the pass is re-runnable, so an
/// interrupt costs only the work already done.
var _interrupted = false;

String _humanBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} '
      '${units[unit]}';
}

String _humanDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inHours}h ${d.inMinutes % 60}m';
}

// ---------------------------------------------------------------------------
// Bounded-concurrency runner
// ---------------------------------------------------------------------------

/// Runs [task]s with at most [concurrency] outstanding at a time.
///
/// Tasks must not throw — a throwing future would surface through
/// [Future.any] and tear down the whole pass, when the intent is that one bad
/// object is recorded and the rest continue. Callers catch inside the task.
class _Pool {
  _Pool(this.concurrency);

  final int concurrency;
  final _inFlight = <Future<void>>{};

  Future<void> add(Future<void> Function() task) async {
    if (_inFlight.length >= concurrency) {
      await Future.any(_inFlight);
    }
    late Future<void> f;
    f = task().whenComplete(() => _inFlight.remove(f));
    _inFlight.add(f);
  }

  Future<void> drain() => Future.wait(_inFlight.toList());
}

// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }

  final apply = args.contains('--apply');
  final concurrency = _intFlag(args, '--concurrency') ?? _defaultConcurrency;
  if (concurrency < 1) {
    stderr.writeln('--concurrency must be >= 1');
    exitCode = 2;
    return;
  }
  final onlyVaults = _multiFlag(args, '--vault');

  final unknownFlags = args
      .where((a) => a.startsWith('-'))
      .where((a) =>
          a != '--apply' &&
          !a.startsWith('--concurrency') &&
          !a.startsWith('--vault'))
      .toList();
  if (unknownFlags.isNotEmpty) {
    stderr.writeln('unknown option(s): ${unknownFlags.join(', ')}');
    stderr.writeln(_usage);
    exitCode = 2;
    return;
  }

  final endPoint = Platform.environment['MINIO_ENDPOINT'] ?? 'localhost';
  final port = int.tryParse(Platform.environment['MINIO_PORT'] ?? '') ?? 9000;
  final accessKey = Platform.environment['MINIO_ACCESS_KEY'] ?? 'minioadmin';
  final secretKey = Platform.environment['MINIO_SECRET_KEY'] ?? 'minioadmin';
  final useSSL = (Platform.environment['MINIO_USE_SSL'] ?? 'false') == 'true';
  final target = Platform.environment['MINIO_BUCKET'] ?? 'rhyolite-blobs';

  final minio = Minio(
    endPoint: endPoint,
    port: port,
    accessKey: accessKey,
    secretKey: secretKey,
    useSSL: useSSL,
    pathStyle: true,
  );

  ProcessSignal.sigint.watch().listen((_) {
    if (_interrupted) exit(130); // second Ctrl-C: give up waiting
    _interrupted = true;
    _progress.log('interrupt received — finishing in-flight copies…');
  });

  stdout.writeln('source: $endPoint:$port');
  stdout.writeln('target bucket: $target');
  stdout.writeln(apply ? 'mode: APPLY' : 'mode: dry run (pass --apply to copy)');
  if (apply) stdout.writeln('concurrency: $concurrency');
  if (onlyVaults.isNotEmpty) {
    stdout.writeln('restricted to: ${onlyVaults.join(', ')}');
  }
  stdout.writeln('');

  // ---- 1. Which buckets are per-vault blob buckets ----
  final buckets = await minio.listBuckets();
  final migrations = <_VaultMigration>[];
  final unrecognised = <String>[];

  for (final bucket in buckets) {
    final name = bucket.name;
    if (name == target) continue;

    // Suffix form first: `blobs-<id>-blobs` would satisfy both rules, and the
    // suffix is the one with a round-trip to check it against.
    if (name.endsWith(_legacySuffix)) {
      final vaultId = name.substring(0, name.length - _legacySuffix.length);
      // Round-trip check: rebuild the bucket name from the recovered vault id.
      // Normalisation is lossy in general (it lowercases and folds
      // separators), so a name that does not rebuild exactly is not something
      // to act on.
      if (_legacyBucketFor(_collectionFor(vaultId)) != name) {
        unrecognised.add(name);
        continue;
      }
      migrations.add(_VaultMigration(vaultId, name));
      continue;
    }

    if (name.startsWith(_legacyPrefix)) {
      final vaultId = name.substring(_legacyPrefix.length);
      // No round-trip to lean on here — the prefix form encodes the collection
      // verbatim — so the vault id has to carry the proof itself.
      if (!_vaultId.hasMatch(vaultId)) {
        unrecognised.add(name);
        continue;
      }
      migrations.add(_VaultMigration(vaultId, name));
      continue;
    }

    unrecognised.add(name);
  }

  // Collision detection runs over every discovered bucket, before --vault
  // narrows anything: a filtered run must not report a clean pass on a vault
  // whose twin was simply out of scope.
  final byVault = <String, List<String>>{};
  for (final m in migrations) {
    (byVault[m.vaultId] ??= <String>[]).add(m.sourceBucket);
  }
  // Both layouts reaching the same vault would copy into one destination
  // prefix, where skip-if-exists silently keeps whichever arrived first. That
  // is a merge nobody asked for, so it stops here instead.
  final collisions = byVault.entries.where((e) => e.value.length > 1).toList();
  if (collisions.isNotEmpty) {
    stderr.writeln('two source buckets claim the same vault:');
    for (final e in collisions) {
      stderr.writeln('  ${e.key}: ${e.value.join(', ')}');
    }
    stderr.writeln('Resolve by hand — refusing to merge them.');
    exitCode = 1;
    return;
  }

  if (onlyVaults.isNotEmpty) {
    final known = migrations.map((m) => m.vaultId).toSet();
    final missing = onlyVaults.where((v) => !known.contains(v)).toList();
    if (missing.isNotEmpty) {
      stderr.writeln('--vault named ${missing.length} vault(s) with no source '
          'bucket: ${missing.join(', ')}');
      exitCode = 2;
      return;
    }
    migrations.retainWhere((m) => onlyVaults.contains(m.vaultId));
  }

  if (unrecognised.isNotEmpty) {
    stdout.writeln('skipping ${unrecognised.length} bucket(s) that are not '
        'per-vault blob buckets:');
    for (final name in unrecognised) {
      stdout.writeln('  $name');
    }
    stdout.writeln('');
  }

  if (migrations.isEmpty) {
    stdout.writeln('nothing to migrate.');
    return;
  }

  final started = DateTime.now();

  // ---- 2. Scan ----
  //
  // Counting first is what makes the copy phase reportable: percentages and an
  // ETA need a denominator, and the old shape — listing inside the copy loop —
  // could not have one. For a dry run this phase IS the job.
  //
  // Only counts are kept, not keys: a million-object vault would otherwise sit
  // in memory for no reason, and re-listing during the copy costs one request
  // per thousand objects.
  stdout.writeln('scanning ${migrations.length} source bucket(s)…');
  for (var i = 0; i < migrations.length; i++) {
    if (_interrupted) break;
    final m = migrations[i];
    try {
      await for (final chunk in minio.listObjects(m.sourceBucket,
          recursive: true)) {
        for (final object in chunk.objects) {
          final key = object.key;
          if (key == null || key.isEmpty) continue;
          m.objects++;
          m.bytes += object.size ?? 0;
        }
        _progress.render('scan ${i + 1}/${migrations.length} · '
            '${m.vaultId} · ${m.objects} objects');
        if (_interrupted) break;
      }
    } catch (e) {
      m.error = '$e';
      _progress.log('  ERROR scanning ${m.sourceBucket}: $e');
    }
  }
  _progress.clear();

  final totalObjects = migrations.fold<int>(0, (s, m) => s + m.objects);
  final totalBytes = migrations.fold<int>(0, (s, m) => s + m.bytes);
  stdout.writeln('scan complete: ${migrations.length} vault(s), '
      '$totalObjects object(s), ${_humanBytes(totalBytes)} '
      '(${_humanDuration(DateTime.now().difference(started))})');
  stdout.writeln('');

  if (!apply) {
    _report(migrations, totalObjects, totalBytes, unrecognised);
    stdout.writeln('');
    stdout.writeln('dry run — nothing was copied. Re-run with --apply.');
    return;
  }

  // ---- 3. Target bucket ----
  if (!await minio.bucketExists(target)) {
    await minio.makeBucket(target);
    stdout.writeln('created target bucket "$target"');
  }

  // ---- 4. Copy ----
  final copyStarted = DateTime.now();
  var done = 0;

  for (var i = 0; i < migrations.length; i++) {
    if (_interrupted) break;
    final m = migrations[i];
    if (m.error != null) continue;

    final prefix = '${_collectionFor(m.vaultId)}/';

    // What is already at the destination, in one listing rather than a HEAD
    // per object. This is the difference between a repeated pass costing one
    // request per thousand objects and one per object — a re-run over a
    // migrated vault used to spend the whole original time discovering that
    // there was nothing to do.
    final present = <String>{};
    try {
      await for (final chunk
          in minio.listObjects(target, prefix: prefix, recursive: true)) {
        for (final object in chunk.objects) {
          final key = object.key;
          if (key != null) present.add(key);
        }
        _progress.render('vault ${i + 1}/${migrations.length} · ${m.vaultId} · '
            'checking destination · ${present.length} already there');
      }
    } catch (e) {
      m.error = 'listing destination: $e';
      _progress.log('  ERROR ${m.vaultId}: ${m.error}');
      continue;
    }

    final pool = _Pool(concurrency);
    try {
      await for (final chunk
          in minio.listObjects(m.sourceBucket, recursive: true)) {
        for (final object in chunk.objects) {
          if (_interrupted) break;
          final key = object.key;
          if (key == null || key.isEmpty) continue;

          final destination = '$prefix$key';
          // Re-runnable: an object already at the destination is left alone,
          // so a failed pass can simply be repeated.
          if (present.contains(destination)) {
            m.skipped++;
            done++;
            continue;
          }

          await pool.add(() async {
            try {
              await minio.copyObject(
                target,
                destination,
                '/${m.sourceBucket}/$key',
              );
              m.copied++;
            } catch (e) {
              // One object failing is recorded and the pass continues; the
              // verify phase below is what decides whether the vault is sound.
              m.error ??= '$e';
            } finally {
              done++;
              _renderCopy(i, migrations, m, done, totalObjects, copyStarted);
            }
          });
        }
        if (_interrupted) break;
      }
      await pool.drain();
    } catch (e) {
      await pool.drain();
      m.error ??= '$e';
      _progress.log('  ERROR ${m.vaultId}: $e');
    }

    _progress.clear();
    stdout.writeln('  ${m.vaultId}  copied ${m.copied}, present ${m.skipped}'
        '${m.error != null ? '  ERROR: ${m.error}' : ''}');
  }
  _progress.clear();

  if (_interrupted) {
    stdout.writeln('');
    stdout.writeln('INTERRUPTED after $done/$totalObjects object(s). '
        'Nothing was deleted — re-run to continue where this stopped.');
  }

  stdout.writeln('');
  _report(migrations, totalObjects, totalBytes, unrecognised);

  final failed = migrations.where((m) => m.error != null).length;

  if (_interrupted) {
    exitCode = 130;
    return;
  }

  // ---- 5. Verify what landed ----
  stdout.writeln('');
  stdout.writeln('verifying…');
  var mismatched = 0;
  for (var i = 0; i < migrations.length; i++) {
    final m = migrations[i];
    if (m.error != null) continue;
    final prefix = '${_collectionFor(m.vaultId)}/';
    var objects = 0;
    var bytes = 0;
    await for (final chunk
        in minio.listObjects(target, prefix: prefix, recursive: true)) {
      for (final object in chunk.objects) {
        objects++;
        bytes += object.size ?? 0;
      }
      _progress.render('verify ${i + 1}/${migrations.length} · ${m.vaultId} · '
          '$objects objects');
    }
    if (objects != m.objects || bytes != m.bytes) {
      mismatched++;
      _progress.log('  MISMATCH ${m.vaultId}: '
          'source ${m.objects}/${m.bytes}B, target $objects/${bytes}B');
    }
  }
  _progress.clear();

  final elapsed = DateTime.now().difference(started);

  if (failed > 0 || mismatched > 0) {
    stderr.writeln('');
    stderr.writeln('$failed vault(s) errored, $mismatched mismatched. '
        'The old buckets are untouched — fix and re-run.');
    exitCode = 1;
    return;
  }

  stdout.writeln('every vault matches on object count and bytes '
      '(${_humanDuration(elapsed)}).');
  stdout.writeln('');
  stdout.writeln('The old buckets are still there. Deploy the servers with '
      'MINIO_BUCKET=$target, confirm reads and writes, and only then remove '
      'them.');
}

void _renderCopy(
  int index,
  List<_VaultMigration> migrations,
  _VaultMigration current,
  int done,
  int total,
  DateTime startedAt,
) {
  final elapsed = DateTime.now().difference(startedAt);
  final rate = elapsed.inMilliseconds > 0
      ? done * 1000 / elapsed.inMilliseconds
      : 0.0;
  final percent = total > 0 ? (done * 100 / total).toStringAsFixed(1) : '0.0';
  final eta = rate > 0 && total > done
      ? _humanDuration(Duration(seconds: ((total - done) / rate).round()))
      : '—';
  _progress.render(
    'vault ${index + 1}/${migrations.length} · ${current.vaultId} · '
    '$done/$total ($percent%) · ${rate.toStringAsFixed(0)}/s · eta $eta',
  );
}

void _report(
  List<_VaultMigration> migrations,
  int totalObjects,
  int totalBytes,
  List<String> unrecognised,
) {
  stdout.writeln('vault'.padRight(40) +
      'objects'.padLeft(9) +
      'bytes'.padLeft(14) +
      'copied'.padLeft(9) +
      'present'.padLeft(9) +
      '  source');
  for (final m in migrations) {
    stdout.writeln(m.vaultId.padRight(40) +
        '${m.objects}'.padLeft(9) +
        '${m.bytes}'.padLeft(14) +
        '${m.copied}'.padLeft(9) +
        '${m.skipped}'.padLeft(9) +
        '  ${m.sourceBucket}');
    if (m.error != null) {
      stdout.writeln('  ERROR: ${m.error}');
    }
  }
  stdout.writeln('');
  stdout.writeln('${migrations.length} vault(s), $totalObjects object(s), '
      '$totalBytes byte(s) — ${_humanBytes(totalBytes)}');

  // Repeated here on purpose: printed once at the top it scrolls past the
  // table, and what is skipped is exactly what a switch to the new layout
  // would make disappear.
  if (unrecognised.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('NOT migrating ${unrecognised.length} bucket(s) — anything '
        'here that holds blobs will read as missing after the switch:');
    for (final name in unrecognised) {
      stdout.writeln('  $name');
    }
    stdout.writeln('Check them with bin/inspect_blob_buckets.dart.');
  }
}

int? _intFlag(List<String> args, String name) {
  for (final a in args) {
    if (a.startsWith('$name=')) {
      return int.tryParse(a.substring(name.length + 1));
    }
  }
  return null;
}

List<String> _multiFlag(List<String> args, String name) => args
    .where((a) => a.startsWith('$name='))
    .map((a) => a.substring(name.length + 1))
    .where((v) => v.isNotEmpty)
    .toList();

const _usage = '''
Moves blobs from bucket-per-vault into one bucket with a key prefix per vault.

  MINIO_ENDPOINT=... MINIO_ACCESS_KEY=... MINIO_SECRET_KEY=... \\
  fvm dart run bin/migrate_blob_layout.dart [options]

  --apply           copy for real (default is a dry run)
  --concurrency=N   parallel copies, default $_defaultConcurrency
  --vault=<id>      restrict to one vault; repeatable
  --help

Env: MINIO_ENDPOINT MINIO_PORT MINIO_ACCESS_KEY MINIO_SECRET_KEY
     MINIO_USE_SSL MINIO_BUCKET
''';
