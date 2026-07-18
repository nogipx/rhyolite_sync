/// All user-facing plugin strings, one member per string.
///
/// English ([EnStrings]) is the reference; every locale MUST implement every
/// member, so a forgotten translation is a COMPILE error (not a runtime miss).
/// Parameterised strings are methods; plain ones are getters. Grouped by feature
/// with `// ── section ──` markers — keep En/Ru in the same order.
abstract class AppStrings {
  const AppStrings();

  // ── Common ──────────────────────────────────────────────────────────────
  String get cancel;
  String get close;
  String get delete;

  // ── Setup / passphrase ───────────────────────────────────────────────────
  String get setupDescription;
  String get enterPassphrase;
  String get confirmPassphrase;
  String get showPassphrase;
  String get rememberOnThisDevice;
  String get rememberKeyDescription;
  String get derivingKey;
  String get passphraseEmpty;
  String get passphraseTooWeak;
  String get passphrasesDoNotMatch;
  String get setUpEncryption;
  String get vaultPassphrase;
  String get incorrectPassphrase;
  String get unlock;

  // ── Vault picker ─────────────────────────────────────────────────────────
  String get selectVault;
  String get noVaultsFound;
  String get connect;
  String vaultDeleted(String name);
  String deleteVaultFailed(Object error);
  String get planSingleVault;
  String planVaultLimit(int max);
  String get createNewVault;
  String get vaultNamePlaceholder;
  String get createVault;
  String get vaultNameEmpty;
  String deleteVaultTitle(String name);
  String get deleteVaultBody;
  String get typeVaultNameToConfirm;
  String get nameDoesNotMatch;
  String get deletePermanently;

  // ── Backups / restore points ────────────────────────────────────────────
  String get backupsUnavailable;
  String backupsLoadFailed(Object error);
  String get backupsTitle;
  String get backupsDescription;
  String get createRestorePointNow;
  String get noRestorePointsYet;
  String restorePointLine(String when, int files);
  String get details;
  String get restoreAllAction;
  String get creatingRestorePoint;
  String get notConnectedNoCapture;
  String restorePointCreated(int files);
  String captureFailed(Object error);
  String get restorePointDeleted;
  String get restorePointNotFound;
  String deleteRestorePointFailed(Object error);
  String restoreAllTitle(String when);
  String get restoreAllConfirmBody;
  String get restoreAllConfirm;
  String get restoring;
  String get restoreUnavailableNotConnected;
  String restoredFilesCount(int n);
  String unchangedCount(int n);
  String errorsCount(int n);
  String restoreFailed(Object error);

  // ── Storage cleanup / reclaim ────────────────────────────────────────────
  String get storageSweepUnavailable;
  String get scanningStorage;
  String storageScanFailed(Object error);
  String get storageSweepNotSupported;
  String get reclaimStorageTitle;
  String get reclaimStorageDescription;
  String get totalBlobs;
  String get orphanedBlobsReclaimable;
  String get deletedMarkersReclaimable;
  String markersOfTotal(int stable, int total);
  String get nothingToReclaim;
  String reclaimedBlobs(int n, String bytes);
  String reclaimedMarkers(int n);
  String reclaimedSummary(String parts);
  String reclaimFailed(Object error);
  String get reclaimVerb;
  String markersCount(int n);

  // ── Storage overview ─────────────────────────────────────────────────────
  String get storageOverviewUnavailable;
  String get storageOverviewTitle;
  String get contentThisDevice;
  String get notSyncedYet;
  String get files;
  String get contentSize;
  String get uniqueBlobs;
  String get conflicts;
  String get deletedTombstoned;
  String get historyServer;
  String get couldNotReadHistory;
  String get versionsKept;
  String get range;
  String get devices;
  String get noDevicesReported;
  String get thisDeviceSuffix;
  String behindBy(int n);
  String deviceLine(String name, String suffix, String ago, String behind);
  String get justNow;
  String minutesAgo(int m);
  String hoursAgo(int h);
  String daysAgo(int d);
  String get restorePointsServer;
  String get restorePointsUnavailableText;
  String get restorePointsNoneYet;
  String get kept;
  String get restorePointsHoldBlobs;
  String get cleanUpStorage;
  String get reclaimOrphans;
  String get manageDevices;
  String get restorePointsAction;
  String get clearRestorePointsAction;
  String get clearRestorePointsTitle;
  String clearRestorePointsBody(int count);
  String get clearVerb;
  String get notConnectedNothingCleared;
  String clearedRestorePoints(int n);
  String clearRestorePointsFailed(Object error);

