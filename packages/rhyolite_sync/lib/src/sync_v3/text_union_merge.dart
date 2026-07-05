import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Deterministic, order-independent line-level union of divergent text
/// versions that share no causal history.
///
/// Used by the text-conflict resolver when concurrent values cannot be
/// char-merged losslessly (independent seeds, post-reseed, repair). Unlike
/// the char-level Fugue join — which silently drops one side when seed dots
/// collide — this keeps every line from every input. Common context lines
/// are de-duplicated; divergent lines from both sides are kept side by side
/// (diff3 `--union` semantics).
///
/// CONVERGENCE: every device computes a byte-identical result from the same
/// set of inputs, so the sealed merge is identical everywhere. Guaranteed by
/// (1) canonical input ordering — sorted by sha256 of the content, so the
/// result does not depend on which device pulled which; and (2) a pure,
/// deadline-free LCS (no wall-clock cutoff that could diverge across slow vs
/// fast devices). Above [_pairBudget] line-pairs the LCS is skipped for a
/// deterministic ordered concatenation — still lossless and convergent.
String deterministicLineUnion(List<String> texts) {
  final inputs = texts.where((t) => t.isNotEmpty).toList(growable: false);
  if (inputs.isEmpty) return '';
  if (inputs.length == 1) return inputs.first;

  // Canonical order: sort by content hash so union(A,B) == union(B,A) and
  // every device folds in the same sequence.
  final sorted = [...inputs]
    ..sort((a, b) => _sha(a).compareTo(_sha(b)));

  var acc = sorted.first;
  for (var i = 1; i < sorted.length; i++) {
    acc = _union2(acc, sorted[i]);
  }
  return acc;
}

/// Hard cap on LCS cost (lines(x) * lines(y)). Above it we fall back to a
/// deterministic ordered concatenation rather than risk an O(N*M) blowup on
/// the host's main thread. Sized so ordinary notes (thousands of lines) stay
/// on the LCS path.
const int _pairBudget = 200000;

String _sha(String text) =>
    sha256.convert(utf8.encode(text)).toString();

/// Union of two texts already in canonical (hash) order: [x] before [y].
String _union2(String x, String y) {
  if (x == y) return x;
  final xl = x.split('\n');
  final yl = y.split('\n');
  if (xl.length * yl.length > _pairBudget) {
    // Deterministic, lossless fallback for pathologically large inputs.
    return '$x\n$y';
  }
  final lcs = _lcsLines(xl, yl);
  return _weave(xl, yl, lcs).join('\n');
}

/// Longest common subsequence of the two line lists, returned as the common
/// lines in order. Standard O(N*M) DP with a deterministic tie-break.
List<String> _lcsLines(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  // dp[i][j] = LCS length of a[i..] and b[j..].
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      if (a[i] == b[j]) {
        dp[i][j] = dp[i + 1][j + 1] + 1;
      } else {
        // Tie-break toward advancing `a` first — deterministic.
        dp[i][j] = dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1];
      }
    }
  }
  final out = <String>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out.add(a[i]);
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return out;
}

/// Emits, between each pair of common anchors, x's divergent lines followed
/// by y's divergent lines, then the anchor once. Lossless: every line of x
/// and y is emitted; shared anchors appear a single time.
List<String> _weave(List<String> xl, List<String> yl, List<String> lcs) {
  final out = <String>[];
  var i = 0;
  var j = 0;
  for (final anchor in lcs) {
    while (i < xl.length && xl[i] != anchor) {
      out.add(xl[i++]);
    }
    while (j < yl.length && yl[j] != anchor) {
      out.add(yl[j++]);
    }
    // Both i and j now sit on `anchor`.
    out.add(anchor);
    i++;
    j++;
  }
  while (i < xl.length) {
    out.add(xl[i++]);
  }
  while (j < yl.length) {
    out.add(yl[j++]);
  }
  return out;
}
