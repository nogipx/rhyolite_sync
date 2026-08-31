/// Fractional indices: strings that can always be ordered between two others.
///
/// Base 62 over `0-9A-Za-z`, which is ASCII order, so comparing the strings
/// lexicographically compares the positions. That is the whole trick — no
/// numbers, no renumbering.
///
/// There is deliberately NO rebalancing. A rebalance is a write, and only a
/// user's edit is allowed to cause a write: a background renumber would touch
/// every key of every note, change the blob hash and push the lot. The cost is
/// that an index grows by about a character each time something is inserted
/// between the same pair, which for a header of a dozen properties never
/// matters.
library;

const _alphabet =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
const _base = 62;

int _idx(String c) => _alphabet.indexOf(c);
String _ch(int i) => _alphabet[i];

/// The index handed to a lone first key. Mid-alphabet so there is room on both
/// sides without ever needing to go below the floor digit.
final String midFracIndex = _ch(_base ~/ 2);

/// True when [s] is a well-formed index: non-empty, in-alphabet, and not all
/// zeros.
///
/// The all-zero case is the one shape nothing can be placed before, so it is
/// never generated and treated as malformed on the way in.
bool isValidFracIndex(String s) {
  if (s.isEmpty) return false;
  var allZero = true;
  for (final c in s.split('')) {
    if (_idx(c) < 0) return false;
    if (c != '0') allZero = false;
  }
  return !allZero;
}

/// Returns an index strictly between [a] and [b].
///
/// Null means unbounded on that side. Deterministic: two devices computing a
/// position from the same neighbours get the same string, which is what lets a
/// lifted `fugue1` blob converge without any coordination (§11).
String fracIndexBetween(String? a, String? b) {
  assert(
    a == null || b == null || a.compareTo(b) < 0,
    'fracIndexBetween($a, $b): bounds must be ordered',
  );
  if (a == null && b == null) return midFracIndex;
  if (a == null) return _before(b!);
  if (b == null) return _after(a);

  final buf = StringBuffer();
  var i = 0;
  while (true) {
    final da = i < a.length ? _idx(a[i]) : -1;
    final db = i < b.length ? _idx(b[i]) : _base;
    if (db - da > 1) {
      buf.write(_ch((da + db) ~/ 2));
      return buf.toString();
    }
    // The digits touch, so the answer shares this prefix with [a] and the
    // decision moves one place right. Once past a's end there is always room,
    // because anything appended is greater than [a] and still under [b].
    buf.write(i < a.length ? a[i] : '0');
    i++;
  }
}

/// Something strictly greater than [a]: keep it and append a mid digit.
String _after(String a) => '$a$midFracIndex';

/// Something strictly less than [b].
String _before(String b) {
  final buf = StringBuffer();
  var i = 0;
  while (true) {
    final d = i < b.length ? _idx(b[i]) : _base;
    if (d > 1) {
      // Room below: halve this digit. Never reaches 0 for d >= 2.
      buf.write(_ch(d ~/ 2));
      return buf.toString();
    }
    if (d == 1) {
      // Dropping to 0 already puts us under [b], so the tail is free.
      buf
        ..write('0')
        ..write(midFracIndex);
      return buf.toString();
    }
    // d == 0: stay level and look further right. Only reachable for an index
    // with leading zeros, which [isValidFracIndex] refuses to produce.
    buf.write('0');
    i++;
  }
}

/// Index for the key at [position] of [total] when a whole region is placed at
/// once — the lift path (§11) and the first ingest of a file.
///
/// Computed from the position rather than by chaining [fracIndexBetween], and
/// never from a clock: two devices lifting the same blob must produce the same
/// bytes, or the converged states differ and every open of the file re-pushes.
String fracIndexForPosition(int position, int total) {
  assert(position >= 0 && position < total);
  // One digit while a region has fewer than 61 keys, which is every real
  // header; beyond that the second digit keeps the order strict.
  if (total <= _base - 1) return _ch(position + 1);
  final hi = 1 + (position ~/ (_base - 1));
  final lo = position % (_base - 1);
  return '${_ch(hi)}${_ch(lo + 1)}';
}
