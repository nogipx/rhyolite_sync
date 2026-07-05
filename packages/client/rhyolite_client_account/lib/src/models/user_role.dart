/// User role values stored in the `users.role` column. Defaults to
/// [user] on signup unless the email matches the `ADMIN_EMAILS` env
/// var, in which case [admin] is granted.
///
/// Modelled as a string-backed namespace rather than a sealed enum so
/// new roles can be added without a schema migration — the daemon
/// and admin interceptor only key off specific values.
abstract final class UserRole {
  /// Regular user — default for all signups. No admin endpoints.
  static const String user = 'user';

  /// Admin — may call any method on `IAdminContract`. Includes the
  /// power to grant the admin role to other users.
  static const String admin = 'admin';

  /// Returns true iff [role] is recognised as having admin powers.
  static bool isAdmin(String? role) => role == admin;
}
