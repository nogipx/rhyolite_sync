import 'package:convergent/fugue.dart';
import 'package:rhyolite_sync/src/sync_v3/fugue_text_sync.dart';
import 'package:test/test.dart';

/// Demonstrates how a large offline edit merges under the deadline-bounded
/// diff. Runs the SAME scenario twice — once with the normal deadline, once
/// with a forced near-zero deadline (`1e-9s`) that pushes the diff onto its
/// coarse fallback — and shows both produce the same correct merge:
///   * device A's deletion is honoured (not resurrected),
///   * device B's concurrent insert is preserved,
///   * A's own append is preserved.
void main() {
  String doc(List<String> lines) => lines.join('\n');

  // Mirrors DiskReconciler._reconcileText: observe the file's own dots, then
  // apply. `deadline` lets us force the coarse diff path deterministically.
  Future<Fugue<String>> applyText(
    Fugue<String> old,
    String text,
    String device, {
    double deadline = 1.0,
  }) {
    final clk = LamportClock(device)..observeAll(old.dots);
    return FugueTextSync.applyTextSnapshot(
      oldFugue: old,
      newText: text,
      clock: clk,
      deadlineSeconds: deadline,
    );
  }

  final baseText = doc([
    'L01', 'L02', 'L03', 'L04', 'L05', 'L06', 'L07', 'L08', 'L09', 'L10',
    'L11', 'L12', 'L13', 'L14', 'L15', 'L16', 'L17', 'L18', 'L19', 'L20',
  ]);

  // Device A (big offline edit): delete the L08..L12 block, append two lines.
  final aText = doc([
    'L01', 'L02', 'L03', 'L04', 'L05', 'L06', 'L07',
    'L13', 'L14', 'L15', 'L16', 'L17', 'L18', 'L19', 'L20',
    'A-new-1', 'A-new-2',
  ]);

  // Device B (concurrent): insert one line after L03, keep everything else.
  final bText = doc([
    'L01', 'L02', 'L03', 'B-new', 'L04', 'L05', 'L06', 'L07', 'L08', 'L09',
    'L10', 'L11', 'L12', 'L13', 'L14', 'L15', 'L16', 'L17', 'L18', 'L19', 'L20',
  ]);

  Future<String> runScenario(double deadline) async {
    final base = FugueTextSync.seedFromText(baseText); // shared synced state
    final a = await applyText(base.clone(), aText, 'A', deadline: deadline);
    final b = await applyText(base.clone(), bText, 'B', deadline: deadline);
    // Lossless CRDT merge of the two concurrent trees.
    return a.join(b).values.join();
  }

  test('large concurrent edit merges losslessly (normal + deadline path)',
      () async {
    final normal = await runScenario(1.0);
    final coarse = await runScenario(1e-9); // force the deadline fallback

    for (final merged in [normal, coarse]) {
      final lines = merged.split('\n');
      // A's deletion honoured — the whole block is gone, not resurrected.
      for (final gone in ['L08', 'L09', 'L10', 'L11', 'L12']) {
        expect(lines, isNot(contains(gone)),
            reason: '$gone was deleted by A and must stay deleted');
      }
      // B's concurrent insert survives.
      expect(lines, contains('B-new'));
      // A's append survives.
      expect(lines, containsAll(['A-new-1', 'A-new-2']));
      // Kept lines still there.
      expect(lines, containsAll(['L01', 'L07', 'L13', 'L20']));
    }

    // Both paths converge to the exact same document.
    expect(coarse, normal,
        reason: 'the deadline-coarsened diff must merge to the same result');

    // The precise merged document:
    expect(normal, doc([
      'L01', 'L02', 'L03', 'B-new', 'L04', 'L05', 'L06', 'L07',
      'L13', 'L14', 'L15', 'L16', 'L17', 'L18', 'L19', 'L20',
      'A-new-1', 'A-new-2',
    ]));
  });

  // The user's real scenario: a small synced note, then a HUGE offline
  // rewrite on device A, and a DIFFERENT huge rewrite on device B in the same
  // file. What happens to the two texts on sync?
  test('two huge, different offline rewrites of the same note both survive',
      () async {
    // Small note that was already synced to both devices.
    const synced = 'Meeting notes\n';

    // Device A: keeps the title, appends a big block of its own.
    final aBig = synced +
        doc([for (var i = 1; i <= 12; i++) 'A: point ${i.toString().padLeft(2, '0')}']);
    // Device B: keeps the title, appends a DIFFERENT big block.
    final bBig = synced +
        doc([for (var i = 1; i <= 12; i++) 'B: idea ${i.toString().padLeft(2, '0')}']);

    final base = FugueTextSync.seedFromText(synced);
    // Force the coarse (deadline) diff to prove it doesn't change the outcome.
    final a = await applyText(base.clone(), aBig, 'deviceA', deadline: 1e-9);
    final b = await applyText(base.clone(), bBig, 'deviceB', deadline: 1e-9);

    final abMerge = a.join(b).values.join();
    final baMerge = b.join(a).values.join();

    // Nothing is lost — every line of BOTH texts is present.
    for (var i = 1; i <= 12; i++) {
      final n = i.toString().padLeft(2, '0');
      expect(abMerge, contains('A: point $n'));
      expect(abMerge, contains('B: idea $n'));
    }
    // The shared title survives once (not doubled).
    expect('Meeting notes\n'.allMatches(abMerge).length, 1);
    // Both devices converge to the exact same document.
    expect(baMerge, abMerge, reason: 'A.join(B) == B.join(A) — convergence');
    // Each block stays intact (not char-interleaved): all A lines form a
    // contiguous run, all B lines another — the two texts sit back-to-back.
    final firstA = abMerge.indexOf('A: point 01');
    final lastA = abMerge.indexOf('A: point 12');
    final firstB = abMerge.indexOf('B: idea 01');
    final lastB = abMerge.indexOf('B: idea 12');
    final aContiguous = firstA < lastA && (lastB < firstA || firstB > lastA);
    expect(aContiguous, isTrue,
        reason: 'each rewrite stays a contiguous block, not garbled');
  });
}
