import 'app_strings.dart';

/// English strings — the reference locale.
class EnStrings extends AppStrings {
  const EnStrings();

  // ── Common ──
  @override
  String get cancel => 'Cancel';
  @override
  String get close => 'Close';
  @override
  String get delete => 'Delete';

  // ── Setup / passphrase ──
  @override
  String get setupDescription => 'Set up end-to-end encryption for this vault.';
  @override
  String get enterPassphrase => 'Enter passphrase';
  @override
  String get confirmPassphrase => 'Confirm passphrase';
  @override
  String get showPassphrase => 'Show passphrase';
  @override
  String get rememberOnThisDevice => 'Remember on this device';
  @override
  String get rememberKeyDescription =>
      'Stores a derived key in the system keychain so you are not prompted for '
      'the passphrase on every launch.';
  @override
  String get derivingKey => 'Deriving key, please wait…';
  @override
  String get passphraseEmpty => 'Passphrase cannot be empty.';
  @override
  String get passphraseTooWeak => 'Passphrase too weak.';
  @override
  String get passphrasesDoNotMatch => 'Passphrases do not match.';
  @override
  String get setUpEncryption => 'Set up encryption';
  @override
  String get vaultPassphrase => 'Vault passphrase';
  @override
  String get incorrectPassphrase => 'Incorrect passphrase. Please try again.';
  @override
  String get unlock => 'Unlock';

  // ── Vault picker ──
  @override
  String get selectVault => 'Select vault';
  @override
  String get noVaultsFound => 'No vaults found. Create one below.';
  @override
  String get connect => 'Connect';
  @override
  String vaultDeleted(String name) => 'Vault "$name" deleted.';
  @override
  String deleteVaultFailed(Object error) => 'Delete failed: $error';
  @override
  String get planSingleVault =>
      'Your plan includes a single vault. Upgrade to add more.';
  @override
  String planVaultLimit(int max) =>
      "You have reached your plan's vault limit ($max). Upgrade to add more.";
  @override
  String get createNewVault => 'Create a new vault:';
  @override
  String get vaultNamePlaceholder => 'Vault name';
  @override
  String get createVault => '+ Create';
  @override
  String get vaultNameEmpty => 'Vault name cannot be empty.';
  @override
  String deleteVaultTitle(String name) => 'Delete vault "$name"?';
  @override
  String get deleteVaultBody =>
      "This permanently deletes all of this vault's data from the server "
      '(files, history, blobs). Your local note files on disk are NOT deleted. '
      'If this vault used your own S3/WebDAV storage, clear that bucket '
      'separately. This cannot be undone.';
  @override
  String get typeVaultNameToConfirm => 'Type the vault name to confirm:';
  @override
  String get nameDoesNotMatch => 'Name does not match.';
  @override
  String get deletePermanently => 'Delete permanently';

  // ── Backups / restore points ──
  @override
  String get backupsUnavailable =>
      'Backups not available — engine is not connected';
  @override
  String backupsLoadFailed(Object error) => 'Failed to load backups: $error';
  @override
  String get backupsTitle => 'Vault backups';
  @override
  String get backupsDescription =>
      'Restore files in place from a snapshot — identical files are left alone, '
      'and every change stays reversible via file history.';
  @override
  String get createRestorePointNow => 'Create restore point now';
  @override
  String get noRestorePointsYet =>
      'No restore points yet. Pro vaults keep daily ones (7 newest).';
  @override
  String restorePointLine(String when, int files) =>
      '$when  ·  $files file(s)';
  @override
  String get details => 'Details';
  @override
  String get restoreAllAction => 'Restore all…';
  @override
  String get creatingRestorePoint => 'Creating restore point …';
  @override
  String get notConnectedNoCapture =>
      'Not connected — no restore point created.';
  @override
  String restorePointCreated(int files) =>
      'Restore point created ($files file(s)).';
  @override
  String captureFailed(Object error) =>
      'Failed to create restore point: $error';
  @override
  String get restorePointDeleted => 'Restore point deleted.';
  @override
  String get restorePointNotFound => 'Restore point not found.';
  @override
  String deleteRestorePointFailed(Object error) =>
      'Failed to delete restore point: $error';
  @override
  String restoreAllTitle(String when) => 'Restore all · $when';
  @override
  String get restoreAllConfirmBody =>
      'Overwrite current files with this restore point wherever they differ. '
      'Files identical to now are left alone; nothing is deleted. Each change '
      'syncs and stays reversible via file history.';
  @override
  String get restoreAllConfirm => 'Restore all';
  @override
  String get restoring => 'Restoring …';
  @override
  String get restoreUnavailableNotConnected =>
      'Restore unavailable — not connected.';
  @override
  String restoredFilesCount(int n) => 'Restored $n file(s)';
  @override
  String unchangedCount(int n) => '$n unchanged';
  @override
  String errorsCount(int n) => '$n error(s)';
  @override
  String restoreFailed(Object error) => 'Restore failed: $error';

