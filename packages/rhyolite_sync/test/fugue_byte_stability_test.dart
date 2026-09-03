import 'package:convergent/fugue.dart';
import 'package:crypto/crypto.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_store.dart';
import 'package:rhyolite_core/rhyolite_core.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

/// The encoders must be byte-stable, because a note's blob is no longer kept
/// in the local cache.
///
/// Recovery of a note's blob — when the server loses a chunk — works by
/// re-encoding the tree out of the FugueStore and trusting that it reproduces
/// the bytes the uploader sent, since a blob id IS the hash of those bytes.
/// The moment `encodeBlob` stops being a pure, canonical function of the tree,
/// that stops being true silently: regeneration yields ids matching nothing,
/// heals nothing, and there is no cached copy to fall back on any more.
///
/// The round-trip test in state_sync_engine_test covers the same ground
/// end-to-end, but it exercises one freshly-seeded note and fails with a
/// message about healing. These fail with a message about the invariant, on a
/// tree that actually has structure: several blocks, tombstones, and two
/// replicas whose concurrent edits were merged.
const _vault = 'vault-stability';

/// Mirrors DiskReconciler._reconcileText: observe the file's own dots, then
/// apply the new snapshot under this device's clock.
Future<Fugue<String>> _apply(Fugue<String> old, String text, String device) {
  final clock = LamportClock(device)..observeAll(old.dots);
  return FugueTextSync.applyTextSnapshot(
    deadlineSeconds: FugueTextSync.unboundedDiffBudget,
    oldFugue: old,
    newText: text,
    clock: clock,
  );
}

String _doc(List<String> lines) => lines.join('\n');

/// A tree with history rather than a fresh seed: A and B edit the same base
/// concurrently and the two are joined, so the result carries interleaved
/// blocks from both replicas plus the tombstones of what each deleted.
Future<Fugue<String>> _mergedTree() async {
  final base = FugueTextSync.seedFromText(
    _doc(['L01', 'L02', 'L03', 'L04', 'L05', 'L06', 'L07', 'L08']),
  );
  final a = await _apply(
    base,
    _doc(['L01', 'L02', 'L03', 'A-вставка', 'L07', 'L08', 'A-хвост']),
    'device-a',
  );
  final b = await _apply(
    base,
    _doc(['L01', 'B-начало', 'L02', 'L03', 'L04', 'L05', 'L06', 'L07', 'L08']),
    'device-b',
  );
  return a.join(b);
}

void main() {
  group('Fugue encoding is byte-stable', () {
    test('encodeBlob is a pure function of the tree', () async {
      final tree = await _mergedTree();
      expect(
        FugueStore.encodeBlob(tree),
        FugueStore.encodeBlob(tree),
        reason:
            'two encodes of ONE tree must agree, or a blob id depends on '
            'something other than content and dedup is broken',
      );
    });

    test(
      'a tree survives the FugueStore round trip byte-identically',
      () async {
        // The exact chain regeneration depends on: the uploader encodes the
        // in-memory tree, but recovery encodes the tree AFTER it has been
        // persisted and read back. Those two encodings must be the same bytes.
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);

        final tree = await _mergedTree();
        final uploaded = FugueStore.encodeBlob(tree);

        final writer = FugueStore(client: env.client, vaultId: _vault);
        await writer.load();
        writer.set('f1', tree);
        await writer.persistOne('f1');

        final reader = FugueStore(client: env.client, vaultId: _vault);
        await reader.load();
        final reloaded = (await reader.get('f1'))!;

        expect(
          FugueStore.encodeBlob(reloaded),
          uploaded,
          reason:
              'persist+reload changed the bytes the tree encodes to. A '
              "note's blob is no longer cached locally, so this is exactly the "
              'chain that heals a chunk the server lost — if it drifts, every '
              'already-uploaded note silently becomes unrecoverable.',
        );
      },
    );

    test(
      'the legacy JSON row decodes to the same bytes as the compact one',
      () async {
        // Rows written before the compact encoding are still out there and are
        // read in place. A note whose row is still JSON must regenerate the same
        // blob as one that has been rewritten.
        final env = await DataServiceFactory.inMemory();
        addTearDown(env.dispose);

        final tree = await _mergedTree();
        await env.client.create(
          collection: '${_vault}_fugue_store',
          id: 'legacy',
          payload: FugueStore.encodeForBlob(tree) as Map<String, dynamic>,
        );

        final store = FugueStore(client: env.client, vaultId: _vault);
        await store.load();

        expect(
          FugueStore.encodeBlob((await store.get('legacy'))!),
          FugueStore.encodeBlob(tree),
          reason:
              'an un-migrated row must heal its blob just as well as a '
              'migrated one',
        );
      },
    );

    test('the wire format has not changed under us', () async {
      // A golden, on purpose. The tests above prove the encoder is stable
      // WITHIN a build; this one notices when it changes BETWEEN builds.
      //
      // If you are reading this because it failed: updating the constant is
      // not automatically the fix. A changed encoding means every blob already
      // on the server was produced by the old one, so no tree in any existing
      // vault can regenerate its own uploaded bytes any more — recovery goes
      // silently dead for all history written before the change. Decide that
      // deliberately (a format tag, a re-upload, keeping the old encoder for
      // decode) and only then move the constant.
      final tree = await _mergedTree();
      final digest = sha256.convert(FugueStore.encodeBlob(tree)).toString();
      expect(
        digest,
        '8c292ab8a754cef83f2e4362022fe1884a7553677a6a517efc9a877ab69acf4c',
        reason:
            'the Fugue wire encoding changed — read the comment above '
            'before touching this constant',
      );
    });
  });
}
