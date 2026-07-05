import 'package:convergent/convergent.dart';

import 'file_state.dart';

/// `Codec<FileState>` over the existing [FileState.toJson] /
/// [FileState.fromJson] forms. Lets [MvRegisterCodec] from
/// `convergent` handle the outer envelope (HLC, causal context,
/// version) uniformly, leaving payload-specific schema concerns
/// (`schemaVersion`, tombstone flag, chunk list) inside [FileState].
class FileStateCodec implements Codec<FileState> {
  const FileStateCodec();

  @override
  Object? encode(FileState value) => value.toJson();

  @override
  FileState decode(Object? json) =>
      FileState.fromJson((json! as Map).cast<String, dynamic>());
}