  // ── Storage cleanup (history) ────────────────────────────────────────────
  String get storageCleanupUnavailable;
  String cleanupScanFailed(Object error);
  String nothingToCleanOlderThan(int days);
  String cleanupIncomplete(int deleted, int failed);
  String cleanupDone(int events, int blobs);
  String cleanupFailed(Object error);
  String get storageCleanupTitle;
  String get storageCleanupDescription;
  String get deleteEventsOlderThanLabel;
  String daysMustBeBetween(int min, int max);
  String get scanAction;
  String get confirmCleanupTitle;
  String eventsToDelete(int n, int total);
  String orphanBlobsToDelete(int n);
  String oldestEntryToDelete(String when);
  String newestEntryToDelete(String when);
  String oldestEntryRemaining(String when);
  String get deviceSafety;
  String get noDeviceHeadYet;
  String get ageLessThanDay;
  String cleanupDaysAgo(int n);
  String get activeTag;
  String get staleTag;
  String deviceHeadLine(String tag, String id8, int head, String age);
  String protectedByMinHead(int minHead, int events);
  String get noActiveDevicesForCleanup;
  String get cannotBeUndone;

  // ── Restore point inspect / diff ─────────────────────────────────────────
  String inspectFailed(Object error);
  String get notConnectedCannotInspect;
  String restorePointTitle(String when);
  String inspectSummary(int changed, int toRestore, int identical);
  String deletionSuffix(int n);
  String get noChangesVsCurrent;
  String get flairChanged;
  String get flairDeletedNow;
  String get flairTombstone;
  String entryIdenticalNotice(String path);
  String entryDeletedInBackupNotice(String path);
  String diffTitle(String path);
  String restoresTitle(String path);
  String binaryWouldRestore(int bytes);
  String get binaryContentDiffers;
  String get restoreThisFile;
  String get restoreThisVersion;
  String loadingPath(String path);
  String backupContentUnavailable(String path);
  String couldNotLoadPath(String path, Object error);
  String get restoringAddsContent;
  String get restoringWouldApply;
  String get tooManyChangesToDiff;
  String get noDifferencesOnDisk;
  String restoringPath(String path);
  String fileRestored(String path);
  String couldNotRestorePath(String path);

  // ── Device management ────────────────────────────────────────────────────
  String get deviceMgmtUnavailable;
  String failedToLoadDevices(Object error);
  String get syncDevicesTitle;
  String deviceMgmtDescription(int count);
  String forgotDevice(String name);
  String deviceAlreadyGone(String name);
  String couldNotForget(String name, Object error);
  String seenLabel(String ago);
  String behindPlain(int n);
  String get forget;

  // ── File version history ─────────────────────────────────────────────────
  String get noFileOpen;
  String get versionHistoryUnavailable;
  String failedToLoadHistory(String path, Object error);
  String noHistoryFor(String path);
  String get versionHistoryTitle;
  String versionsCountHint(int n);
  String get versionPreviewTitle;
  String versionPreviewSubtitle(String path, String when);
  String get blobNoLongerAvailable;
  String get back;
  String get fileDoesNotExistWillRecreate;
  String moreCharacters(int n);
  String get noDifferencesMatchesDisk;
  String binaryContentPreview(String size);
  String restoredFromVersion(String path, String when);
  String get restoreVerb;