  // ── Storage cleanup / reclaim ──
  @override
  String get storageSweepUnavailable =>
      'Storage sweep not available — engine is not connected';
  @override
  String get scanningStorage => 'Scanning storage…';
  @override
  String storageScanFailed(Object error) => 'Storage scan failed: $error';
  @override
  String get storageSweepNotSupported =>
      'Storage sweep not available on this server yet';
  @override
  String get reclaimStorageTitle => 'Reclaim storage';
  @override
  String get reclaimStorageDescription =>
      'Server-side dead weight: orphaned blobs (failed uploads / old cleanup '
      'residue) and deleted-file markers every device has already seen. Content '
      'stays recoverable via history / restore points.';
  @override
  String get totalBlobs => 'Total blobs';
  @override
  String get orphanedBlobsReclaimable => 'Orphaned blobs (reclaimable)';
  @override
  String get deletedMarkersReclaimable => 'Deleted-file markers (reclaimable)';
  @override
  String markersOfTotal(int stable, int total) => '$stable of $total';
  @override
  String get nothingToReclaim => 'Nothing to reclaim.';
  @override
  String reclaimedBlobs(int n, String bytes) => '$n blobs ($bytes)';
  @override
  String reclaimedMarkers(int n) => '$n deleted-file marker(s)';
  @override
  String reclaimedSummary(String parts) => 'Reclaimed $parts.';
  @override
  String reclaimFailed(Object error) => 'Reclaim failed: $error';
  @override
  String get reclaimVerb => 'Reclaim';
  @override
  String markersCount(int n) => '$n marker(s)';

  // ── Storage overview ──
  @override
  String get storageOverviewUnavailable =>
      'Storage overview not available — engine is not connected';
  @override
  String get storageOverviewTitle => 'Storage overview';
  @override
  String get contentThisDevice => 'Content (this device)';
  @override
  String get notSyncedYet => 'Not synced yet.';
  @override
  String get files => 'Files';
  @override
  String get contentSize => 'Content size';
  @override
  String get uniqueBlobs => 'Unique blobs';
  @override
  String get conflicts => 'Conflicts';
  @override
  String get deletedTombstoned => 'Deleted (tombstoned)';
  @override
  String get historyServer => 'History (server)';
  @override
  String get couldNotReadHistory => 'Could not read history (not connected?).';
  @override
  String get versionsKept => 'Versions kept';
  @override
  String get range => 'Range';
  @override
  String get devices => 'Devices';
  @override
  String get noDevicesReported => 'No devices have reported yet.';
  @override
  String get thisDeviceSuffix => '  (this device)';
  @override
  String behindBy(int n) => '  ·  $n behind';
  @override
  String deviceLine(String name, String suffix, String ago, String behind) =>
      '$name$suffix  —  seen $ago$behind';
  @override
  String get justNow => 'just now';
  @override
  String minutesAgo(int m) => '${m}m ago';
  @override
  String hoursAgo(int h) => '${h}h ago';
  @override
  String daysAgo(int d) => '${d}d ago';
  @override
  String get restorePointsServer => 'Restore points (server)';
  @override
  String get restorePointsUnavailableText =>
      'Unavailable — the server does not support restore points yet (update the '
      'server, or this vault is offline).';
  @override
  String get restorePointsNoneYet =>
      'None yet. Open Restore points… to create one; Pro vaults also keep daily '
      'ones (7 newest).';
  @override
  String get kept => 'Kept';
  @override
  String get restorePointsHoldBlobs =>
      'These hold on to older blobs, so some storage will not free until they '
      'age out (or you clear them).';
  @override
  String get cleanUpStorage => 'Clean up storage…';
  @override
  String get reclaimOrphans => 'Reclaim orphans…';
  @override
  String get manageDevices => 'Manage devices…';
  @override
  String get restorePointsAction => 'Restore points…';
  @override
  String get clearRestorePointsAction => 'Clear restore points…';
  @override
  String get clearRestorePointsTitle => 'Clear restore points';
  @override
  String clearRestorePointsBody(int count) =>
      'Drop all $count restore point(s)? You will no longer be able to restore '
      'an earlier state. This frees the blobs they pin — run Reclaim orphans '
      'afterwards to actually reclaim the space.';
  @override
  String get clearVerb => 'Clear';
  @override
  String get notConnectedNothingCleared => 'Not connected — nothing cleared.';
  @override
  String clearedRestorePoints(int n) =>
      'Cleared $n restore point(s). Run Reclaim orphans to free the space.';
  @override
  String clearRestorePointsFailed(Object error) =>
      'Failed to clear restore points: $error';

