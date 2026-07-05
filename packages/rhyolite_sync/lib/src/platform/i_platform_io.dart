import 'dart:typed_data';

class FileStatInfo {
  const FileStatInfo({required this.mtimeMs, required this.sizeBytes});

  /// Last modification time in milliseconds since Unix epoch.
  final int mtimeMs;

  /// File size in bytes.
  final int sizeBytes;
}

abstract interface class IPlatformIO {
  Future<Uint8List> readFile(String absolutePath);
  Future<bool> fileExists(String absolutePath);
  Future<bool> dirExists(String absolutePath);

  /// Returns absolute paths of all files (recursively) under [absoluteDirPath].
  Future<List<String>> listFiles(String absoluteDirPath);

  /// Writes [bytes] to [absolutePath], creating parent directories as needed.
  Future<void> writeFile(String absolutePath, Uint8List bytes);

  /// Moves [from] to [to], creating parent directories for [to] as needed.
  Future<void> moveFile(String from, String to);

  /// Deletes the file at [absolutePath]. No-op if it does not exist.
  Future<void> deleteFile(String absolutePath);

  /// Deletes [dirPath] if empty, then walks up ancestors deleting each empty
  /// directory until [stopAt] (exclusive) is reached or a non-empty dir is found.
  Future<void> deleteEmptyDirsUpTo(String dirPath, String stopAt);

  /// Returns mtime + size for [absolutePath], or null if unsupported / file missing.
  Future<FileStatInfo?> statFile(String absolutePath);
}
