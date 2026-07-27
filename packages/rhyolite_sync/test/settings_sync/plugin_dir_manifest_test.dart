import 'dart:convert';
import 'dart:typed_data';

import 'package:convergent/convergent.dart';
import 'package:rhyolite_sync/src/settings_sync/plugin_dir_manifest.dart';
import 'package:rhyolite_sync/src/settings_sync/resource_crdt_codec.dart';
import 'package:test/test.dart';

Hlc Function() clock(String node, {int start = 1}) {
  var ms = start;
  return () => Hlc(ms++, 0, node);
}

PluginDirManifest manifest({
  String id = 'dataview',
  String? version = '1.0.0',
  Map<String, String> refs = const {'main.js': 'blob-main-1'},
  int updatedAtMs = 100,
  String? updatedBy = 'MacBook',
  bool desktopOnly = false,
  List<PluginVersionEntry> history = const [],
}) =>
    PluginDirManifest(
      pluginId: id,
      version: version,
      desktopOnly: desktopOnly,
      updatedAtMs: updatedAtMs,
      updatedBy: updatedBy,
      history: history,
      files: {
        for (final e in refs.entries)
          e.key: PluginFileRef(
            blobRef: e.value,
            chunks: ['${e.value}-c0', '${e.value}-c1'],
            size: 1024,
          ),
      },
    );

