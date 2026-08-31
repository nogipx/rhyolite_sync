import 'package:obsidian_dart/obsidian_dart.dart';

import '../settings/obsidian_settings_registry.dart';
import 'log_file_store.dart';

/// [LogFileStore] over Obsidian's vault adapter.
///
/// Lives under the plugin's own folder in the config directory. That location
/// is not an accident: the settings-sync registry excludes
/// `plugins/rhyolite-sync` from itself, so logs stay on the device that wrote
/// them and never ride the sync they exist to describe. Putting them anywhere
/// in the vault proper would upload them, and they would then reach the very
/// server the user has been promised sees no readable content.
///
/// `vault.configDir` rather than a hardcoded `.obsidian` because Obsidian lets
/// the config directory be renamed, and a report from such a vault would
/// otherwise silently carry no logs at all.
class ObsidianLogFileStore implements LogFileStore {
  ObsidianLogFileStore(
    this._vault, {
    this.keepSegments = 5,
    this.maxTotalBytes = 24 * 1024 * 1024,
    this.maxProblemsBytes = 1024 * 1024,
    this.keepTailSlots = 2,
  });

  final VaultHandle _vault;

  /// Segments kept on disk. A segment is a session or a day, whichever ends
  /// first, so this is a window a person can reason about either way.
  final int keepSegments;

  /// Ceiling across all segments, enforced oldest-first. This, not
  /// [keepSegments], is what actually bounds disk use — segment sizes vary by
  /// orders of magnitude between a quiet day and a first sync.
  final int maxTotalBytes;

  /// Ceiling for the problems file before it rotates once. Warnings are rare,
  /// so this reaches back much further than the segment logs.
  final int maxProblemsBytes;

  /// Tail slots retained per segment. Two means recent output on disk is
  /// always between one and two slots, never zero right after a roll.
  final int keepTailSlots;

  AdapterHandle get _adapter => _vault.adapter;

  String get _dir =>
      '${_vault.configDir}/plugins/${ObsidianSettingsRegistry.selfPluginId}/logs';

  String _head(String sid) => '$_dir/$sid.head.log';
  String _tail(String sid, int slot) => '$_dir/$sid.tail$slot.log';
  String get _problems => '$_dir/problems.log';
  String get _problemsPrev => '$_dir/problems.1.log';

  String? _segmentId;
  int _tailSlot = 0;
  int _tailBytes = 0;
  bool _dirReady = false;

  Future<void> _ensureDir() async {
    if (_dirReady) return;
    if (!await _adapter.exists(_dir)) {
      await _adapter.mkdir(_dir);
    }
    _dirReady = true;
  }

  @override
  Future<List<String>> beginSegment(String segmentId) async {
    await _ensureDir();
    _segmentId = segmentId;
    _tailSlot = 0;
    _tailBytes = 0;
    return _prune(keeping: segmentId);
  }

  @override
  Future<void> appendHead(String text) async {
    final sid = _segmentId;
    if (sid == null || text.isEmpty) return;
    await _ensureDir();
    await _adapter.append(_head(sid), text);
  }

  @override
  Future<bool> appendTail(String text, {required int tailSlotBytes}) async {
    final sid = _segmentId;
    if (sid == null || text.isEmpty) return false;
    await _ensureDir();

    var discarded = false;
    if (_tailBytes > 0 && _tailBytes + text.length > tailSlotBytes) {
      _tailSlot++;
      _tailBytes = 0;
      // Keeping N slots means dropping the one N back. Numbered, so the read
      // order is the slot order and nothing has to remember which was newer.
      final stale = _tail(sid, _tailSlot - keepTailSlots);
      if (await _adapter.exists(stale)) {
        await _adapter.remove(stale);
        discarded = true;
      }
    }
    await _adapter.append(_tail(sid, _tailSlot), text);
    _tailBytes += text.length;
    return discarded;
  }

  @override
  Future<void> appendProblems(String text) async {
    if (text.isEmpty) return;
    await _ensureDir();
    final size = await _sizeOf(_problems);
    if (size + text.length > maxProblemsBytes) {
      if (await _adapter.exists(_problemsPrev)) {
        await _adapter.remove(_problemsPrev);
      }
      if (await _adapter.exists(_problems)) {
        await _adapter.rename(_problems, _problemsPrev);
      }
    }
    await _adapter.append(_problems, text);
  }

  @override
  Future<String> readRecent(int segments) async {
    if (!await _adapter.exists(_dir)) return '';
    final byId = await _filesBySegment();
    final ids = byId.keys.toList()..sort();
    final take = ids.length <= segments ? ids : ids.sublist(ids.length - segments);

    final paths = <String>[];
    for (final id in take) {
      final files = byId[id]!..sort(_readOrder);
      paths.addAll(files);
    }
    return _concat(paths);
  }

  @override
  Future<String> readProblems() => _concat([_problemsPrev, _problems]);

