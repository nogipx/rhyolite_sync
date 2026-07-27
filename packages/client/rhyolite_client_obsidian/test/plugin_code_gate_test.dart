import 'package:rhyolite_client_obsidian/src/settings/plugin_code_gate.dart';
import 'package:test/test.dart';

void main() {
  PluginCodeAvailability gate({
    bool selfHost = false,
    bool externalStorage = false,
    int? quota,
  }) =>
      pluginCodeAvailability(
        selfHost: selfHost,
        externalStorage: externalStorage,
        managedStorageQuotaBytes: quota,
      );

  test('self-host has no managed quota to protect', () {
    expect(gate(selfHost: true), PluginCodeAvailability.allowed);
    // Even a tiny managed quota is irrelevant once the server is the user's.
    expect(gate(selfHost: true, quota: 1), PluginCodeAvailability.allowed);
  });

  test('bring-your-own storage spends the user own capacity', () {
    expect(gate(externalStorage: true), PluginCodeAvailability.allowed);
    expect(
      gate(externalStorage: true, quota: 50 * 1024 * 1024),
      PluginCodeAvailability.allowed,
    );
  });

  test('the free managed quota cannot hold a plugin set', () {
    expect(
      gate(quota: 50 * 1024 * 1024),
      PluginCodeAvailability.quotaTooSmall,
    );
  });

  test('a paid managed quota can', () {
    expect(gate(quota: 1024 * 1024 * 1024), PluginCodeAvailability.allowed);
  });

  test('a zero quota is too small, not unlimited', () {
    // Denied capability sets are expressed as a zero quota; reading that as
    // "no limit" would be exactly backwards.
    expect(gate(quota: 0), PluginCodeAvailability.quotaTooSmall);
  });

  test('unknown capabilities fail closed', () {
    // Better a feature that appears a moment later than an upload the server
    // rejects halfway through.
    expect(gate(), PluginCodeAvailability.unknownQuota);
  });

  test('the threshold sits between the free and paid quotas', () {
    expect(kMinManagedQuotaForPluginCode, greaterThan(50 * 1024 * 1024));
    expect(kMinManagedQuotaForPluginCode, lessThan(1024 * 1024 * 1024));
  });
}