  // ── Storage cleanup (history) ──
  @override
  String get storageCleanupUnavailable =>
      'Storage cleanup not available — engine is not connected';
  @override
  String cleanupScanFailed(Object error) =>
      'Storage cleanup scan failed: $error';
  @override
  String nothingToCleanOlderThan(int days) =>
      'Nothing to clean up older than $days days.';
  @override
  String cleanupIncomplete(int deleted, int failed) =>
      'Cleanup incomplete: $deleted blobs deleted, $failed failed — history kept '
      'so a re-run can retry.';
  @override
  String cleanupDone(int events, int blobs) =>
      'Cleanup done: $events history entries and $blobs blobs deleted.';
  @override
  String cleanupFailed(Object error) => 'Storage cleanup failed: $error';
  @override
  String get storageCleanupTitle => 'Storage cleanup';
  @override
  String get storageCleanupDescription =>
      'Permanently remove history entries older than the chosen number of days. '
      'Blobs referenced only by those entries are also deleted from blob storage.';
  @override
  String get deleteEventsOlderThanLabel =>
      'Delete events older than (days) — use 0 to clear all history that every '
      'active device has already synced:';
  @override
  String daysMustBeBetween(int min, int max) =>
      'Days must be between $min and $max.';
  @override
  String get scanAction => 'Scan';
  @override
  String get confirmCleanupTitle => 'Confirm cleanup';
  @override
  String eventsToDelete(int n, int total) => 'Events to delete: $n of $total';
  @override
  String orphanBlobsToDelete(int n) => 'Orphan blobs to delete: $n';
  @override
  String oldestEntryToDelete(String when) => 'Oldest entry to delete: $when';
  @override
  String newestEntryToDelete(String when) => 'Newest entry to delete: $when';
  @override
  String oldestEntryRemaining(String when) => 'Oldest entry remaining: $when';
  @override
  String get deviceSafety => 'Device safety:';
  @override
  String get noDeviceHeadYet =>
      'No devices have reported a history head yet. Only the age cutoff is '
      'protecting events from deletion.';
  @override
  String get ageLessThanDay => '<1 day ago';
  @override
  String cleanupDaysAgo(int n) => '$n day${n == 1 ? '' : 's'} ago';
  @override
  String get activeTag => '[active]';
  @override
  String get staleTag => '[stale]';
  @override
  String deviceHeadLine(String tag, String id8, int head, String age) =>
      '$tag  $id8…  head=$head  ($age)';
  @override
  String protectedByMinHead(int minHead, int events) =>
      'Protected by min head $minHead: $events event(s) older than the cutoff '
      'would be deletable but are kept because at least one active device has '
      'not seen them.';
  @override
  String get noActiveDevicesForCleanup =>
      'No devices considered active (last seen within 30 days). Only the age '
      'cutoff applies.';
  @override
  String get cannotBeUndone => 'This cannot be undone.';

