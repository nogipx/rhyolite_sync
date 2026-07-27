import 'dart:convert';
import 'dart:typed_data';

import 'package:rhyolite_client_obsidian/src/settings/enabled_list_gating.dart';
import 'package:test/test.dart';

Uint8List jb(Object? v) => Uint8List.fromList(utf8.encode(jsonEncode(v)));
List<String> ids(Uint8List b) =>
    (jsonDecode(utf8.decode(b)) as List).cast<String>();

void main() {
  group('partitionEnabledList', () {
    ({List<String> keep, Set<String> withheld}) split(
      List<String> input, {
      Set<String> vaultCode = const {},
      Set<String> installed = const {},
    }) =>
        partitionEnabledList(
          input,
          vaultHasCode: vaultCode.contains,
          installedHere: installed.contains,
        );

    test('holds back a plugin whose code is coming but has not landed', () {
      final r = split(['dataview'], vaultCode: {'dataview'});
      expect(r.keep, isEmpty);
      expect(r.withheld, {'dataview'});
    });

    test('writes a plugin whose code already landed here', () {
      final r = split(
        ['dataview'],
        vaultCode: {'dataview'},
        installed: {'dataview'},
      );
      expect(r.keep, ['dataview']);
      expect(r.withheld, isEmpty);
    });

    test('leaves alone plugins the vault has no code for', () {
      // The user installs these themselves — withholding would break what
      // works today, with or without plugin-code sync.
      final r = split(['templater', 'dataview'], vaultCode: {'dataview'});
      expect(r.keep, ['templater']);
      expect(r.withheld, {'dataview'});
    });

    test('output is sorted and drops empty ids', () {
      final r = split(['zzz', '', 'aaa']);
      expect(r.keep, ['aaa', 'zzz']);
    });
  });

  group('restoreWithheld', () {
    test('re-adds withheld ids before the file is diffed', () {
      // The scenario this exists for: the user toggles some OTHER plugin while
      // dataview's code is still downloading. Obsidian rewrites the list from
      // what it sees on disk — which is our shortened copy.
      final disk = jb(['templater']);
      final restored = restoreWithheld(disk, {'dataview'});
      expect(ids(restored), ['dataview', 'templater']);
    });

    test('a genuine local disable still wins for other plugins', () {
      final disk = jb(<String>[]); // user disabled templater
      final restored = restoreWithheld(disk, {'dataview'});
      expect(ids(restored), ['dataview']);
    });

    test('nothing withheld is a pass-through', () {
      final disk = jb(['a']);
      expect(restoreWithheld(disk, const {}), same(disk));
    });

    test('non-array content is left untouched', () {
      final junk = Uint8List.fromList(utf8.encode('not json'));
      expect(restoreWithheld(junk, {'dataview'}), same(junk));
    });

    test('does not duplicate an id already present', () {
      final restored = restoreWithheld(jb(['dataview']), {'dataview'});
      expect(ids(restored), ['dataview']);
    });
  });

  group('parseEnabledList', () {
    test('reads a plain array', () {
      expect(parseEnabledList(jb(['a', 'b'])), ['a', 'b']);
    });

    test('rejects non-arrays and junk', () {
      expect(parseEnabledList(jb({'a': 1})), isNull);
      expect(
        parseEnabledList(Uint8List.fromList(utf8.encode('{'))),
        isNull,
      );
    });
  });

  group('platform cannot speak for what it cannot run', () {
    test('a desktop-only plugin survives a diff taken on mobile', () {
      // Obsidian drops desktop-only plugins from the enabled list on mobile.
      // Diffing that in would disable them for every desktop in the vault.
      final diskOnPhone = jb(['templater']);
      final restored = restoreWithheld(diskOnPhone, {'realclaudian'});
      expect(ids(restored), ['realclaudian', 'templater']);
    });

    test('a genuine disable of a runnable plugin still propagates', () {
      // The guard is scoped to what the platform cannot run; everything else
      // remains the user's call.
      final diskOnPhone = jb(<String>[]);
      final restored = restoreWithheld(diskOnPhone, {'realclaudian'});
      expect(ids(restored), ['realclaudian'],
          reason: 'templater was disabled by the user and stays disabled');
    });
  });
}
