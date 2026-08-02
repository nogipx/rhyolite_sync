// Read-only census of every bucket in a MinIO/S3 deployment.
//
// Written to classify what migrate_blob_layout.dart skips: that script only
// recognises the `<vaultId>-blobs` layout, and a deployment old enough can
// also hold `<prefix><collection>` names from when the adapter took a
// bucketPrefix. Anything it does not recognise is left behind silently, so
// before --apply someone has to know what those buckets actually hold.
//
// Lists only — no bucket, object or metadata is ever written or removed.
//
// Usage:
//   MINIO_ENDPOINT=... MINIO_ACCESS_KEY=... MINIO_SECRET_KEY=... \
//   fvm dart run bin/inspect_blob_buckets.dart
import 'dart:io';

import 'package:minio/minio.dart';

/// How many object keys to show per bucket. Enough to recognise a shape
/// (content-addressed hex ids look nothing like anything else) without
/// printing a vault's worth of them.
const _sampleKeys = 3;

Future<void> main(List<String> args) async {
  final endPoint = Platform.environment['MINIO_ENDPOINT'] ?? 'localhost';
  final port = int.tryParse(Platform.environment['MINIO_PORT'] ?? '') ?? 9000;
  final accessKey = Platform.environment['MINIO_ACCESS_KEY'] ?? 'minioadmin';
  final secretKey = Platform.environment['MINIO_SECRET_KEY'] ?? 'minioadmin';
  final useSSL = (Platform.environment['MINIO_USE_SSL'] ?? 'false') == 'true';

  final minio = Minio(
    endPoint: endPoint,
    port: port,
    accessKey: accessKey,
    secretKey: secretKey,
    useSSL: useSSL,
    pathStyle: true,
  );

  stdout.writeln('source: $endPoint:$port');
  stdout.writeln('mode: read-only census');
  stdout.writeln('');

  final buckets = await minio.listBuckets();
  stdout.writeln('${buckets.length} bucket(s)');
  stdout.writeln('');

  var totalObjects = 0;
  var totalBytes = 0;

  for (final bucket in buckets) {
    final name = bucket.name;
    var objects = 0;
    var bytes = 0;
    final samples = <String>[];
    final topLevel = <String>{};
    String? error;

    try {
      await for (final chunk in minio.listObjects(name, recursive: true)) {
        for (final object in chunk.objects) {
          final key = object.key;
          if (key == null || key.isEmpty) continue;
          objects++;
          bytes += object.size ?? 0;
          if (samples.length < _sampleKeys) samples.add(key);
          // The first path segment tells a flat bucket (content ids at the
          // root) apart from one already carrying a collection prefix.
          final slash = key.indexOf('/');
          if (topLevel.length < 5) {
            topLevel.add(slash == -1 ? '<root>' : key.substring(0, slash));
          }
        }
      }
    } catch (e) {
      error = '$e';
    }

    totalObjects += objects;
    totalBytes += bytes;

    stdout.writeln('$name');
    if (error != null) {
      stdout.writeln('  ERROR: $error');
      continue;
    }
    stdout.writeln('  objects: $objects   bytes: $bytes');
    stdout.writeln('  top-level: ${topLevel.join(', ')}');
    for (final key in samples) {
      stdout.writeln('  key: $key');
    }
    stdout.writeln('');
  }

  stdout.writeln('total: $totalObjects object(s), $totalBytes byte(s)');
}