  // ── Restore point inspect / diff ──
  @override
  String inspectFailed(Object error) =>
      'Failed to inspect restore point: $error';
  @override
  String get notConnectedCannotInspect => 'Not connected — cannot inspect.';
  @override
  String restorePointTitle(String when) => 'Restore point · $when';
  @override
  String inspectSummary(int changed, int toRestore, int identical) =>
      '$changed changed · $toRestore to restore (deleted since) · '
      '$identical identical';
  @override
  String deletionSuffix(int n) => ' · $n deletion';
  @override
  String get noChangesVsCurrent =>
      'No changes vs the current vault — every file is identical.';
  @override
  String get flairChanged => 'changed';
  @override
  String get flairDeletedNow => 'deleted now';
  @override
  String get flairTombstone => 'tombstone';
  @override
  String entryIdenticalNotice(String path) =>
      '$path: identical to current — nothing would change.';
  @override
  String entryDeletedInBackupNotice(String path) =>
      '$path: was deleted in this restore point.';
  @override
  String diffTitle(String path) => 'Diff · $path';
  @override
  String restoresTitle(String path) => 'Restores · $path';
  @override
  String binaryWouldRestore(int bytes) =>
      'Binary file — would be restored ($bytes bytes).';
  @override
  String get binaryContentDiffers =>
      'Binary file — content differs (not shown as text).';
  @override
  String get restoreThisFile => 'Restore this file';
  @override
  String get restoreThisVersion => 'Restore this version';
  @override
  String loadingPath(String path) => 'Loading $path …';
  @override
  String backupContentUnavailable(String path) =>
      'Backup content for $path is unavailable.';
  @override
  String couldNotLoadPath(String path, Object error) =>
      'Could not load $path: $error';
  @override
  String get restoringAddsContent =>
      'Deleted from the vault since — restoring adds this content:';
  @override
  String get restoringWouldApply =>
      'Restoring would apply these changes (- current, + backup):';
  @override
  String get tooManyChangesToDiff => 'Too many changes to diff — restore to inspect.';
  @override
  String get noDifferencesOnDisk => 'No differences — identical to the file on disk.';
  @override
  String restoringPath(String path) => 'Restoring $path …';
  @override
  String fileRestored(String path) => '$path restored (reversible via history).';
  @override
  String couldNotRestorePath(String path) =>
      'Could not restore $path — not connected or blob gone.';

  // ── Device management ──
  @override
  String get deviceMgmtUnavailable =>
      'Device management not available — engine is not connected';
  @override
  String failedToLoadDevices(Object error) => 'Failed to load devices: $error';
  @override
  String get syncDevicesTitle => 'Sync devices';
  @override
  String deviceMgmtDescription(int count) =>
      '$count device(s) have synced this vault. Forgetting a device you no '
      'longer use lets cleanup reclaim the history it was holding back. It does '
      'not delete any content.';
  @override
  String forgotDevice(String name) =>
      'Forgot $name. Run cleanup to reclaim its held history.';
  @override
  String deviceAlreadyGone(String name) => 'Device $name was already gone.';
  @override
  String couldNotForget(String name, Object error) =>
      'Could not forget $name: $error';
  @override
  String seenLabel(String ago) => 'seen $ago';
  @override
  String behindPlain(int n) => '$n behind';
  @override
  String get forget => 'Forget';

  // ── File version history ──
  @override
  String get noFileOpen => 'No file is open';
  @override
  String get versionHistoryUnavailable =>
      'Version history not available — engine is not connected';
  @override
  String failedToLoadHistory(String path, Object error) =>
      'Failed to load history for $path: $error';
  @override
  String noHistoryFor(String path) => 'No history for $path';
  @override
  String get versionHistoryTitle => 'Version history';
  @override
  String versionsCountHint(int n) =>
      '$n version(s), newest first. Select one to preview and restore.';
  @override
  String get versionPreviewTitle => 'Version preview';
  @override
  String versionPreviewSubtitle(String path, String when) =>
      '$path  ·  $when  ·  vs current';
  @override
  String get blobNoLongerAvailable =>
      'The blob for this version is no longer available — it may have been '
      'removed during a cleanup, or never downloaded to this device.';
  @override
  String get back => 'Back';
  @override
  String get fileDoesNotExistWillRecreate =>
      'This file does not currently exist on disk — restoring will re-create it.';
  @override
  String moreCharacters(int n) => '…($n more characters)';
  @override
  String get noDifferencesMatchesDisk =>
      'No differences — this version matches the file on disk.';
  @override
  String binaryContentPreview(String size) =>
      'Binary content ($size). Cannot preview, but Restore will write the '
      'original bytes.';
  @override
  String restoredFromVersion(String path, String when) =>
      'Restored $path from $when.';
  @override
  String get restoreVerb => 'Restore';

  // ── Settings: common verbs ──
  @override
  String get save => 'Save';
  @override
  String get configure => 'Configure';
  @override
  String get disconnect => 'Disconnect';
  @override
  String get download => 'Download';
  @override
  String get reupload => 'Re-upload';
  @override
  String get ok => 'OK';

