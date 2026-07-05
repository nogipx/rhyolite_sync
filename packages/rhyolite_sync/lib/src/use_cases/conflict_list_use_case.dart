import '../sync_v3/file_state.dart';
import '../sync_v3/file_state_store.dart';

/// List every fileId whose register currently has more than one
/// surviving value (multi-value MvRegister — doc §6). UI uses this to
/// render a "files needing attention" panel.
class ConflictListUseCase {
  ConflictListUseCase(this._store);

  final FileStateStore _store;

  List<ConflictedFile> call() {
    final out = <ConflictedFile>[];
    for (final fileId in _store.fileIds) {
      final reg = _store.registerFor(fileId);
      if (reg == null || !reg.hasConflict) continue;
      out.add(ConflictedFile(
        fileId: fileId,
        values: reg.allValues,
      ));
    }
    return out;
  }
}

class ConflictedFile {
  const ConflictedFile({required this.fileId, required this.values});

  final String fileId;
  final List<FileState> values;

  String? get path => values.isEmpty ? null : values.first.path;
  Set<String> get blobRefs =>
      values.where((v) => !v.tombstone).map((v) => v.blobRef).toSet();
  bool get hasTombstone => values.any((v) => v.tombstone);
}