  // ── Settings: common verbs ───────────────────────────────────────────────
  String get save;
  String get configure;
  String get disconnect;
  String get download;
  String get reupload;
  String get ok;

  // ── Settings: auth ───────────────────────────────────────────────────────
  String get authStatus;
  String signedInAs(String email);
  String get signOut;
  String get authentication;
  String get signIn;
  String get signInDescription;
  String get signInButton;
  String get signedIn;
  String signInFailed(Object error);
  String get signInLinkWrongDevice;
  String couldNotOpenAccountPage(Object error);

  // ── Settings: vault ──────────────────────────────────────────────────────
  String get vaultSection;
  String get disconnectVaultName;
  String get disconnectVaultDescription;
  String get connectVaultName;
  String get connectVaultDescription;
  String get connectVaultButton;
  String get disconnectVaultTitle;
  String disconnectFromVault(String name);
  String get disconnectVaultBody;

  // ── Settings: troubleshooting ────────────────────────────────────────────
  String get troubleshooting;
  String get reuploadName;
  String get reuploadDescription;
  String get reuploadConfirmTitle;
  String get reuploadConfirmBody;
  String get downloadServerName;
  String get downloadServerDescription;
  String get downloadServerConfirmTitle;
  String get downloadServerConfirmBody;
  String get repairName;
  String get repairDescription;
  String get repairButton;
  String get repairConfirmTitle;
  String get repairConfirmBody;
  String get repairFinished;
  String repairFailed(Object error);

  // ── Settings: self-host ──────────────────────────────────────────────────
  String get selfHostSection;
  String get selfHostEnabledName;
  String get selfHostName;
  String selfHostServer(String url);
  String get selfHostDescription;
  String get selfHostReconfigure;
  String get selfHostEnable;
  String get applyingSelfHost;

  // ── Settings: subscription ───────────────────────────────────────────────
  String get subscriptionSection;
  String activeUntil(String date);
  String get subscriptionActive;
  String get manageSubscription;
  String get manageSubscriptionDescription;
  String get manageOnSite;
  String get subscribe;
  String get subscribeDescription;
  String get alreadyPaid;
  String get alreadyPaidDescription;
  String get restoreSubscription;
  String get checkingSubscription;
  String get contactingServer;
  String get subscriptionActivated;
  String get subscriptionRestored;
  String get noSubscriptionFound;
  String get noPaymentFound;

  // ── Settings: diagnostics + file filter ──────────────────────────────────
  String get diagnosticsSection;
  String get logCollectorUrl;
  String get logCollectorDescription;
  String get sendLogsToCollector;
  String get sendLogsDescription;
  String get fileTypesSection;
  String get dontSyncExtensions;
  String get dontSyncDescription;

  // ── Settings: external storage ───────────────────────────────────────────
  String get externalStorageSection;
  String get connected;
  String get disconnectStorage;
  String get disconnectStorageDescription;
  String get externalStorageDisconnected;
  String couldNotDisconnectStorage(Object error);
  String get bringYourOwnStorage;
  String get bringYourOwnDescription;
  String get s3Compatible;
  String get s3Description;
  String get webdavName;
  String get webdavDescription;
  String externalStorageConnected(String kind);
  String couldNotSaveStorage(Object error);
  String get s3ConfigTitle;
  String get webdavConfigTitle;
  String get endpoint;
  String get bucket;
  String get accessKey;
  String get secretKey;
  String get region;
  String get username;
  String get password;