  // ── Settings: auth ──
  @override
  String get authStatus => 'Auth status';
  @override
  String signedInAs(String email) => 'Signed in as $email. Click to sign out.';
  @override
  String get signOut => 'Sign out';
  @override
  String get authentication => 'Authentication';
  @override
  String get signIn => 'Sign in';
  @override
  String get signInDescription =>
      'Sign in or create an account in your browser. Rhyolite opens the web '
      'login and brings you back here automatically.';
  @override
  String get signInButton => 'Sign in';
  @override
  String get signedIn => 'Signed in';
  @override
  String signInFailed(Object error) => 'Sign-in failed: $error';
  @override
  String get signInLinkWrongDevice =>
      'This sign-in link is not for this device. Try again.';
  @override
  String couldNotOpenAccountPage(Object error) =>
      'Could not open the account page: $error';

  // ── Settings: vault ──
  @override
  String get vaultSection => 'Vault';
  @override
  String get disconnectVaultName => 'Disconnect vault';
  @override
  String get disconnectVaultDescription =>
      'Stop sync and forget this vault on this device. Vault data on the server '
      'is not affected.';
  @override
  String get connectVaultName => 'Vault';
  @override
  String get connectVaultDescription =>
      'Connect to an existing vault or create a new one.';
  @override
  String get connectVaultButton => 'Connect vault';
  @override
  String get disconnectVaultTitle => 'Disconnect vault?';
  @override
  String disconnectFromVault(String name) =>
      'Disconnect from "$name" on this device?';
  @override
  String get disconnectVaultBody =>
      'Sync will stop. The vault config and remembered passphrase will be '
      'removed from this device. Your data on the server and files on disk are '
      'not affected.';

  // ── Settings: troubleshooting ──
  @override
  String get troubleshooting => 'Troubleshooting';
  @override
  String get reuploadName => 'Re-upload from this device';
  @override
  String get reuploadDescription =>
      'Use this device as the source of truth. Server history will be replaced '
      'with files from this device. Other devices will download the updated '
      'files automatically.';
  @override
  String get reuploadConfirmTitle => 'Re-upload from this device?';
  @override
  String get reuploadConfirmBody =>
      'Server history will be replaced with files from this device. Other '
      'devices will re-sync automatically. No files are deleted.';
  @override
  String get downloadServerName => 'Download from server';
  @override
  String get downloadServerDescription =>
      'Replace local files with the server version. Use this if your files on '
      'this device are outdated or corrupted.';
  @override
  String get downloadServerConfirmTitle => 'Download from server?';
  @override
  String get downloadServerConfirmBody =>
      'Local files will be deleted and replaced with the server version. This '
      'only affects this device.';
  @override
  String get repairName => 'Repair vault sync state';
  @override
  String get repairDescription =>
      'Rebuild sync state for every note from its current disk content and '
      're-upload so the server adopts the fresh state. Use this if notes look '
      'corrupted, duplicated, or sync seems stuck. Your file content on disk is '
      'not modified.';
  @override
  String get repairButton => 'Repair';
  @override
  String get repairConfirmTitle => 'Repair vault sync state?';
  @override
  String get repairConfirmBody =>
      'Every note will be re-seeded from its current disk content and '
      're-uploaded. This can take a while for large vaults. File content on '
      'disk is not changed.';
  @override
  String get repairFinished => 'Vault repair finished — see logs for details.';
  @override
  String repairFailed(Object error) => 'Vault repair failed: $error';

  // ── Settings: self-host ──
  @override
  String get selfHostSection => 'Self-host';
  @override
  String get selfHostEnabledName => 'Self-host enabled';
  @override
  String get selfHostName => 'Self-host';
  @override
  String selfHostServer(String url) => 'Server: $url';
  @override
  String get selfHostDescription =>
      'Sync with your own server instead of the managed service.';
  @override
  String get selfHostReconfigure => 'Reconfigure';
  @override
  String get selfHostEnable => 'Enable self-host';
  @override
  String get applyingSelfHost => 'Applying self-host settings…';

  // ── Settings: subscription ──
  @override
  String get subscriptionSection => 'Subscription';
  @override
  String activeUntil(String date) => 'Active until $date';
  @override
  String get subscriptionActive => 'Your subscription is active.';
  @override
  String get manageSubscription => 'Manage subscription';
  @override
  String get manageSubscriptionDescription =>
      'Open your account page in the browser (signed in).';
  @override
  String get manageOnSite => 'Manage on site';
  @override
  String get subscribe => 'Subscribe';
  @override
  String get subscribeDescription =>
      'Subscribe on the site to sync across all your devices. Opens your '
      'account page in the browser, already signed in.';
  @override
  String get alreadyPaid => 'Already paid?';
  @override
  String get alreadyPaidDescription => 'Check if your payment went through.';
  @override
  String get restoreSubscription => 'Restore subscription';
  @override
  String get checkingSubscription => 'Checking subscription…';
  @override
  String get contactingServer => 'Contacting server';
  @override
  String get subscriptionActivated => 'Subscription activated!';
  @override
  String get subscriptionRestored =>
      'Your subscription has been successfully restored.';
  @override
  String get noSubscriptionFound => 'No subscription found';
  @override
  String get noPaymentFound =>
      'No completed payment was found for your account. If you just paid, '
      'please wait a moment and try again.';