void main() {
  group('PluginDirManifest', () {
    test('round-trips through JSON', () {
      final m = manifest(
        refs: {'main.js': 'b1', 'manifest.json': 'b2', 'styles.css': 'b3'},
        desktopOnly: true,
        history: const [PluginVersionEntry(version: '0.9.0', atMs: 1, device: 'PC')],
      );
      final back = PluginDirManifest.tryParse(m.toBytes())!;
      expect(back.pluginId, m.pluginId);
      expect(back.version, m.version);
      expect(back.desktopOnly, isTrue);
      expect(back.updatedAtMs, m.updatedAtMs);
      expect(back.updatedBy, m.updatedBy);
      expect(back.files.keys.toList()..sort(), ['main.js', 'manifest.json', 'styles.css']);
      expect(back.files['main.js']!.chunks, ['b1-c0', 'b1-c1']);
      expect(back.history.single.version, '0.9.0');
      expect(back.contentHash, m.contentHash);
    });

    test('drops file names outside the fixed three-file set', () {
      final json = jsonDecode(utf8.decode(manifest().toBytes())) as Map;
      (json['f'] as Map)['data.json'] = {'b': 'nope', 's': 1};
      (json['f'] as Map)['cache.db'] = {'b': 'nope2', 's': 1};
      final back = PluginDirManifest.tryFromJson(json)!;
      expect(back.files.keys, ['main.js']);
    });

    test('contentHash ignores metadata, tracks blob refs', () {
      final a = manifest(updatedAtMs: 1, updatedBy: 'A', version: '1.0.0');
      final b = manifest(updatedAtMs: 999, updatedBy: 'B', version: '2.0.0');
      expect(a.contentHash, b.contentHash);

      final c = manifest(refs: {'main.js': 'blob-main-2'});
      expect(c.contentHash, isNot(a.contentHash));
    });

    test('contentHash is bound to the plugin id', () {
      expect(manifest(id: 'a').contentHash, isNot(manifest(id: 'b').contentHash));
    });

    test('liveBlobIds covers every manifest hash and chunk', () {
      final m = manifest(refs: {'main.js': 'b1', 'styles.css': 'b2'});
      expect(
        m.liveBlobIds..sort(),
        ['b1', 'b1-c0', 'b1-c1', 'b2', 'b2-c0', 'b2-c1'],
      );
    });

    test('withHistoryFrom carries the trail and appends the old version', () {
      final prev = manifest(version: '1.0.0', updatedAtMs: 10, updatedBy: 'PC');
      final next = manifest(version: '1.1.0', refs: {'main.js': 'blob-main-2'})
          .withHistoryFrom(prev);
      expect(next.history.single.version, '1.0.0');
      expect(next.history.single.atMs, 10);
      expect(next.history.single.device, 'PC');
    });

    test('withHistoryFrom does not record an unchanged version', () {
      final prev = manifest(version: '1.0.0');
      final next = manifest(version: '1.0.0', refs: {'main.js': 'b2'})
          .withHistoryFrom(prev);
      expect(next.history, isEmpty);
    });

    test('history trail is bounded', () {
      var current = manifest(version: 'v0');
      for (var i = 1; i <= PluginDirManifest.maxHistoryEntries + 5; i++) {
        current = manifest(version: 'v$i', refs: {'main.js': 'b$i'})
            .withHistoryFrom(current);
      }
      expect(current.history.length, PluginDirManifest.maxHistoryEntries);
      // Oldest entries fall off the front; the newest predecessor stays.
      expect(current.history.last.version, 'v${PluginDirManifest.maxHistoryEntries + 4}');
    });

    test('rejects payloads with no usable file', () {
      expect(PluginDirManifest.tryFromJson({'id': 'x', 'f': <String, Object?>{}}), isNull);
      expect(PluginDirManifest.tryFromJson({'f': {'main.js': {'b': 'x'}}}), isNull);
      expect(PluginDirManifest.tryParse(Uint8List(0)), isNull);
      expect(PluginDirManifest.tryParse(Uint8List.fromList(utf8.encode('nope'))), isNull);
    });
  });

  group('BlobDirCodec', () {
    const c = BlobDirCodec();

    test('captures a manifest and renders it back', () {
      final m = manifest();
      final s = c.diffApply(c.emptyState(), m.toBytes(), clock('A'));
      final back = PluginDirManifest.tryParse(c.renderState(s))!;
      expect(back.contentHash, m.contentHash);
      expect(back.version, '1.0.0');
    });

    test('same contentHash is suppressed even when metadata differs', () {
      final s1 = c.diffApply(c.emptyState(), manifest(updatedAtMs: 1).toBytes(), clock('A'));
      final s2 = c.diffApply(
        s1,
        manifest(updatedAtMs: 5000, updatedBy: 'Phone', version: '2.0.0').toBytes(),
        clock('A', start: 500),
      );
      expect(identical(s1, s2), isTrue);
    });

    test('changed blob refs produce a new value', () {
      final s1 = c.diffApply(c.emptyState(), manifest().toBytes(), clock('A'));
      final s2 = c.diffApply(
        s1,
        manifest(version: '2.0.0', refs: {'main.js': 'blob-main-2'}).toBytes(),
        clock('A', start: 500),
      );
      expect(PluginDirManifest.tryParse(c.renderState(s2))!.version, '2.0.0');
    });

    test('unparseable bytes leave the state untouched', () {
      final s1 = c.diffApply(c.emptyState(), manifest().toBytes(), clock('A'));
      final s2 = c.diffApply(s1, Uint8List.fromList(utf8.encode('{}')), clock('B'));
      expect(identical(s1, s2), isTrue);
    });

    test('join is last-write-wins on the whole directory', () {
      final a = c.diffApply(
        c.emptyState(),
        manifest(version: '1.0.0', refs: {'main.js': 'b1', 'styles.css': 's1'}).toBytes(),
        clock('A', start: 1),
      );
      final b = c.diffApply(
        c.emptyState(),
        manifest(version: '2.0.0', refs: {'main.js': 'b2', 'styles.css': 's2'}).toBytes(),
        clock('B', start: 100),
      );

      final ab = PluginDirManifest.tryParse(c.renderState(c.joinStates(a, b)))!;
      final ba = PluginDirManifest.tryParse(c.renderState(c.joinStates(b, a)))!;

      // Commutative, and the winner is taken whole — never a mix of the two.
      expect(ab.contentHash, ba.contentHash);
      expect(ab.version, '2.0.0');
      expect(ab.files['main.js']!.blobRef, 'b2');
      expect(ab.files['styles.css']!.blobRef, 's2');
    });

    test('join is idempotent', () {
      final a = c.diffApply(c.emptyState(), manifest().toBytes(), clock('A'));
      expect(c.renderState(c.joinStates(a, a)), c.renderState(a));
    });

    test('liveBlobIds reads through the register', () {
      final s = c.diffApply(
        c.emptyState(),
        manifest(refs: {'main.js': 'b1'}).toBytes(),
        clock('A'),
      );
      expect(c.liveBlobIds(s)..sort(), ['b1', 'b1-c0', 'b1-c1']);
      expect(c.liveBlobIds(c.emptyState()), isEmpty);
    });

    test('state survives encode/decode round-trip', () {
      final s = c.diffApply(c.emptyState(), manifest().toBytes(), clock('A'));
      final back = c.decodeState(c.encodeState(s));
      expect(c.renderState(back), c.renderState(s));
    });
  });

  group('removal', () {
    test('round-trips and carries no files', () {
      final m = PluginDirManifest.removed(
        pluginId: 'dataview',
        version: '1.0.0',
        updatedAtMs: 42,
        updatedBy: 'MacBook',
      );
      final back = PluginDirManifest.tryParse(m.toBytes())!;
      expect(back.deleted, isTrue);
      expect(back.files, isEmpty);
      expect(back.liveBlobIds, isEmpty,
          reason: 'the previous version stops being referenced');
      expect(back.totalSize, 0);
      expect(back.version, '1.0.0');
      expect(back.updatedBy, 'MacBook');
    });

    test('a live manifest with no files is still rejected', () {
      expect(
        PluginDirManifest.tryFromJson({'id': 'x', 'f': <String, Object?>{}}),
        isNull,
        reason: 'malformed, must not replace a working install',
      );
    });

    test('never hashes equal to a live version', () {
      final live = manifest(refs: {'main.js': 'b1'});
      final gone = PluginDirManifest.removed(pluginId: live.pluginId);
      expect(gone.contentHash, isNot(live.contentHash));
    });

    test('carries the version trail forward', () {
      final prev = manifest(version: '2.0.0', updatedAtMs: 7, updatedBy: 'PC');
      final gone =
          PluginDirManifest.removed(pluginId: prev.pluginId).withHistoryFrom(prev);
      expect(gone.deleted, isTrue);
      expect(gone.history.single.version, '2.0.0');
    });

    test('codec: a removal replaces a live version', () {
      const c = BlobDirCodec();
      final live =
          c.diffApply(c.emptyState(), manifest().toBytes(), clock('A'));
      final gone = c.diffApply(
        live,
        PluginDirManifest.removed(pluginId: 'dataview').toBytes(),
        clock('A', start: 500),
      );
      final applied = PluginDirManifest.tryParse(c.renderState(gone))!;
      expect(applied.deleted, isTrue);
      expect(c.liveBlobIds(gone), isEmpty);
    });

    test('codec: a reinstall after a removal wins by HLC', () {
      const c = BlobDirCodec();
      final gone = c.diffApply(
        c.emptyState(),
        PluginDirManifest.removed(pluginId: 'dataview').toBytes(),
        clock('A', start: 1),
      );
      final back = c.diffApply(
        gone,
        manifest(version: '3.0.0', refs: {'main.js': 'b9'}).toBytes(),
        clock('A', start: 500),
      );
      final applied = PluginDirManifest.tryParse(c.renderState(back))!;
      expect(applied.deleted, isFalse);
      expect(applied.version, '3.0.0');
    });

    test('codec: re-issuing the same removal is suppressed', () {
      const c = BlobDirCodec();
      final gone = c.diffApply(
        c.emptyState(),
        PluginDirManifest.removed(pluginId: 'dataview').toBytes(),
        clock('A'),
      );
      final again = c.diffApply(
        gone,
        PluginDirManifest.removed(pluginId: 'dataview', updatedAtMs: 999)
            .toBytes(),
        clock('A', start: 500),
      );
      expect(identical(gone, again), isTrue);
    });
  });

  group('untrusted id (the manifest is authored by a peer)', () {
    Object? raw(String id) => {
          'v': 1,
          'id': id,
          'f': {
            'main.js': {'b': 'blob', 's': 1},
          },
        };

    test('rejects ids that would escape their directory', () {
      // The id used to reach the filesystem verbatim, so `../plugins/
      // rhyolite-sync` let a peer holding the vault key overwrite the running
      // engine's own main.js.
      for (final id in [
        '../plugins/rhyolite-sync',
        '..',
        '.',
        'a/b',
        r'a\b',
        '/etc/passwd',
        '.hidden',
      ]) {
        expect(PluginDirManifest.tryFromJson(raw(id)), isNull, reason: id);
      }
    });

    test('rejects an empty or non-string id', () {
      expect(PluginDirManifest.tryFromJson(raw('')), isNull);
      expect(
        PluginDirManifest.tryFromJson({'id': 42, 'f': {'main.js': {'b': 'x'}}}),
        isNull,
      );
    });

    test('accepts the shapes real plugins and themes use', () {
      for (final id in [
        'dataview',
        'obsidian-excalidraw-plugin',
        'templater-obsidian',
        'Minimal',
        'Things2_theme',
        'plugin.with.dots',
      ]) {
        expect(PluginDirManifest.tryFromJson(raw(id)), isNotNull, reason: id);
      }
    });
  });
}
