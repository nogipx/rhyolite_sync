import 'package:rhyolite_client_obsidian/src/settings/obsidian_settings_registry.dart';
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

  group('applying the gate to a category selection', () {
    const optedIn = <SettingsCategory>{
      SettingsCategory.appSettings,
      SettingsCategory.themesSnippets,
      SettingsCategory.communityPluginCode,
    };

    Set<SettingsCategory> pullOnly(
      PluginCodeAvailability availability, {
      Set<SettingsCategory> enabled = optedIn,
    }) =>
        pluginCodePullOnly(enabled: enabled, availability: availability);

    test('a verdict never removes a category the user chose', () {
      // The regression this whole split exists for. The selection is the sync
      // scope: if the gate could edit it, a getSubscription that timed out
      // would purge every plugin record and reset the pull cursor, and the next
      // successful lookup would pay for it with a full re-download.
      for (final availability in PluginCodeAvailability.values) {
        expect(
          pullOnly(availability).difference(optedIn),
          isEmpty,
          reason: '$availability must only ever mark categories read-only',
        );
      }
    });

    test('allowed means upload as usual', () {
      expect(pullOnly(PluginCodeAvailability.allowed), isEmpty);
    });

    test('a quota too small pauses uploads, not the category', () {
      expect(
        pullOnly(PluginCodeAvailability.quotaTooSmall),
        {SettingsCategory.communityPluginCode},
      );
    });

    test('an unknown quota pauses uploads too, and only uploads', () {
      // Fail closed on spending storage, fail OPEN on receiving it: what the
      // vault already holds costs the quota nothing to download.
      expect(
        pullOnly(PluginCodeAvailability.unknownQuota),
        {SettingsCategory.communityPluginCode},
      );
    });

    test('nothing to pause when the user never opted in', () {
      const off = <SettingsCategory>{SettingsCategory.appSettings};
      for (final availability in PluginCodeAvailability.values) {
        expect(pullOnly(availability, enabled: off), isEmpty);
      }
    });

    test('other categories are never gated on plugin-code storage', () {
      for (final availability in PluginCodeAvailability.values) {
        expect(
          pullOnly(availability),
          isNot(contains(SettingsCategory.themesSnippets)),
        );
      }
    });
  });
}