  // ── Settings: diagnostics + file filter ──
  @override
  String get diagnosticsSection => 'Diagnostics';
  @override
  String get logCollectorUrl => 'Log collector URL';
  @override
  String get logCollectorDescription =>
      'WebSocket endpoint your logs stream to. Use wss:// — iOS blocks plain '
      'ws:// silently.';
  @override
  String get sendLogsToCollector => 'Send logs to collector';
  @override
  String get sendLogsDescription =>
      "Off by default — nothing is logged until you enable this. Streams this "
      "device's debug logs to the URL above. Logs include file paths, ids, "
      'hashes, sizes and timings — never file content.';
  @override
  String get fileTypesSection => 'File types';
  @override
  String get dontSyncExtensions => "Don't sync these extensions";
  @override
  String get dontSyncDescription =>
      'Comma-separated list (e.g. pdf, zip, mp4). Files with these extensions '
      'are skipped on this device only — neither uploaded nor downloaded. Other '
      'devices are unaffected. Leave empty to sync everything. Re-adding a type '
      'downloads its files on the next sync.';

  // ── Settings: external storage ──
  @override
  String get externalStorageSection => 'External storage';
  @override
  String get connected => 'Connected';
  @override
  String get disconnectStorage => 'Disconnect storage';
  @override
  String get disconnectStorageDescription =>
      'Stop using external storage. New blobs will go through the sync server.';
  @override
  String get externalStorageDisconnected => 'External storage disconnected.';
  @override
  String couldNotDisconnectStorage(Object error) =>
      'Could not disconnect external storage: $error';
  @override
  String get bringYourOwnStorage => 'Bring your own storage';
  @override
  String get bringYourOwnDescription =>
      'Store file content in your own S3 or WebDAV server. The sync server will '
      'only handle lightweight metadata.';
  @override
  String get s3Compatible => 'S3-compatible';
  @override
  String get s3Description => 'AWS S3, MinIO, Cloudflare R2, Backblaze B2';
  @override
  String get webdavName => 'WebDAV';
  @override
  String get webdavDescription => 'Nextcloud, ownCloud, or any WebDAV server';
  @override
  String externalStorageConnected(String kind) =>
      'External storage connected: $kind';
  @override
  String couldNotSaveStorage(Object error) =>
      'Could not save external storage: $error';
  @override
  String get s3ConfigTitle => 'S3 storage configuration';
  @override
  String get webdavConfigTitle => 'WebDAV storage configuration';
  @override
  String get endpoint => 'Endpoint';
  @override
  String get bucket => 'Bucket';
  @override
  String get accessKey => 'Access Key';
  @override
  String get secretKey => 'Secret Key';
  @override
  String get region => 'Region';
  @override
  String get username => 'Username';
  @override
  String get password => 'Password';

