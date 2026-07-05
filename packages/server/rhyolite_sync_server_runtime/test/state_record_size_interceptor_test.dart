import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rhyolite_sync_server_runtime/rhyolite_sync_server_runtime.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('StateRecordSizeInterceptor', () {
    late RpcResponderEndpoint endpoint;

    setUp(() {
      final (_, server) = RpcInMemoryTransport.pair();
      endpoint = RpcResponderEndpoint(transport: server);
    });
    tearDown(() => endpoint.close());

    const interceptor =
        StateRecordSizeInterceptor(notesMaxBytes: 5000, configMaxBytes: 1000);
    final configService = StateSyncContractNames.instance('config');
    final notesService = StateSyncContractNames.service;

    RpcMiddlewareContext call(String service) => RpcMiddlewareContext(
          endpoint: endpoint,
          serviceName: service,
          methodName: StateSyncContractNames.putStates,
          context: RpcContext.empty(),
        );

    StatePutRequest req(int stateLen) => StatePutRequest(
          vaultId: 'v',
          items: [
            StatePutItem(
              fileId: 'appearance.json',
              encryptedState: 'a' * stateLen,
              blobRef: '',
              hlcPacked: 'h',
              tombstone: false,
              contextPacked: '',
            ),
          ],
        );

    Future<StatePutResponse> run(RpcMiddlewareContext c, StatePutRequest r) =>
        interceptor.interceptUnary<StatePutRequest, StatePutResponse>(
          c,
          r,
          (ctx, request) async =>
              const StatePutResponse(results: [], cursor: 0, epoch: 0),
        );

    test('config: a record over the limit is rejected', () {
      expect(
        () => run(call(configService), req(1001)),
        throwsA(
          isA<RpcException>().having(
            (e) => e.message,
            'message',
            contains('app_policy.quota.state_size'),
          ),
        ),
      );
    });

    test('config: a record at the limit passes', () async {
      final resp = await run(call(configService), req(1000));
      expect(resp.cursor, 0);
    });

    test('notes: a record over the (higher) notes limit is rejected', () {
      expect(
        () => run(call(notesService), req(5001)),
        throwsA(
          isA<RpcException>().having(
            (e) => e.message,
            'message',
            contains('app_policy.quota.state_size'),
          ),
        ),
      );
    });

    test('notes: a record at the notes limit passes', () async {
      final resp = await run(call(notesService), req(5000));
      expect(resp.cursor, 0);
    });

    test('notes limit is higher than config: 2000 passes notes, fails config',
        () async {
      final notesResp = await run(call(notesService), req(2000));
      expect(notesResp.cursor, 0);
      expect(() => run(call(configService), req(2000)), throwsA(isA<RpcException>()));
    });

    test('an unrelated service is not enforced', () async {
      final resp = await run(call('SomeOtherService'), req(100000));
      expect(resp.cursor, 0);
    });

    test('config: rejects if ANY item in the batch is over the limit', () {
      final batch = StatePutRequest(
        vaultId: 'v',
        items: [
          StatePutItem(
            fileId: 'app.json',
            encryptedState: 'a' * 10,
            blobRef: '',
            hlcPacked: 'h',
            tombstone: false,
            contextPacked: '',
          ),
          StatePutItem(
            fileId: 'big.json',
            encryptedState: 'a' * 5000,
            blobRef: '',
            hlcPacked: 'h',
            tombstone: false,
            contextPacked: '',
          ),
        ],
      );
      expect(
        () => run(call(configService), batch),
        throwsA(isA<RpcException>()),
      );
    });
  });
}
