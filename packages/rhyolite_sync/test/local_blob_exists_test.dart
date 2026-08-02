import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_sync/rhyolite_sync.dart';
import 'package:rpc_blob/rpc_blob.dart';
import 'package:test/test.dart';

const _v = 'vault-1';

/// Counts listBlobs pages, so a test can tell "asked about these ids" apart
/// from "walked the whole cache to answer".
class _CountingRepo extends InMemoryBlobRepository {
  int listCalls = 0;

  @override
  Future<ListBlobsResponse> listBlobs(ListBlobsRequest request) {
    listCalls++;
    return super.listBlobs(request);
  }
}

void main() {
  late _CountingRepo repo;
  late LocalBlobStore store;
  late LocalBlobStorageAdapter adapter;

  setUp(() async {
    repo = _CountingRepo();
    store = LocalBlobStore(repo);
    adapter = LocalBlobStorageAdapter(store, _v);
    for (final id in ['a', 'b', 'c']) {
      await store.write(
        Uint8List.fromList(utf8.encode(id)),
        id,
        vaultId: _v,
      );
    }
    repo.listCalls = 0;
  });

  test('reports the subset it holds, without walking the cache', () async {
    final present = await adapter.exists(['a', 'c', 'missing']);

    expect(present, unorderedEquals(['a', 'c']));
    expect(
      repo.listCalls,
      0,
      reason: 'a probe asks about its own ids; enumerating the vault for each '
          'batch made verification walk the whole cache per slice',
    );
  });

  test('the empty-file blob counts as present without being stored', () async {
    // Reconstructable from nothing, so it never reaches the cache.
    const emptySha256 =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

    expect(await adapter.exists([emptySha256, 'missing']), [emptySha256]);
  });

  test('an empty probe is a no-op', () async {
    expect(await adapter.exists([]), isEmpty);
    expect(repo.listCalls, 0);
  });
}