  // ── Settings: settings-sync + storage usage ──────────────────────────────
  String get reuploadSettingsTitle;
  String get reuploadSettingsBody;
  String get settingsReuploadFinished;
  String settingsReuploadFailed(Object error);
  String get downloadSettingsTitle;
  String get downloadSettingsBody;
  String get settingsDownloadFinished;
  String settingsDownloadFailed(Object error);
  String get settingsSyncSection;
  String get syncSettingsName;
  String get syncSettingsDescription;
  String get reuploadSettingsRowName;
  String get reuploadSettingsRowDesc;
  String get downloadSettingsRowName;
  String get downloadSettingsRowDesc;
  String get settingsCatAppSettings;
  String get settingsCatAppSettingsDesc;
  String get settingsCatAppearance;
  String get settingsCatAppearanceDesc;
  String get settingsCatHotkeys;
  String get settingsCatHotkeysDesc;
  String get settingsCatCorePluginsEnabled;
  String get settingsCatCorePluginsEnabledDesc;
  String get settingsCatCorePluginSettings;
  String get settingsCatCorePluginSettingsDesc;
  String get settingsCatCommunityPluginsEnabled;
  String get settingsCatCommunityPluginsEnabledDesc;
  String get settingsCatCommunityPluginSettings;
  String get settingsCatCommunityPluginSettingsDesc;
  String get settingsCatThemesSnippets;
  String get settingsCatThemesSnippetsDesc;
  String get storageSection;

  // ── Sync panel ───────────────────────────────────────────────────────────
  String get endToEndEncrypted;
  String syncedAgo(String ago);
  String get notConnected;
  String get panelStorageLabel;
  String get vaultSizeLabel;
  String get settingsSizeLabel;
  String get storageDetails;
  String get refreshStorageUsage;
  String get textMergesLine;
  String uploadDownloadReport(int up, int down);
  String get resumeSync;
  String get pauseSync;
  String get settingsButton;
  String activeTransfers(int n);
  String get recent;
  String get browseVersions;
  String tooLargeToSync(int n);
  String get tooLargeHint;
  String blockedMeta(String size, String limit);
  String andMore(int n);
  String conflictsLostContent(int n);
  String storageMeterTitle(String plan);
  String get syncStopped;
  String get connecting;
  String get reconnecting;
  String get offlineCantReach;
  String get upToDate;
  String get pendingChanges;
  String syncingProgress(int completed, int total);
  String get syncingEllipsis;
  String get syncErrorStatus;
  String get sessionExpiredStatus;
  String get subscriptionRequiredStatus;
  String get pausedStatus;

  // ── Self-host modal ──────────────────────────────────────────────────────
  String get selfHostModalTitle;
  String get selfHostModalDescription;
  String get serverUrl;
  String get accessToken;
  String get enableAndSave;
  String get serverUrlTokenRequired;
  String get disable;

  // ── DB recovery ──────────────────────────────────────────────────────────
  String get dbRecoveryTitle;
  String get dbCorruptedText;
  String get dbRecoveryDescription;
  String get resetDatabase;

  // ── Status bar / floating pill ───────────────────────────────────────────
  String labelUp(int completed, int total);
  String labelDown(int completed, int total);
  String labelRepair(int completed, int total);
  String get overlaySettings;
  String tipUploading(int completed, int total);
  String tipDownloading(int completed, int total);
  String tipRepairing(int completed, int total);
  String get tipStopped;
  String get tipOffline;
  String get tipConnecting;
  String get tipConnected;
  String get tipUploadingChanges;
  String get tipDownloadingChanges;
  String get tipUploadingInitial;
  String get tipDownloadingFiles;
  String get tipRepairingVault;
  String get tipError;
  String get tipAuthExpired;
  String get tipSubExpired;
  String get tipSyncingSettings;

  // ── Commands ─────────────────────────────────────────────────────────────
  String get cmdSyncNow;
  String get cmdSyncSettingsNow;
  String get cmdCleanupStorage;
  String get cmdManageDevices;
  String get cmdReclaimOrphans;
  String get cmdConfigureSelfHost;
  String get cmdShowHistory;
  String get cmdRestoreBackup;

  // ── Payment activation ───────────────────────────────────────────────────
  String get activatingSubscription;
  String get confirmingPayment;
  String get checking;
  String get subscriptionNowActive;
  String get gotIt;
  String get paymentNotConfirmed;
  String get paymentNotConfirmedBody;
}
