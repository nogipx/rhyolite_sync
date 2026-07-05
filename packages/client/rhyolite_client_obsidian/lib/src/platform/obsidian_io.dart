import 'dart:typed_data';

import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

class ObsidianIO implements IPlatformIO {
  const ObsidianIO(this._vault);

  final VaultHandle _vault;

  // Paths from the engine arrive as "/<relative>" because vaultPath = "".
  String _rel(String path) => path.startsWith('/') ? path.substring(1) : path;

  @override
  Future<Uint8List> readFile(String path) async => _vault.adapter.readBinary(_rel(path));

  @override
  Future<bool> fileExists(String path) async {
    final rel = _rel(path);
    if (rel.isEmpty) return false;
    return _vault.getFileByPath(rel) != null;
  }

  @override
  Future<bool> dirExists(String path) async {
    final rel = _rel(path);
    if (rel.isEmpty) return true; // vault root always exists
    return _vault.getFolderByPath(rel) != null;
  }

  @override
  Future<List<String>> listFiles(String path) async {
    final rel = _rel(path);
    final files = _vault.getFiles();
    if (rel.isEmpty) {
      return files.map((f) => '/${f.path}').toList();
    }
    final prefix = rel.endsWith('/') ? rel : '$rel/';
    return files.where((f) => f.path.startsWith(prefix)).map((f) => '/${f.path}').toList();
  }

  @override
  Future<void> writeFile(String path, Uint8List bytes) async {
    final rel = _rel(path);
    final existing = _vault.getFileByPath(rel);
    if (existing != null) {
      await _vault.modifyBinary(existing, bytes);
    } else {
      await _ensureParentDir(rel);
      try {
        await _vault.createBinary(rel, bytes);
      } catch (e) {
        try {
          await _vault.adapter.writeBinary(rel, bytes);
        } catch (e2) {
          throw Exception(
            'writeFile failed for "$rel": '
            'createBinary error: $e; '
            'adapter.writeBinary error: $e2',
          );
        }
      }
    }
  }

  @override
  Future<void> moveFile(String from, String to) async {
    final file = _vault.getAbstractFileByPath(_rel(from));
    if (file == null) return;
    final toRel = _rel(to);
    await _ensureParentDir(toRel);
    await _vault.rename(file, toRel);
  }

  @override
  Future<void> deleteFile(String path) async {
    final file = _vault.getFileByPath(_rel(path));
    if (file == null) return;
    await _vault.delete(file);
  }

  @override
  Future<void> deleteEmptyDirsUpTo(String dirPath, String stopAt) async {
    var current = _rel(dirPath);
    final stop = _rel(stopAt);
    while (current != stop && current.startsWith(stop)) {
      final folder = _vault.getFolderByPath(current);
      if (folder == null) {
        final slash = current.lastIndexOf('/');
        if (slash <= 0) break;
        current = current.substring(0, slash);
        continue;
      }
      final files = await listFiles(current.isEmpty ? '/' : '/$current');
      if (files.isEmpty) {
        await _vault.delete(folder);
        final slash = current.lastIndexOf('/');
        if (slash <= 0) break;
        current = current.substring(0, slash);
      } else {
        break;
      }
    }
  }

  @override
  Future<FileStatInfo?> statFile(String path) async {
    final file = _vault.getFileByPath(_rel(path));
    if (file == null) return null;
    return FileStatInfo(mtimeMs: file.stat.mtime, sizeBytes: file.stat.size);
  }

  Future<void> _ensureParentDir(String filePath) async {
    final slashIdx = filePath.lastIndexOf('/');
    if (slashIdx <= 0) return;
    final parentDir = filePath.substring(0, slashIdx);
    final parts = parentDir.split('/');
    var current = '';
    for (final part in parts) {
      current = current.isEmpty ? part : '$current/$part';
      if (_vault.getFolderByPath(current) == null) {
        try {
          await _vault.adapter.mkdir(current);
        } catch (e) {
          // ignore — createBinary/writeBinary will surface the real error if dir is missing
        }
      }
    }
  }
}