  @override
  Future<int> totalBytes() async {
    if (!await _adapter.exists(_dir)) return 0;
    final listed = await _adapter.list(_dir);
    var total = 0;
    for (final f in listed.files) {
      total += await _sizeOf(f);
    }
    return total;
  }

  @override
  Future<List<(String, String)>> readAllFiles() async {
    if (!await _adapter.exists(_dir)) return const [];
    final listed = await _adapter.list(_dir);
    final paths = listed.files.toList()..sort(_archiveOrder);
    final out = <(String, String)>[];
    for (final path in paths) {
      try {
        out.add((path.split('/').last, await _adapter.read(path)));
      } catch (_) {
        // One unreadable file must not cost the report every other one.
      }
    }
    return out;
  }

  /// Segments in chronological order, head before its tails, problems last —
  /// the order someone reads them in.
  static int _archiveOrder(String a, String b) {
    final pa = a.contains('problems') ? 1 : 0;
    final pb = b.contains('problems') ? 1 : 0;
    if (pa != pb) return pa - pb;
    final sa = _segmentOf(a.split('/').last) ?? '';
    final sb = _segmentOf(b.split('/').last) ?? '';
    final bySegment = sa.compareTo(sb);
    return bySegment != 0 ? bySegment : _slotOf(a).compareTo(_slotOf(b));
  }

  @override
  Future<void> deleteAll() async {
    if (!await _adapter.exists(_dir)) return;
    final listed = await _adapter.list(_dir);
    for (final f in listed.files) {
      try {
        await _adapter.remove(f);
      } catch (_) {
        // A file we cannot delete must not abort the rest of the cleanup.
      }
    }
    _tailBytes = 0;
    _tailSlot = 0;
  }

  /// Head before tails, then tails by slot number. Lexicographic sorting would
  /// put `tail10` before `tail2`.
  static int _readOrder(String a, String b) {
    final sa = _slotOf(a);
    final sb = _slotOf(b);
    return sa.compareTo(sb);
  }

  /// -1 for a head, so it sorts before every tail.
  static int _slotOf(String path) {
    final name = path.split('/').last;
    if (name.endsWith('.head.log')) return -1;
    final m = RegExp(r'\.tail(\d+)\.log$').firstMatch(name);
    return m == null ? -1 : int.parse(m.group(1)!);
  }

  Future<Map<String, List<String>>> _filesBySegment() async {
    final listed = await _adapter.list(_dir);
    final owned = <String, List<String>>{};
    for (final path in listed.files) {
      final sid = _segmentOf(path.split('/').last);
      if (sid == null) continue;
      (owned[sid] ??= []).add(path);
    }
    return owned;
  }

  Future<String> _concat(List<String> paths) async {
    final parts = <String>[];
    for (final path in paths) {
      if (!await _adapter.exists(path)) continue;
      final text = await _adapter.read(path);
      if (text.isNotEmpty) parts.add(text);
    }
    return parts.join('\n');
  }

  Future<int> _sizeOf(String path) async {
    if (!await _adapter.exists(path)) return 0;
    final stat = await _adapter.stat(path);
    return stat?.size ?? 0;
  }

  /// Enforces both limits, newest kept. Returns the surviving segment ids,
  /// oldest first.
  ///
  /// Segment ids sort chronologically by construction, so ordering needs no
  /// stat call — which matters because this runs during boot.
  Future<List<String>> _prune({required String keeping}) async {
    final owned = await _filesBySegment();
    owned.putIfAbsent(keeping, () => []);

    final sizes = <String, int>{};
    for (final entry in owned.entries) {
      var total = 0;
      for (final path in entry.value) {
        total += await _sizeOf(path);
      }
      sizes[entry.key] = total;
    }

    final ids = owned.keys.toList()..sort();
    final survivors = <String>[];
    var total = 0;

    // Newest-first, so the budget is spent on the most recent segments.
    for (final sid in ids.reversed) {
      final size = sizes[sid] ?? 0;
      final withinCount = survivors.length < keepSegments;
      final withinBytes = total + size <= maxTotalBytes;
      // The segment being started is never evicted, whatever the budget says.
      if (sid == keeping || (withinCount && withinBytes)) {
        survivors.add(sid);
        total += size;
        continue;
      }
      for (final path in owned[sid]!) {
        try {
          await _adapter.remove(path);
        } catch (_) {
          // Best effort — a stuck file costs disk, not correctness.
        }
      }
    }
    return survivors.reversed.toList();
  }

  /// `20260830-195622-731.head.log` -> `20260830-195622-731`. Null for
  /// anything this store does not own, including `problems.log`.
  static String? _segmentOf(String fileName) {
    final match = RegExp(r'^(\d{8}-\d{6}-\d+)\.(?:head|tail\d+)\.log$')
        .firstMatch(fileName);
    return match?.group(1);
  }
}
