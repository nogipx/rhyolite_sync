import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

const _vaultId = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';

void main() {
  group('VaultConfig — BYO secret is never persisted locally', () {
    test('toJson drops the secret externalBlobConfig, keeps the kind marker',
        () {
      final cfg = VaultConfig(
        vaultId: _vaultId,
        vaultName: 'v',
        externalBlobConfig: const S3BlobConfig(
          endpoint: 's3.example.com',
          bucket: 'b',
          accessKey: 'AKIA_SECRET',
          secretKey: 'TOP_SECRET_KEY',
        ),
        externalStorageKind: 's3',
      );

      final json = cfg.toJson();
      expect(json.containsKey('externalBlobConfig'), isFalse,
          reason: 'the secret config must never reach data.json');
      expect(json['externalStorageKind'], 's3',
          reason: 'only the non-secret kind marker is persisted');
      // Belt-and-suspenders: no secret material anywhere in the serialised form.
      expect(json.toString(), isNot(contains('TOP_SECRET_KEY')));
      expect(json.toString(), isNot(contains('AKIA_SECRET')));
    });

    test('fromJson migrates a legacy cleartext config: secret in memory, kind '
        'derived, and re-serialisation strips the secret', () {
      // An old data.json that stored the full secret-bearing config inline.
      final legacy = {
        'vaultId': _vaultId,
        'vaultName': 'v',
        'externalBlobConfig': {
          'type': 'webdav',
          'endpoint': 'dav.example.com',
          'username': 'u',
          'password': 'LEGACY_PASSWORD',
        },
      };

      final cfg = VaultConfig.fromJson(legacy);
      // The session keeps the secret in memory (fallback until the server
      // config is fetched)...
      expect(cfg.externalBlobConfig, isA<WebDavBlobConfig>());
      // ...and derives the non-secret marker for future boots.
      expect(cfg.externalStorageKind, 'webdav');

      // Re-saving strips the cleartext (this is the one-time migration).
      final reserialised = cfg.toJson();
      expect(reserialised.containsKey('externalBlobConfig'), isFalse);
      expect(reserialised['externalStorageKind'], 'webdav');
      expect(reserialised.toString(), isNot(contains('LEGACY_PASSWORD')));
    });

    test('a non-BYO vault has no kind marker', () {
      final cfg = VaultConfig(vaultId: _vaultId, vaultName: 'v');
      expect(cfg.toJson().containsKey('externalStorageKind'), isFalse);
      expect(VaultConfig.fromJson(cfg.toJson()).externalStorageKind, isNull);
    });
  });
}
