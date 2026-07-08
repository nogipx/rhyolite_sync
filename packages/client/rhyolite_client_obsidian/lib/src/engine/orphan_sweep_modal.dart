import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

/// Reclaims orphaned blobs — server-side sweep that deletes blobs referenced by
/// no current file and no history event. Always dry-runs first and shows the
/// numbers before anything is deleted.
Future<void> showOrphanSweepModal(
  PluginHandle plugin,
  ISyncEngine engine,
) async {
  final janitor = engine is StateSyncEngine ? engine.createBlobJanitor() : null;
  if (janitor == null) {
    showNotice('Orphan sweep not available — engine is not connected');
    return;
  }

  // The dry-run enumerates the whole blob bucket — can take a few seconds — so
  // give immediate feedback instead of a silent delay before the modal opens.
  showNotice('Scanning storage for orphaned blobs…');
  final SweepOrphanBlobsResponse? report;
  try {
    report = await janitor.sweepOrphans(dryRun: true);
  } catch (e) {
    showNotice('Orphan scan failed: $e');
    return;
  }
  if (report == null) {
    showNotice('Orphan sweep not available on this server yet');
    return;
  }

  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3('Reclaim orphaned blobs');
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: 'Blobs referenced by no current file and no history entry — dead '
            'weight left by failed uploads or files deleted in an earlier '
            'cleanup. Safe to remove.',
      );
      ctx.spaceVertical(px: 12);

      _kv(ctx, 'Total blobs',
          '${report!.totalBlobs}  (${_bytes(report.totalBytes)})');
      _kv(ctx, 'Orphaned (reclaimable)',
          '${report.orphanBlobs}  (${_bytes(report.orphanBytes)})');
      ctx.spaceVertical(px: 16);

      if (report.orphanBlobs == 0) {
        ctx.createEl('p', text: 'Nothing to reclaim.');
        ctx.buttonRow([ButtonSpec('Close', () => ctx.close(null))]);
        ctx.onEscape(() => ctx.close(null));
        return;
      }

      Future<void> reclaim() async {
        ctx.close(null);
        try {
          final result = await janitor.sweepOrphans(dryRun: false);
          showNotice(
            'Reclaimed ${result?.deletedBlobs ?? 0} blobs '
            '(${_bytes(result?.orphanBytes ?? 0)}).',
          );
        } catch (e) {
          showNotice('Reclaim failed: $e');
        }
      }

      ctx.buttonRow([
        ButtonSpec('Reclaim ${_bytes(report.orphanBytes)}', reclaim,
            variant: ButtonVariant.destructive),
        ButtonSpec('Cancel', () => ctx.close(null)),
      ]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}

void _kv(ModalContext<void> ctx, String key, String value) {
  ctx.createEl('p', cls: 'rhyolite-setting-desc', text: '$key: $value');
}

String _bytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
