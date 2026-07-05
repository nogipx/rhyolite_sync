import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync_server_selfhost/rhyolite_sync_server_selfhost.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

void main() {
  group('LocalVaultRegistryResponder', () {
    late LocalVaultRegistryResponder responder;

    setUp(() {
      final client = IDataClient.repository(repository: InMemoryDataRepository());
      responder = LocalVaultRegistryResponder(client: client);
    });

    test('createVault then listVaults returns it', () async {
      final created = await responder.createVault(
        const CreateVaultRequest(vaultId: 'v1', vaultName: 'One'),
      );
      expect(created.vaultId, 'v1');
      expect(created.vaultName, 'One');

      final list = await responder.listVaults(const ListVaultsRequest());
      expect(list.vaults.map((v) => v.vaultId), contains('v1'));
    });

    test('createVault is idempotent (keeps original, no duplicate)', () async {
      await responder.createVault(
        const CreateVaultRequest(vaultId: 'v1', vaultName: 'One'),
      );
      final second = await responder.createVault(
        const CreateVaultRequest(vaultId: 'v1', vaultName: 'Renamed'),
      );
      expect(second.vaultName, 'One', reason: 'existing entry is returned as-is');

      final list = await responder.listVaults(const ListVaultsRequest());
      expect(list.vaults.where((v) => v.vaultId == 'v1').length, 1);
    });

    test('updateVerificationToken sets the token on an existing vault', () async {
      await responder.createVault(
        const CreateVaultRequest(vaultId: 'v1', vaultName: 'One'),
      );
      await responder.updateVerificationToken(
        const UpdateVaultTokenRequest(vaultId: 'v1', verificationToken: 'tok'),
      );

      final list = await responder.listVaults(const ListVaultsRequest());
      final v1 = list.vaults.firstWhere((v) => v.vaultId == 'v1');
      expect(v1.verificationToken, 'tok');
    });

    test('updateVerificationToken creates the vault when missing', () async {
      await responder.updateVerificationToken(
        const UpdateVaultTokenRequest(vaultId: 'v2', verificationToken: 'tok2'),
      );
      final list = await responder.listVaults(const ListVaultsRequest());
      final v2 = list.vaults.firstWhere((v) => v.vaultId == 'v2');
      expect(v2.verificationToken, 'tok2');
    });

    test('vault meta round-trips and updates', () async {
      final before =
          await responder.getVaultMeta(const VaultMetaRequest(vaultId: 'v1'));
      expect(before.encryptedMeta, isNull);

      await responder.setVaultMeta(
        const SetVaultMetaRequest(vaultId: 'v1', encryptedMeta: 'ENC'),
      );
      final after =
          await responder.getVaultMeta(const VaultMetaRequest(vaultId: 'v1'));
      expect(after.encryptedMeta, 'ENC');

      await responder.setVaultMeta(
        const SetVaultMetaRequest(vaultId: 'v1', encryptedMeta: 'ENC2'),
      );
      final updated =
          await responder.getVaultMeta(const VaultMetaRequest(vaultId: 'v1'));
      expect(updated.encryptedMeta, 'ENC2');
    });
  });
}
