/// Pack/unpack for the per-device Fugue GC frontier.
///
/// The frontier a device reports for causal-stability GC is a **version
/// vector over Fugue dots**: `Map<replica, maxCounter>`. It replaces the
/// old HLC [CausalContext] frontier — Fugue elements are identified by a
/// logical [Dot] `(counter, replica)`, not an [Hlc], so the boundary the
/// GC compares against must be counters-per-replica, not HLC-per-author.
///
/// **Format-tagged and fail-safe.** The server relays `frontierPacked`
/// blindly (`history_responder`), so during a mixed-version rollout a
/// device can receive a peer's frontier in the *old* (HLC) format. Every
/// packed string carries a leading format id (`fgvv1:`); [unpack] returns
/// `null` for anything it doesn't recognise. The GC treats an unparseable
/// frontier as "that device hasn't reported" → its author boundary
/// collapses to zero → nothing is pruned. Under-pruning only costs
/// memory; over-pruning breaks convergence, so the safe default is to do
/// nothing on an unknown format.
///
/// Wire form: `fgvv1:<replica>=<counter>;<replica>=<counter>…`. Replica
/// ids are device UUIDs (or the seed sentinel `seed`) and never contain
/// `:`, `;` or `=`, so the split is unambiguous. An empty vector packs to
/// the empty string (nothing observed yet).
abstract final class FugueFrontier {
  static const String _tag = 'fgvv1:';

  /// Packs a `replica → maxCounter` version vector. Entries with a
  /// non-positive counter are dropped (a replica the device has authored
  /// or observed nothing from carries no boundary). Returns the empty
  /// string when the resulting vector is empty.
  static String pack(Map<String, int> vv) {
    final parts = <String>[];
    for (final e in vv.entries) {
      if (e.value <= 0) continue;
      parts.add('${e.key}=${e.value}');
    }
    if (parts.isEmpty) return '';
    return _tag + parts.join(';');
  }

  /// Parses a string produced by [pack]. Returns `null` when [packed]
  /// is not a recognised `fgvv1` frontier (old-format or corrupt) — the
  /// caller must treat that as "unreported" and prune nothing for it.
  /// An empty string parses to an empty vector (a valid "nothing yet"
  /// report), NOT null, so a fresh device doesn't block the boundary any
  /// differently than a device that reports `fgvv1:` with no entries.
  static Map<String, int>? unpack(String packed) {
    if (packed.isEmpty) return const <String, int>{};
    if (!packed.startsWith(_tag)) return null;
    final body = packed.substring(_tag.length);
    if (body.isEmpty) return const <String, int>{};
    final out = <String, int>{};
    for (final kv in body.split(';')) {
      final eq = kv.lastIndexOf('=');
      if (eq <= 0) return null; // malformed → fail safe
      final replica = kv.substring(0, eq);
      final counter = int.tryParse(kv.substring(eq + 1));
      if (counter == null) return null;
      out[replica] = counter;
    }
    return out;
  }
}
