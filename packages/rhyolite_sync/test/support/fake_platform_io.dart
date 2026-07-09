import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';

/// In-memory [IPlatformIO]. mtime advances on every write so the reconciler's
/// stat short-circuit never masks a genuine change.
class FakePlatformIO implements IPlatformIO {
  final Map<String, Uint8List> files = {};
  final Map<String, int> _mtime = {};
  int _clock = 1;

  @override
  Future<bool> fileExists(String absolutePath) async =>
      files.containsKey(absolutePath);

  @override
  Future<bool> dirExists(String absolutePath) async => true;

  @override
  Future<Uint8List> readFile(String absolutePath) async {
    final b = files[absolutePath];
    if (b == null) throw StateError('no file at $absolutePath');
    return b;
  }

  @override
  Future<void> writeFile(String absolutePath, Uint8List bytes) async {
    files[absolutePath] = bytes;
    _mtime[absolutePath] = _clock++;
  }

  @override
  Future<void> deleteFile(String absolutePath) async {
    files.remove(absolutePath);
    _mtime.remove(absolutePath);
  }

  @override
  Future<void> moveFile(String from, String to) async {
    final b = files.remove(from);
    _mtime.remove(from);
    if (b != null) {
      files[to] = b;
      _mtime[to] = _clock++;
    }
  }

  @override
  Future<void> deleteEmptyDirsUpTo(String dirPath, String stopAt) async {}

  @override
  Future<List<String>> listFiles(String absoluteDirPath) async =>
      files.keys.where((p) => p.startsWith(absoluteDirPath)).toList();

  @override
  Future<FileStatInfo?> statFile(String absolutePath) async {
    final b = files[absolutePath];
    if (b == null) return null;
    return FileStatInfo(mtimeMs: _mtime[absolutePath] ?? 0, sizeBytes: b.length);
  }
}

/// Writes only the first [limit] bytes of any oversized write, then throws —
/// models a crash / disk-full interrupting a non-atomic write. The truncated
/// prefix stays on disk, exactly as a direct `writeAsBytes` (no tmp+rename)
/// would leave it.
class PartialWriteIO extends FakePlatformIO {
  PartialWriteIO(this.limit);

  final int limit;

  /// While true, an oversized write truncates+throws. Disarm to let a later
  /// write succeed.
  bool armed = true;

  @override
  Future<void> writeFile(String absolutePath, Uint8List bytes) async {
    if (armed && bytes.length > limit) {
      await super.writeFile(
        absolutePath,
        Uint8List.fromList(bytes.sublist(0, limit)),
      );
      throw StateError(
        'simulated crash after $limit/${bytes.length} bytes to $absolutePath',
      );
    }
    await super.writeFile(absolutePath, bytes);
  }
}
