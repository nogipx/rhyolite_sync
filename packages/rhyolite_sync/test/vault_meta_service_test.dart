import 'dart:convert';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

import 'support/identity_cipher.dart';

/// In-memory [IVaultMetaStorage] — one opaque slot per vaultId.
class _MemMetaStorage implements IVaultMetaStorage {
  final Map<String, String> _slots = {};

  @override
  Future<String?> getEncryptedMeta(String vaultId) async => _slots[vaultId];

  @override
  Future<void> setEncryptedMeta(String vaultId, String encryptedMeta) async {
    if (encryptedMeta.isEmpty) {
      _slots.remove(vaultId);
    } else {
      _slots[vaultId] = encryptedMeta;
    }
  }
}

void main() {
  const vaultId = 'vault-1';
  late _MemMetaStorage storage;
  late VaultMetaService service;

  setUp(() {
    storage = _MemMetaStorage();
    service = VaultMetaService(
      storage: storage,
      vaultId: vaultId,
      cipher: IdentityCipher(),
    );
  });

  group('forced-binary policy round-trip', () {
    test('empty by default', () async {
      expect(await service.loadForcedBinaryExtensions(), isEmpty);
    });

    test('saves and reloads, normalising case and leading dots', () async {
      await service.saveForcedBinaryExtensions({'.Excalidraw', 'FOO', 'bar'});
      expect(
        await service.loadForcedBinaryExtensions(),
        {'excalidraw', 'foo', 'bar'},
      );
    });

    test('empty set clears the slot', () async {
      await service.saveForcedBinaryExtensions({'foo'});
      await service.saveForcedBinaryExtensions({});
      expect(await service.loadForcedBinaryExtensions(), isEmpty);
      expect(await storage.getEncryptedMeta(vaultId), isNull);
    });
  });

  group('coexistence with external blob config', () {
    final s3 = S3BlobConfig.fromJson(<String, dynamic>{
      'type': 's3',
      'endpoint': 'https://s3.example.com',
      'bucket': 'b',
      'region': 'r',
      'accessKey': 'ak',
      'secretKey': 'sk',
    });

    test('saving policy preserves an existing external blob config', () async {
      await service.saveExternalBlobConfig(s3!);
      await service.saveForcedBinaryExtensions({'foo'});

      expect(await service.loadForcedBinaryExtensions(), {'foo'});
      final loaded = await service.loadExternalBlobConfig();
      expect(loaded, isNotNull);
      expect(loaded!.kind, 's3');
    });

    test('saving external blob config preserves an existing policy', () async {
      await service.saveForcedBinaryExtensions({'foo', 'bar'});
      await service.saveExternalBlobConfig(s3!);

      expect(await service.loadForcedBinaryExtensions(), {'foo', 'bar'});
      expect((await service.loadExternalBlobConfig())!.kind, 's3');
    });

    test('clearing external blob config keeps the policy', () async {
      await service.saveExternalBlobConfig(s3!);
      await service.saveForcedBinaryExtensions({'foo'});
      await service.clearExternalBlobConfig();

      expect(await service.loadExternalBlobConfig(), isNull);
      expect(await service.loadForcedBinaryExtensions(), {'foo'});
    });
  });

  group('forward/backward compatibility', () {
    test('reads a legacy bare-ExternalBlobConfig payload', () async {
      // Pre-policy clients stored the config map directly (no wrapper key).
      final legacy = base64Encode(
        utf8.encode(jsonEncode(<String, dynamic>{
          'type': 'webdav',
          'endpoint': 'https://dav.example.com',
          'username': 'u',
          'password': 'p',
        })),
      );
      await storage.setEncryptedMeta(vaultId, legacy);

      expect((await service.loadExternalBlobConfig())!.kind, 'webdav');
      // No policy field in the legacy payload -> empty, not an error.
      expect(await service.loadForcedBinaryExtensions(), isEmpty);
    });

    test('a policy-only payload has no type, so old clients see no BYO',
        () async {
      await service.saveForcedBinaryExtensions({'foo'});
      // ExternalBlobConfig.fromJson keys off `type`; a policy-only map lacks it.
      expect(await service.loadExternalBlobConfig(), isNull);
    });
  });
}
