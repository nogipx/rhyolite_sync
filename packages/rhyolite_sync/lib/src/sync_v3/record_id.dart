import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../crypto/vault_cipher.dart';
import 'path_normalize.dart';

const _uuid = Uuid();

/// The canonical notes `fileId` for a vault-relative [relPath].
///
/// SINGLE source of truth for every producer AND consumer of a notes fileId —
/// engine push, [DiskReconciler], [StateStartupDiff], [RepairVaultUseCase] and
/// the history/version viewer. They MUST agree byte-for-byte: the server keys
/// both history events and state records by this id, so any deriver that drifts
/// writes under one id and reads under another and silently finds nothing.
/// (That is exactly what broke history reads when ids moved to the keyed HMAC
/// in 3.5.3 but the viewer kept the old unkeyed `uuid.v5`.)
///
/// [recordIdKey] is [VaultCipher.deriveRecordIdKey]; when non-null the id is the
/// server-opaque keyed HMAC. Null (a non-VaultCipher fake, tests) falls back to
/// the legacy unkeyed `uuid.v5`. The path is NFC-normalized first so the id is
/// stable across platforms (see [normalizeVaultPath]).
String deterministicFileId(
  Uint8List? recordIdKey,
  String vaultId,
  String relPath,
) {
  final path = normalizeVaultPath(relPath);
  return recordIdKey == null
      ? _uuid.v5(vaultId, path)
      : VaultCipher.recordId(recordIdKey, vaultId, path);
}
