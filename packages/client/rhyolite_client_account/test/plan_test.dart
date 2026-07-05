import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:test/test.dart';

void main() {
  group('PlanCapabilities', () {
    test('JSON round-trip with nulls', () {
      const caps = PlanCapabilities(
        canUseManagedStorage: false,
        canUseExternalStorage: true,
      );
      expect(
        PlanCapabilities.fromJson(caps.toJson()),
        equals(caps),
      );
    });

    test('JSON round-trip with all fields', () {
      const caps = PlanCapabilities(
        canUseManagedStorage: true,
        canUseExternalStorage: true,
        maxVaultCount: 5,
        maxFileSizeBytes: 10 * 1024 * 1024,
        managedStorageQuotaBytes: 1024 * 1024 * 1024,
      );
      expect(
        PlanCapabilities.fromJson(caps.toJson()),
        equals(caps),
      );
    });

    test('deny denies everything', () {
      expect(PlanCapabilities.deny.canUseManagedStorage, isFalse);
      expect(PlanCapabilities.deny.canUseExternalStorage, isFalse);
      expect(PlanCapabilities.deny.maxVaultCount, 0);
    });
  });

  group('PlanAcquisition', () {
    test('Paid round-trip', () {
      const a = PaidAcquisition();
      expect(PlanAcquisition.fromJson(a.toJson()), equals(a));
    });

    test('Trial round-trip', () {
      const a = TrialAcquisition();
      expect(PlanAcquisition.fromJson(a.toJson()), equals(a));
    });

    test('Promo round-trip with code', () {
      const a = PromoAcquisition(requiredCode: 'BETA-2026');
      expect(PlanAcquisition.fromJson(a.toJson()), equals(a));
    });

    test('Promo round-trip with email allow-list', () {
      const a = PromoAcquisition(
        eligibleEmails: {'a@example.com', 'b@example.com'},
      );
      final decoded = PlanAcquisition.fromJson(a.toJson());
      expect(decoded, equals(a));
    });

    test('fromJson rejects unknown kind', () {
      expect(
        () => PlanAcquisition.fromJson({'kind': 'invented'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Plan', () {
    const sample = Plan(
      planId: 'rhyolite-managed-monthly',
      name: 'Managed',
      description: '5 vaults / 10 MB / 1 GB',
      amountKopecks: 49900,
      periodDays: 30,
      caps: PlanCapabilities(
        canUseManagedStorage: true,
        canUseExternalStorage: true,
        maxVaultCount: 5,
        maxFileSizeBytes: 10 * 1024 * 1024,
        managedStorageQuotaBytes: 1024 * 1024 * 1024,
      ),
      acquisition: PaidAcquisition(),
    );

    test('round-trip preserves every field', () {
      expect(Plan.fromJson(sample.toJson()), equals(sample));
    });

    test('equality is structural', () {
      const same = Plan(
        planId: 'rhyolite-managed-monthly',
        name: 'Managed',
        description: '5 vaults / 10 MB / 1 GB',
        amountKopecks: 49900,
        periodDays: 30,
        caps: PlanCapabilities(
          canUseManagedStorage: true,
          canUseExternalStorage: true,
          maxVaultCount: 5,
          maxFileSizeBytes: 10 * 1024 * 1024,
          managedStorageQuotaBytes: 1024 * 1024 * 1024,
        ),
        acquisition: PaidAcquisition(),
      );
      expect(sample, equals(same));
    });
  });
}