  // ── Settings: settings-sync + storage usage ──
  @override
  String get reuploadSettingsTitle => 'Re-upload settings from this device?';
  @override
  String get reuploadSettingsBody =>
      "Server settings will be replaced with this device's .obsidian settings. "
      'Other devices re-sync automatically.';
  @override
  String get settingsReuploadFinished => 'Settings re-upload finished.';
  @override
  String settingsReuploadFailed(Object error) =>
      'Settings re-upload failed: $error';
  @override
  String get downloadSettingsTitle => 'Download settings from server?';
  @override
  String get downloadSettingsBody =>
      "This device's .obsidian settings will be replaced with the server "
      'version. Most changes apply after an Obsidian restart.';
  @override
  String get settingsDownloadFinished =>
      'Settings download finished — restart Obsidian to apply.';
  @override
  String settingsDownloadFailed(Object error) =>
      'Settings download failed: $error';
  @override
  String get settingsSyncSection => 'Settings sync (.obsidian)';
  @override
  String get syncSettingsName => 'Sync settings (.obsidian)';
  @override
  String get syncSettingsDescription =>
      'Sync app settings, hotkeys, themes and plugin settings across your '
      'devices. Most changes apply after an Obsidian restart.';
  @override
  String get reuploadSettingsRowName => 'Re-upload settings from this device';
  @override
  String get reuploadSettingsRowDesc =>
      'Use this device as the source of truth. Server settings are replaced '
      "with this device's .obsidian settings; other devices re-sync "
      'automatically.';
  @override
  String get downloadSettingsRowName => 'Download settings from server';
  @override
  String get downloadSettingsRowDesc =>
      "Replace this device's .obsidian settings with the server version. Use "
      'this if settings on this device are outdated or wrong. Most changes '
      'apply after an Obsidian restart.';
  @override
  String get settingsCatAppSettings => 'App settings';
  @override
  String get settingsCatAppSettingsDesc =>
      'app.json, graph.json (editor, files & links)';
  @override
  String get settingsCatAppearance => 'Appearance';
  @override
  String get settingsCatAppearanceDesc =>
      'Theme, dark mode, enabled snippets';
  @override
  String get settingsCatHotkeys => 'Hotkeys';
  @override
  String get settingsCatHotkeysDesc => 'Custom hotkeys';
  @override
  String get settingsCatCorePluginsEnabled => 'Core plugins (enabled list)';
  @override
  String get settingsCatCorePluginsEnabledDesc =>
      'Which core plugins are enabled';
  @override
  String get settingsCatCorePluginSettings => 'Core plugin settings';
  @override
  String get settingsCatCorePluginSettingsDesc =>
      'Daily notes, templates, etc.';
  @override
  String get settingsCatCommunityPluginsEnabled =>
      'Community plugins (enabled list)';
  @override
  String get settingsCatCommunityPluginsEnabledDesc =>
      'Which community plugins are enabled';
  @override
  String get settingsCatCommunityPluginSettings => 'Community plugin settings';
  @override
  String get settingsCatCommunityPluginSettingsDesc => "Each plugin's data.json";
  @override
  String get settingsCatThemesSnippets => 'Themes & snippets';
  @override
  String get settingsCatThemesSnippetsDesc =>
      'Downloaded themes and CSS snippets';
  @override
  String get storageSection => 'Storage';

  // ── Sync panel ──
  @override
  String get endToEndEncrypted => 'End-to-end encrypted';
  @override
  String syncedAgo(String ago) => 'synced $ago';
  @override
  String get notConnected => 'Not connected';
  @override
  String get panelStorageLabel => 'Storage';
  @override
  String get vaultSizeLabel => 'Vault size';
  @override
  String get settingsSizeLabel => 'Settings size';
  @override
  String get storageDetails => 'Storage details →';
  @override
  String get refreshStorageUsage => 'Refresh storage usage';
  @override
  String get textMergesLine =>
      'Text merges: conflict-free (CRDT) — concurrent edits never clobber each '
      'other.';
  @override
  String uploadDownloadReport(int up, int down) =>
      '↑ $up uploaded   ↓ $down downloaded';
  @override
  String get resumeSync => 'Resume sync';
  @override
  String get pauseSync => 'Pause sync';
  @override
  String get settingsButton => 'Settings';
  @override
  String activeTransfers(int n) => 'Active transfers ($n)';
  @override
  String get recent => 'Recent';
  @override
  String get browseVersions => 'Browse versions';
  @override
  String tooLargeToSync(int n) => 'Too large to sync ($n)';
  @override
  String get tooLargeHint =>
      'Over your plan’s per-file limit. Kept local-only until they shrink below '
      'the limit or you upgrade.';
  @override
  String blockedMeta(String size, String limit) => '$size · limit $limit';
  @override
  String andMore(int n) => '…and $n more';
  @override
  String conflictsLostContent(int n) => 'Conflicts with lost content ($n)';
  @override
  String storageMeterTitle(String plan) => 'Storage · $plan';
  @override
  String get syncStopped => 'Sync stopped';
  @override
  String get connecting => 'Connecting…';
  @override
  String get reconnecting => 'Reconnecting…';
  @override
  String get offlineCantReach => 'Offline — can’t reach server';
  @override
  String get upToDate => 'Up to date';
  @override
  String get pendingChanges => 'Pending changes';
  @override
  String syncingProgress(int completed, int total) =>
      'Syncing $completed/$total';
  @override
  String get syncingEllipsis => 'Syncing…';
  @override
  String get syncErrorStatus => 'Sync error';
  @override
  String get sessionExpiredStatus => 'Session expired';
  @override
  String get subscriptionRequiredStatus => 'Subscription required';
  @override
  String get pausedStatus => 'Paused';

