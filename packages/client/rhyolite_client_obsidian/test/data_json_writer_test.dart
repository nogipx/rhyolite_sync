import 'package:rhyolite_client_obsidian/src/engine/data_json_writer.dart';
import 'package:test/test.dart';

/// In-memory RawDataStore with a forced async gap on load/save so
/// interleaving is observable — an unserialized read-modify-write would
/// lose an update against this.
class _FakeRawStore implements RawDataStore {
  _FakeRawStore([Map<String, dynamic>? initial])
      : data = {...?initial};

  Map<String, dynamic> data;
  int saves = 0;

  @override
  Future<Object?> load() async {
    await Future<void>.delayed(Duration.zero);
    return {...data}; // a copy — callers mutate their own view
  }

  @override
  Future<void> save(Map<String, dynamic> d) async {
    await Future<void>.delayed(Duration.zero);
    data = {...d};
    saves++;
  }
}

void main() {
  group('DataJsonWriter', () {
    test('concurrent updates to different keys do not clobber each other',
        () async {
      final store = _FakeRawStore({'existing': 1});
      final w = DataJsonWriter(store);

      // Fire both without awaiting between — they must serialize so the
      // second re-reads AFTER the first has persisted.
      final f1 = w.update((m) => m['a'] = 'A');
      final f2 = w.update((m) => m['b'] = 'B');
      await Future.wait([f1, f2]);

      expect(store.data['a'], 'A');
      expect(store.data['b'], 'B',
          reason: 'the second update must not clobber the first');
      expect(store.data['existing'], 1,
          reason: 'untouched keys are preserved');
      expect(store.saves, 2);
    });

    test('a failing update does not poison later updates', () async {
      final store = _FakeRawStore();
      final w = DataJsonWriter(store);

      final bad = w.update((_) => throw StateError('boom'));
      final good = w.update((m) => m['ok'] = true);

      await expectLater(bad, throwsA(isA<StateError>()));
      await good;
      expect(store.data['ok'], isTrue);
    });

    test('read deep-converts nested maps to Dart maps', () async {
      final store = _FakeRawStore({
        'settingsSync': {
          'nested': {'x': 1},
        },
      });
      final w = DataJsonWriter(store);

      final m = await w.read();
      expect(m['settingsSync'], isA<Map<String, dynamic>>());
      final nested = (m['settingsSync'] as Map)['nested'];
      expect(nested, isA<Map<String, dynamic>>());
      expect((nested as Map)['x'], 1);
    });

    test('an update preserves an untouched sibling nested key', () async {
      final store = _FakeRawStore({
        'vaultConfig': {
          'vaultId': 'v1',
          'externalBlobConfig': {'kind': 's3'},
        },
      });
      final w = DataJsonWriter(store);

      await w.update((m) => m['syncPaused'] = true);

      expect(store.data['syncPaused'], isTrue);
      final vc = store.data['vaultConfig'] as Map;
      expect(vc['vaultId'], 'v1');
      expect((vc['externalBlobConfig'] as Map)['kind'], 's3',
          reason: 'sibling nested config must round-trip intact');
    });
  });
}
