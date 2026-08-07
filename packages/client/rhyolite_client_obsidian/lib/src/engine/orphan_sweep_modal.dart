import 'package:obsidian_dart/obsidian_dart.dart';
import 'package:rhyolite_sync/rhyolite_sync.dart';

import '../i18n/i18n.dart';

/// Reclaims server-side residue: orphaned blobs (referenced by no current file
/// and no history event) AND causally-stable tombstones (deleted-file markers
/// every device has already seen). Always dry-runs first and shows the numbers
/// before anything is deleted.
Future<void> showOrphanSweepModal(
  PluginHandle plugin,
  ISyncEngine engine,
) async {
  final janitor = engine is StateSyncEngine ? engine.createBlobJanitor() : null;
  // A bring-your-own vault keeps its blobs in the user's own bucket, which the
  // server can neither enumerate nor delete — so its orphans need the split
  // sweep (client lists and deletes, server judges) rather than the managed one.
  final byo = engine is StateSyncEngine ? engine.createByoBlobJanitor() : null;
  if (byo != null) {
    return _showByoSweepModal(plugin, byo);
  }
  if (janitor == null) {
    showNotice(S.storageSweepUnavailable);
    return;
  }

  // The dry-run enumerates the whole blob bucket — can take a few seconds — so
  // give immediate feedback instead of a silent delay before the modal opens.
  showNotice(S.scanningStorage);
  final SweepOrphanBlobsResponse? blobs;
  SweepStableTombstonesResponse? tombs;
  try {
    blobs = await janitor.sweepOrphans(dryRun: true);
    // Tombstone sweep is newer — an older server 404s; degrade gracefully.
    try {
      tombs = await janitor.sweepStableTombstones(dryRun: true);
    } catch (_) {
      tombs = null;
    }
  } catch (e) {
    showNotice(S.storageScanFailed(e));
    return;
  }
  if (blobs == null) {
    showNotice(S.storageSweepNotSupported);
    return;
  }

  final orphanBytes = blobs.orphanBytes;
  final orphanBlobs = blobs.orphanBlobs;
  final stableTombs = tombs?.stableTombstones ?? 0;

  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3(S.reclaimStorageTitle);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: S.reclaimStorageDescription,
      );
      ctx.spaceVertical(px: 12);

      _kv(ctx, S.totalBlobs,
          '${blobs!.totalBlobs}  (${_bytes(blobs.totalBytes)})');
      _kv(ctx, S.orphanedBlobsReclaimable,
          '$orphanBlobs  (${_bytes(orphanBytes)})');
      final t = tombs;
      if (t != null) {
        _kv(ctx, S.deletedMarkersReclaimable,
            S.markersOfTotal(stableTombs, t.totalTombstones));
      }
      ctx.spaceVertical(px: 16);

      if (orphanBlobs == 0 && stableTombs == 0) {
        ctx.createEl('p', text: S.nothingToReclaim);
        ctx.buttonRow([ButtonSpec(S.close, () => ctx.close(null))]);
        ctx.onEscape(() => ctx.close(null));
        return;
      }

      Future<void> reclaim() async {
        ctx.close(null);
        final parts = <String>[];
        try {
          if (orphanBlobs > 0) {
            final r = await janitor.sweepOrphans(dryRun: false);
            parts.add(
                S.reclaimedBlobs(r?.deletedBlobs ?? 0, _bytes(r?.orphanBytes ?? 0)));
          }
          if (stableTombs > 0) {
            final r = await janitor.sweepStableTombstones(dryRun: false);
            parts.add(S.reclaimedMarkers(r?.deletedTombstones ?? 0));
          }
          showNotice(S.reclaimedSummary(parts.join(' + ')));
        } catch (e) {
          showNotice(S.reclaimFailed(e));
        }
      }

      final segs = <String>[];
      if (orphanBytes > 0) segs.add(_bytes(orphanBytes));
      if (stableTombs > 0) segs.add(S.markersCount(stableTombs));
      ctx.buttonRow([
        ButtonSpec('${S.reclaimVerb} ${segs.join(' + ')}', reclaim,
            variant: ButtonVariant.destructive),
        ButtonSpec(S.cancel, () => ctx.close(null)),
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

/// The bring-your-own variant. Same shape as the managed sweep — dry run,
/// show the numbers, delete only on confirmation — but the enumeration
/// happens here and only the verdict comes from the server.
Future<void> _showByoSweepModal(
  PluginHandle plugin,
  ByoBlobJanitor janitor,
) async {
  showNotice(S.scanningStorage);
  final ByoSweepPlan plan;
  try {
    plan = await janitor.scan();
  } catch (e) {
    showNotice(S.storageScanFailed(e));
    return;
  }
  if (plan.unsupported) {
    showNotice(S.storageSweepNotSupported);
    return;
  }

  return showModalWith<void>(
    plugin,
    build: (ctx) {
      ctx.h3(S.reclaimStorageTitle);
      ctx.createEl(
        'p',
        cls: 'rhyolite-setting-desc',
        text: S.reclaimStorageByoDescription,
      );
      ctx.spaceVertical(px: 12);

      _kv(ctx, S.totalBlobs, '${plan.totalBlobs}');
      _kv(ctx, S.orphanedBlobsReclaimable, '${plan.deadCount}');
      ctx.spaceVertical(px: 16);

      if (plan.isClean) {
        ctx.createEl('p', text: S.nothingToReclaim);
        ctx.buttonRow([ButtonSpec(S.close, () => ctx.close(null))]);
        ctx.onEscape(() => ctx.close(null));
        return;
      }

      ctx.buttonRow([
        ButtonSpec(
          '${S.reclaimVerb} ${plan.deadCount}',
          () async {
            ctx.close(null);
            try {
              final deleted = await janitor.execute(plan);
              showNotice(S.reclaimedByo(deleted));
            } catch (e) {
              showNotice(S.reclaimFailed(e));
            }
          },
          variant: ButtonVariant.destructive,
        ),
        ButtonSpec(S.cancel, () => ctx.close(null)),
      ]);
      ctx.onEscape(() => ctx.close(null));
    },
  );
}
