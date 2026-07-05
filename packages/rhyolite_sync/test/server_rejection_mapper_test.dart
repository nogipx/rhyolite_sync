import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:test/test.dart';

class _Custom extends SyncServerRejected {
  _Custom(String code, String message, Map<String, dynamic> params)
      : super(code: code, message: message, params: params);
}

void main() {
  const mapper = ServerRejectionMapper();

  test('maps known auth/policy error strings to standard codes', () {
    expect(mapper.fromException(Exception('UNAUTHENTICATED'))?.code,
        'auth.session_expired');
    expect(mapper.fromException(Exception('PAYMENT_REQUIRED'))?.code,
        'app_policy.subscription_required');
    expect(mapper.fromException(Exception('PERMISSION_DENIED'))?.code,
        'auth.permission_denied');
  });

  test('parses structured app_policy params', () {
    final r = mapper
        .fromException(Exception('app_policy.storage_quota:used=5,limit=3'));
    expect(r?.code, 'app_policy.storage_quota');
    expect(r?.params, {'used': '5', 'limit': '3'});
  });

  test('returns null for errors that are not policy/auth rejections', () {
    expect(mapper.fromException(Exception('some transient network blip')),
        isNull);
  });

  test('isFatal is true for auth/app_policy, false otherwise', () {
    expect(mapper.isFatal(Exception('UNAUTHENTICATED')), isTrue);
    expect(mapper.isFatal(Exception('app_policy.storage_quota:used=5')), isTrue);
    expect(mapper.isFatal(Exception('transient network error')), isFalse);
  });

  test('factory upgrades the envelope into a typed subclass', () {
    final m = ServerRejectionMapper(
      factory: (code, message, params) =>
          code == 'auth.session_expired' ? _Custom(code, message, params) : null,
    );
    expect(m.fromException(Exception('UNAUTHENTICATED')), isA<_Custom>());
  });
}
