import 'package:rhyolite_client_account/rhyolite_client_account.dart';
import 'package:test/test.dart';

void main() {
  group('UserRole', () {
    test('isAdmin matches the admin literal', () {
      expect(UserRole.isAdmin('admin'), isTrue);
      expect(UserRole.isAdmin(UserRole.admin), isTrue);
    });

    test('isAdmin rejects user / null / unknown', () {
      expect(UserRole.isAdmin('user'), isFalse);
      expect(UserRole.isAdmin(null), isFalse);
      expect(UserRole.isAdmin('support'), isFalse);
      expect(UserRole.isAdmin(''), isFalse);
    });
  });

  group('AdminUserRow JSON', () {
    test('round-trip with optional fields', () {
      const row = AdminUserRow(
        userId: 'u1',
        email: 'a@example.com',
        role: 'admin',
        emailVerified: true,
        createdAtMs: 1700000000000,
        activePlanId: 'rhyolite-managed-monthly',
        activeSubEndsAtMs: 1701000000000,
      );
      expect(AdminUserRow.fromJson(row.toJson()).toJson(), row.toJson());
    });

    test('round-trip without optional fields', () {
      const row = AdminUserRow(
        userId: 'u1',
        email: 'a@example.com',
        role: 'user',
        emailVerified: false,
        createdAtMs: 1700000000000,
      );
      expect(AdminUserRow.fromJson(row.toJson()).toJson(), row.toJson());
    });
  });

  group('GrantSubscriptionRequest JSON', () {
    test('round-trip', () {
      const req = GrantSubscriptionRequest(
        userId: 'u1',
        planId: 'rhyolite-managed-monthly',
        days: 30,
        reason: 'VIP',
      );
      expect(
        GrantSubscriptionRequest.fromJson(req.toJson()).toJson(),
        req.toJson(),
      );
    });
  });
}