  // ── Self-host modal ──
  @override
  String get selfHostModalTitle => 'Self-host server';
  @override
  String get selfHostModalDescription =>
      'Sync with your own server instead of the managed service. Reload the '
      'plugin after saving to apply.';
  @override
  String get serverUrl => 'Server URL';
  @override
  String get accessToken => 'Access token';
  @override
  String get enableAndSave => 'Enable & Save';
  @override
  String get serverUrlTokenRequired =>
      'Server URL and access token are both required.';
  @override
  String get disable => 'Disable';

  // ── DB recovery ──
  @override
  String get dbRecoveryTitle => 'Database corrupted';
  @override
  String get dbCorruptedText =>
      'The local sync database is corrupted and cannot be used.';
  @override
  String get dbRecoveryDescription =>
      'This can happen after a crash or an interrupted write. Resetting the '
      'database will delete local cached data — your files and server data are '
      'not affected. After reset, the plugin will reload and re-sync from the '
      'server.';
  @override
  String get resetDatabase => 'Reset database';

  // ── Status bar / floating pill ──
  @override
  String labelUp(int completed, int total) => 'up $completed/$total';
  @override
  String labelDown(int completed, int total) => 'down $completed/$total';
  @override
  String labelRepair(int completed, int total) => 'repair $completed/$total';
  @override
  String get overlaySettings => 'settings';
  @override
  String tipUploading(int completed, int total) =>
      'Rhyolite Sync: uploading $completed of $total files';
  @override
  String tipDownloading(int completed, int total) =>
      'Rhyolite Sync: downloading $completed of $total files';
  @override
  String tipRepairing(int completed, int total) =>
      'Rhyolite Sync: repairing $completed of $total files — rebuilding sync '
      'state, this can take a while';
  @override
  String get tipStopped => 'Rhyolite Sync: stopped';
  @override
  String get tipOffline => 'Rhyolite Sync: offline — can’t reach server, retrying';
  @override
  String get tipConnecting => 'Rhyolite Sync: connecting…';
  @override
  String get tipConnected => 'Rhyolite Sync: connected';
  @override
  String get tipUploadingChanges => 'Rhyolite Sync: uploading changes';
  @override
  String get tipDownloadingChanges => 'Rhyolite Sync: downloading changes';
  @override
  String get tipUploadingInitial => 'Rhyolite Sync: uploading initial files';
  @override
  String get tipDownloadingFiles => 'Rhyolite Sync: downloading files';
  @override
  String get tipRepairingVault =>
      'Rhyolite Sync: repairing vault — rebuilding sync state';
  @override
  String get tipError => 'Rhyolite Sync: error — tap to open settings';
  @override
  String get tipAuthExpired =>
      'Rhyolite Sync: session expired — tap to open settings';
  @override
  String get tipSubExpired =>
      'Rhyolite Sync: subscription expired — tap to open settings';
  @override
  String get tipSyncingSettings => 'Rhyolite Sync: syncing settings';

  // ── Commands ──
  @override
  String get cmdSyncNow => 'Sync now';
  @override
  String get cmdSyncSettingsNow => 'Sync settings now (.obsidian)';
  @override
  String get cmdCleanupStorage => 'Clean up storage (history + blobs)';
  @override
  String get cmdManageDevices => 'Manage sync devices';
  @override
  String get cmdReclaimOrphans => 'Reclaim orphaned blobs';
  @override
  String get cmdConfigureSelfHost => 'Configure self-host server';
  @override
  String get cmdShowHistory => 'Show version history for current file';
  @override
  String get cmdRestoreBackup => 'Restore from backup';

  // ── Payment activation ──
  @override
  String get activatingSubscription => 'Activating subscription…';
  @override
  String get confirmingPayment => 'Please wait while we confirm your payment.';
  @override
  String get checking => 'Checking…';
  @override
  String get subscriptionNowActive =>
      'Your subscription is now active. Sync will start shortly.';
  @override
  String get gotIt => 'Got it';
  @override
  String get paymentNotConfirmed => 'Payment not confirmed';
  @override
  String get paymentNotConfirmedBody =>
      'We could not confirm your payment within 5 minutes. If you completed the '
      'payment, please restart Obsidian. If the issue persists, contact support.';
}
