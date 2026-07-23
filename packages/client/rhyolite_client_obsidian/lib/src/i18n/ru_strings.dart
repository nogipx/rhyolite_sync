import 'app_strings.dart';

/// Russian strings.
class RuStrings extends AppStrings {
  const RuStrings();

  // ── Common ──
  @override
  String get cancel => 'Отмена';
  @override
  String get close => 'Закрыть';
  @override
  String get delete => 'Удалить';

  // ── Setup / passphrase ──
  @override
  String get setupDescription =>
      'Настройте сквозное шифрование для этого хранилища.';
  @override
  String get enterPassphrase => 'Введите пароль';
  @override
  String get confirmPassphrase => 'Повторите пароль';
  @override
  String get showPassphrase => 'Показать пароль';
  @override
  String get rememberOnThisDevice => 'Запомнить на этом устройстве';
  @override
  String get rememberKeyDescription =>
      'Хранит производный ключ в системном хранилище, чтобы не спрашивать пароль '
      'при каждом запуске.';
  @override
  String get derivingKey => 'Вычисляю ключ, подождите…';
  @override
  String get passphraseEmpty => 'Пароль не может быть пустым.';
  @override
  String get passphraseTooWeak => 'Слишком слабый пароль.';
  @override
  String get passphrasesDoNotMatch => 'Пароли не совпадают.';
  @override
  String get setUpEncryption => 'Настроить шифрование';
  @override
  String get vaultPassphrase => 'Пароль хранилища';
  @override
  String get incorrectPassphrase => 'Неверный пароль. Попробуйте ещё раз.';
  @override
  String get unlock => 'Разблокировать';

  // ── Vault picker ──
  @override
  String get selectVault => 'Выбор хранилища';
  @override
  String get noVaultsFound => 'Хранилищ не найдено. Создайте ниже.';
  @override
  String get connect => 'Подключить';
  @override
  String vaultDeleted(String name) => 'Хранилище «$name» удалено.';
  @override
  String deleteVaultFailed(Object error) => 'Не удалось удалить: $error';
  @override
  String get planSingleVault =>
      'Ваш план включает одно хранилище. Обновите план, чтобы добавить ещё.';
  @override
  String planVaultLimit(int max) =>
      'Достигнут лимит хранилищ вашего плана ($max). Обновите план, чтобы добавить ещё.';
  @override
  String get createNewVault => 'Создать новое хранилище:';
  @override
  String get vaultNamePlaceholder => 'Название хранилища';
  @override
  String get createVault => '+ Создать';
  @override
  String get vaultNameEmpty => 'Название хранилища не может быть пустым.';
  @override
  String deleteVaultTitle(String name) => 'Удалить хранилище «$name»?';
  @override
  String get deleteVaultBody =>
      'Это безвозвратно удалит все данные этого хранилища с сервера '
      '(файлы, историю, блобы). Локальные файлы заметок на диске НЕ удаляются. '
      'Если хранилище использовало ваш S3/WebDAV, очистите бакет отдельно. '
      'Отменить нельзя.';
  @override
  String get typeVaultNameToConfirm =>
      'Введите название хранилища для подтверждения:';
  @override
  String get nameDoesNotMatch => 'Название не совпадает.';
  @override
  String get deletePermanently => 'Удалить навсегда';

  // ── Backups / restore points ──
  @override
  String get backupsUnavailable =>
      'Бэкапы недоступны — движок не подключён';
  @override
  String backupsLoadFailed(Object error) =>
      'Не удалось загрузить бэкапы: $error';
  @override
  String get backupsTitle => 'Бэкапы хранилища';
  @override
  String get backupsDescription =>
      'Восстановление файлов на место из снимка — идентичные файлы не трогаются, '
      'а каждое изменение обратимо через историю файла.';
  @override
  String get createRestorePointNow => 'Создать точку восстановления';
  @override
  String get noRestorePointsYet =>
      'Точек восстановления пока нет. На Pro они создаются ежедневно (хранятся 7 последних).';
  @override
  String restorePointLine(String when, int files) => '$when  ·  файлов: $files';
  @override
  String get details => 'Подробнее';
  @override
  String get restoreAllAction => 'Восстановить всё…';
  @override
  String get creatingRestorePoint => 'Создаю точку восстановления …';
  @override
  String get notConnectedNoCapture =>
      'Нет подключения — точка не создана.';
  @override
  String restorePointCreated(int files) =>
      'Точка восстановления создана (файлов: $files).';
  @override
  String captureFailed(Object error) =>
      'Не удалось создать точку восстановления: $error';
  @override
  String get restorePointDeleted => 'Точка восстановления удалена.';
  @override
  String get restorePointNotFound => 'Точка восстановления не найдена.';
  @override
  String deleteRestorePointFailed(Object error) =>
      'Не удалось удалить точку восстановления: $error';
  @override
  String restoreAllTitle(String when) => 'Восстановить всё · $when';
  @override
  String get restoreAllConfirmBody =>
      'Перезаписать текущие файлы этой точкой везде, где они различаются. '
      'Идентичные сейчас файлы не трогаются, ничего не удаляется. Каждое '
      'изменение синхронизируется и обратимо через историю файла.';
  @override
  String get restoreAllConfirm => 'Восстановить всё';
  @override
  String get restoring => 'Восстанавливаю …';
  @override
  String get restoreUnavailableNotConnected =>
      'Восстановление недоступно — нет подключения.';
  @override
  String restoredFilesCount(int n) => 'Восстановлено файлов: $n';
  @override
  String unchangedCount(int n) => 'без изменений: $n';
  @override
  String errorsCount(int n) => 'ошибок: $n';
  @override
  String restoreFailed(Object error) => 'Восстановление не удалось: $error';

  // ── Storage cleanup / reclaim ──
  @override
  String get storageSweepUnavailable =>
      'Очистка хранилища недоступна — движок не подключён';
  @override
  String get scanningStorage => 'Сканирую хранилище…';
  @override
  String storageScanFailed(Object error) =>
      'Сканирование хранилища не удалось: $error';
  @override
  String get storageSweepNotSupported =>
      'Сервер пока не поддерживает очистку хранилища';
  @override
  String get reclaimStorageTitle => 'Освободить хранилище';
  @override
  String get reclaimStorageDescription =>
      'Серверный балласт: осиротевшие блобы (неудачные загрузки / остатки старой '
      'очистки) и маркеры удалённых файлов, которые уже увидели все устройства. '
      'Содержимое остаётся восстановимым через историю / точки восстановления.';
  @override
  String get totalBlobs => 'Всего блобов';
  @override
  String get orphanedBlobsReclaimable => 'Осиротевшие блобы (освобождаемые)';
  @override
  String get deletedMarkersReclaimable =>
      'Маркеры удалённых файлов (освобождаемые)';
  @override
  String markersOfTotal(int stable, int total) => '$stable из $total';
  @override
  String get nothingToReclaim => 'Освобождать нечего.';
  @override
  String reclaimedBlobs(int n, String bytes) => 'блобов: $n ($bytes)';
  @override
  String reclaimedMarkers(int n) => 'маркеров удаления: $n';
  @override
  String reclaimedSummary(String parts) => 'Освобождено: $parts.';
  @override
  String reclaimFailed(Object error) => 'Освобождение не удалось: $error';
  @override
  String get reclaimVerb => 'Освободить';
  @override
  String markersCount(int n) => 'маркеров: $n';

  // ── Storage overview ──
  @override
  String get storageOverviewUnavailable =>
      'Обзор хранилища недоступен — движок не подключён';
  @override
  String get storageOverviewTitle => 'Обзор хранилища';
  @override
  String get contentThisDevice => 'Содержимое (это устройство)';
  @override
  String get notSyncedYet => 'Ещё не синхронизировано.';
  @override
  String get files => 'Файлов';
  @override
  String get contentSize => 'Размер содержимого';
  @override
  String get uniqueBlobs => 'Уникальных блобов';
  @override
  String get conflicts => 'Конфликтов';
  @override
  String get deletedTombstoned => 'Удалено (tombstone)';
  @override
  String get historyServer => 'История (сервер)';
  @override
  String get couldNotReadHistory =>
      'Не удалось прочитать историю (нет подключения?).';
  @override
  String get versionsKept => 'Хранится версий';
  @override
  String get range => 'Диапазон';
  @override
  String get devices => 'Устройства';
  @override
  String get noDevicesReported => 'Устройства ещё не отметились.';
  @override
  String get thisDeviceSuffix => '  (это устройство)';
  @override
  String behindBy(int n) => '  ·  отстаёт на $n';
  @override
  String deviceLine(String name, String suffix, String ago, String behind) =>
      '$name$suffix  —  видели $ago$behind';
  @override
  String get justNow => 'только что';
  @override
  String minutesAgo(int m) => '$m мин назад';
  @override
  String hoursAgo(int h) => '$h ч назад';
  @override
  String daysAgo(int d) => '$d дн назад';
  @override
  String get restorePointsServer => 'Точки восстановления (сервер)';
  @override
  String get restorePointsUnavailableText =>
      'Недоступно — сервер пока не поддерживает точки восстановления (обновите '
      'сервер, или хранилище офлайн).';
  @override
  String get restorePointsNoneYet =>
      'Пока нет. Откройте «Точки восстановления…», чтобы создать; на Pro они '
      'создаются ежедневно (хранятся 7 последних).';
  @override
  String get kept => 'Хранится';
  @override
  String get restorePointsHoldBlobs =>
      'Они удерживают старые блобы, поэтому часть места не освободится, пока они '
      'не устареют (или вы их не очистите).';
  @override
  String get cleanUpStorage => 'Очистить хранилище…';
  @override
  String get reclaimOrphans => 'Освободить сироты…';
  @override
  String get manageDevices => 'Устройства…';
  @override
  String get restorePointsAction => 'Точки восстановления…';
  @override
  String get clearRestorePointsAction => 'Очистить точки восстановления…';
  @override
  String get clearRestorePointsTitle => 'Очистить точки восстановления';
  @override
  String clearRestorePointsBody(int count) =>
      'Удалить все точки восстановления ($count)? Вернуться к более раннему '
      'состоянию будет нельзя. Это освободит удерживаемые блобы — затем '
      'запустите «Освободить сироты», чтобы реально вернуть место.';
  @override
  String get clearVerb => 'Очистить';
  @override
  String get notConnectedNothingCleared => 'Нет подключения — ничего не очищено.';
  @override
  String clearedRestorePoints(int n) =>
      'Очищено точек: $n. Запустите «Освободить сироты», чтобы вернуть место.';
  @override
  String clearRestorePointsFailed(Object error) =>
      'Не удалось очистить точки восстановления: $error';

  // ── Storage cleanup (history) ──
  @override
  String get storageCleanupUnavailable =>
      'Очистка хранилища недоступна — движок не подключён';
  @override
  String cleanupScanFailed(Object error) =>
      'Сканирование очистки не удалось: $error';
  @override
  String nothingToCleanOlderThan(int days) =>
      'Нечего очищать старше $days дн.';
  @override
  String cleanupIncomplete(int deleted, int failed) =>
      'Очистка не завершена: удалено блобов $deleted, ошибок $failed — история '
      'сохранена, чтобы повтор мог продолжить.';
  @override
  String cleanupDone(int events, int blobs) =>
      'Очистка завершена: удалено записей истории $events и блобов $blobs.';
  @override
  String cleanupFailed(Object error) => 'Очистка хранилища не удалась: $error';
  @override
  String get storageCleanupTitle => 'Очистка хранилища';
  @override
  String get storageCleanupDescription =>
      'Безвозвратно удаляет записи истории старше выбранного числа дней. Блобы, '
      'на которые ссылаются только эти записи, тоже удаляются из хранилища блобов.';
  @override
  String get deleteEventsOlderThanLabel =>
      'Удалять записи старше (дней) — 0, чтобы очистить всю историю, которую все '
      'активные устройства уже синхронизировали:';
  @override
  String daysMustBeBetween(int min, int max) =>
      'Число дней должно быть от $min до $max.';
  @override
  String get scanAction => 'Сканировать';
  @override
  String get confirmCleanupTitle => 'Подтвердите очистку';
  @override
  String eventsToDelete(int n, int total) => 'Записей к удалению: $n из $total';
  @override
  String orphanBlobsToDelete(int n) => 'Сиротских блобов к удалению: $n';
  @override
  String oldestEntryToDelete(String when) => 'Самая старая запись к удалению: $when';
  @override
  String newestEntryToDelete(String when) => 'Самая новая запись к удалению: $when';
  @override
  String oldestEntryRemaining(String when) => 'Самая старая из оставшихся: $when';
  @override
  String get deviceSafety => 'Защита по устройствам:';
  @override
  String get noDeviceHeadYet =>
      'Ни одно устройство ещё не сообщило свою позицию истории. От удаления '
      'защищает только порог по возрасту.';
  @override
  String get ageLessThanDay => '<1 дня назад';
  @override
  String cleanupDaysAgo(int n) => '$n дн назад';
  @override
  String get activeTag => '[активно]';
  @override
  String get staleTag => '[устарело]';
  @override
  String deviceHeadLine(String tag, String id8, int head, String age) =>
      '$tag  $id8…  позиция=$head  ($age)';
  @override
  String protectedByMinHead(int minHead, int events) =>
      'Защищено минимальной позицией $minHead: записей ($events) старше порога '
      'можно было бы удалить, но они сохранены, т.к. хотя бы одно активное '
      'устройство их ещё не видело.';
  @override
  String get noActiveDevicesForCleanup =>
      'Нет устройств, считающихся активными (замечены за последние 30 дней). '
      'Применяется только порог по возрасту.';
  @override
  String get cannotBeUndone => 'Отменить нельзя.';

  // ── Restore point inspect / diff ──
  @override
  String inspectFailed(Object error) =>
      'Не удалось изучить точку восстановления: $error';
  @override
  String get notConnectedCannotInspect => 'Нет подключения — изучить нельзя.';
  @override
  String restorePointTitle(String when) => 'Точка восстановления · $when';
  @override
  String inspectSummary(int changed, int toRestore, int identical) =>
      'изменено: $changed · восстановит (удалено): $toRestore · '
      'без изменений: $identical';
  @override
  String deletionSuffix(int n) => ' · удалений: $n';
  @override
  String get noChangesVsCurrent =>
      'Отличий от текущего хранилища нет — все файлы идентичны.';
  @override
  String get flairChanged => 'изменён';
  @override
  String get flairDeletedNow => 'удалён сейчас';
  @override
  String get flairTombstone => 'tombstone';
  @override
  String entryIdenticalNotice(String path) =>
      '$path: идентичен текущему — ничего не изменится.';
  @override
  String entryDeletedInBackupNotice(String path) =>
      '$path: был удалён в этой точке восстановления.';
  @override
  String diffTitle(String path) => 'Дифф · $path';
  @override
  String restoresTitle(String path) => 'Восстановит · $path';
  @override
  String binaryWouldRestore(int bytes) =>
      'Бинарный файл — будет восстановлен ($bytes байт).';
  @override
  String get binaryContentDiffers =>
      'Бинарный файл — содержимое отличается (не показывается как текст).';
  @override
  String get restoreThisFile => 'Восстановить этот файл';
  @override
  String get restoreThisVersion => 'Восстановить эту версию';
  @override
  String loadingPath(String path) => 'Загружаю $path …';
  @override
  String backupContentUnavailable(String path) =>
      'Содержимое бэкапа для $path недоступно.';
  @override
  String couldNotLoadPath(String path, Object error) =>
      'Не удалось загрузить $path: $error';
  @override
  String get restoringAddsContent =>
      'Удалён из хранилища с тех пор — восстановление добавит это содержимое:';
  @override
  String get restoringWouldApply =>
      'Восстановление применит эти изменения (- текущее, + бэкап):';
  @override
  String get tooManyChangesToDiff =>
      'Слишком много изменений для диффа — восстановите, чтобы посмотреть.';
  @override
  String get noDifferencesOnDisk => 'Отличий нет — идентично файлу на диске.';
  @override
  String restoringPath(String path) => 'Восстанавливаю $path …';
  @override
  String fileRestored(String path) =>
      '$path восстановлен (обратимо через историю).';
  @override
  String couldNotRestorePath(String path) =>
      'Не удалось восстановить $path — нет подключения или блоб потерян.';

  // ── Device management ──
  @override
  String get deviceMgmtUnavailable =>
      'Управление устройствами недоступно — движок не подключён';
  @override
  String failedToLoadDevices(Object error) =>
      'Не удалось загрузить устройства: $error';
  @override
  String get syncDevicesTitle => 'Устройства синхронизации';
  @override
  String deviceMgmtDescription(int count) =>
      'Это хранилище синхронизировали устройств: $count. Если забыть устройство, '
      'которым вы больше не пользуетесь, очистка сможет вернуть историю, которую '
      'оно удерживало. Содержимое при этом не удаляется.';
  @override
  String forgotDevice(String name) =>
      'Устройство $name забыто. Запустите очистку, чтобы вернуть удержанную историю.';
  @override
  String deviceAlreadyGone(String name) => 'Устройство $name уже отсутствовало.';
  @override
  String couldNotForget(String name, Object error) =>
      'Не удалось забыть $name: $error';
  @override
  String seenLabel(String ago) => 'видели $ago';
  @override
  String behindPlain(int n) => 'отстаёт на $n';
  @override
  String get forget => 'Забыть';

  // ── File version history ──
  @override
  String get noFileOpen => 'Нет открытого файла';
  @override
  String get versionHistoryUnavailable =>
      'История версий недоступна — движок не подключён';
  @override
  String failedToLoadHistory(String path, Object error) =>
      'Не удалось загрузить историю для $path: $error';
  @override
  String noHistoryFor(String path) => 'Истории для $path нет';
  @override
  String get versionHistoryTitle => 'История версий';
  @override
  String versionsCountHint(int n) =>
      'версий: $n, свежие сверху. Выберите одну для просмотра и восстановления.';
  @override
  String get versionPreviewTitle => 'Просмотр версии';
  @override
  String versionPreviewSubtitle(String path, String when) =>
      '$path  ·  $when  ·  vs текущее';
  @override
  String get blobNoLongerAvailable =>
      'Блоб этой версии больше недоступен — возможно, он удалён при очистке или '
      'никогда не скачивался на это устройство.';
  @override
  String get back => 'Назад';
  @override
  String get fileDoesNotExistWillRecreate =>
      'Этого файла сейчас нет на диске — восстановление создаст его заново.';
  @override
  String moreCharacters(int n) => '…(ещё $n символов)';
  @override
  String get noDifferencesMatchesDisk =>
      'Отличий нет — эта версия совпадает с файлом на диске.';
  @override
  String binaryContentPreview(String size) =>
      'Бинарное содержимое ($size). Предпросмотр невозможен, но восстановление '
      'запишет исходные байты.';
  @override
  String restoredFromVersion(String path, String when) =>
      'Восстановлено $path из $when.';
  @override
  String get restoreVerb => 'Восстановить';

  // ── Settings: common verbs ──
  @override
  String get save => 'Сохранить';
  @override
  String get configure => 'Настроить';
  @override
  String get disconnect => 'Отключить';
  @override
  String get download => 'Скачать';
  @override
  String get reupload => 'Перезалить';
  @override
  String get ok => 'OK';

  // ── Settings: auth ──
  @override
  String get authStatus => 'Статус входа';
  @override
  String signedInAs(String email) =>
      'Вы вошли как $email. Нажмите, чтобы выйти.';
  @override
  String get signOut => 'Выйти';
  @override
  String get authentication => 'Аутентификация';
  @override
  String get signIn => 'Вход';
  @override
  String get signInDescription =>
      'Войдите или создайте аккаунт в браузере. Rhyolite откроет веб-вход и '
      'вернёт вас сюда автоматически.';
  @override
  String get signInButton => 'Войти';
  @override
  String get signedIn => 'Вход выполнен';
  @override
  String signInFailed(Object error) => 'Вход не удался: $error';
  @override
  String get signInLinkWrongDevice =>
      'Эта ссылка входа не для этого устройства. Попробуйте снова.';
  @override
  String couldNotOpenAccountPage(Object error) =>
      'Не удалось открыть страницу аккаунта: $error';

  // ── Settings: vault ──
  @override
  String get vaultSection => 'Хранилище';
  @override
  String get disconnectVaultName => 'Отключить хранилище';
  @override
  String get disconnectVaultDescription =>
      'Остановить синхронизацию и забыть это хранилище на устройстве. Данные на '
      'сервере не затрагиваются.';
  @override
  String get connectVaultName => 'Хранилище';
  @override
  String get connectVaultDescription =>
      'Подключитесь к существующему хранилищу или создайте новое.';
  @override
  String get connectVaultButton => 'Подключить хранилище';
  @override
  String get disconnectVaultTitle => 'Отключить хранилище?';
  @override
  String disconnectFromVault(String name) =>
      'Отключиться от «$name» на этом устройстве?';
  @override
  String get disconnectVaultBody =>
      'Синхронизация остановится. Конфиг хранилища и запомненный пароль будут '
      'удалены с этого устройства. Данные на сервере и файлы на диске не '
      'затрагиваются.';

  // ── Settings: troubleshooting ──
  @override
  String get troubleshooting => 'Решение проблем';
  @override
  String get reuploadName => 'Перезалить с этого устройства';
  @override
  String get reuploadDescription =>
      'Использовать это устройство как источник истины. История на сервере '
      'будет заменена файлами с этого устройства. Другие устройства скачают '
      'обновлённые файлы автоматически.';
  @override
  String get reuploadConfirmTitle => 'Перезалить с этого устройства?';
  @override
  String get reuploadConfirmBody =>
      'История на сервере будет заменена файлами с этого устройства. Другие '
      'устройства пересинхронизируются автоматически. Файлы не удаляются.';
  @override
  String get downloadServerName => 'Скачать с сервера';
  @override
  String get downloadServerDescription =>
      'Заменить локальные файлы серверной версией. Используйте, если файлы на '
      'этом устройстве устарели или повреждены.';
  @override
  String get downloadServerConfirmTitle => 'Скачать с сервера?';
  @override
  String get downloadServerConfirmBody =>
      'Локальные файлы будут удалены и заменены серверной версией. Это касается '
      'только этого устройства.';
  @override
  String get repairName => 'Починить состояние синхронизации';
  @override
  String get repairDescription =>
      'Пересобрать состояние синхронизации для каждой заметки из её текущего '
      'содержимого на диске и перезалить, чтобы сервер принял свежее состояние. '
      'Используйте, если заметки выглядят повреждёнными, задублированными, или '
      'синхронизация зависла. Содержимое файлов на диске не меняется.';
  @override
  String get repairButton => 'Починить';
  @override
  String get repairConfirmTitle => 'Починить состояние синхронизации?';
  @override
  String get repairConfirmBody =>
      'Каждая заметка будет пересобрана из её текущего содержимого на диске и '
      'перезалита. Для больших хранилищ это может занять время. Содержимое '
      'файлов на диске не меняется.';
  @override
  String get repairFinished => 'Починка завершена — подробности в логах.';
  @override
  String repairFailed(Object error) => 'Починка не удалась: $error';

  // ── Settings: self-host ──
  @override
  String get selfHostSection => 'Свой сервер';
  @override
  String get selfHostEnabledName => 'Свой сервер включён';
  @override
  String get selfHostName => 'Свой сервер';
  @override
  String selfHostServer(String url) => 'Сервер: $url';
  @override
  String get selfHostDescription =>
      'Синхронизация через ваш собственный сервер вместо управляемого сервиса.';
  @override
  String get selfHostReconfigure => 'Перенастроить';
  @override
  String get selfHostEnable => 'Включить свой сервер';
  @override
  String get applyingSelfHost => 'Применяю настройки своего сервера…';

  // ── Settings: subscription ──
  @override
  String get subscriptionSection => 'Подписка';
  @override
  String activeUntil(String date) => 'Активна до $date';
  @override
  String get subscriptionActive => 'Ваша подписка активна.';
  @override
  String get manageSubscription => 'Управление подпиской';
  @override
  String get manageSubscriptionDescription =>
      'Открыть страницу аккаунта в браузере (уже с входом).';
  @override
  String get manageOnSite => 'Управлять на сайте';
  @override
  String get subscribe => 'Оформить подписку';
  @override
  String get subscribeDescription =>
      'Оформите подписку на сайте, чтобы синхронизировать все устройства. '
      'Откроет страницу аккаунта в браузере, уже с входом.';
  @override
  String get alreadyPaid => 'Уже оплатили?';
  @override
  String get alreadyPaidDescription => 'Проверить, прошёл ли платёж.';
  @override
  String get restoreSubscription => 'Восстановить подписку';
  @override
  String get checkingSubscription => 'Проверяю подписку…';
  @override
  String get contactingServer => 'Связываюсь с сервером';
  @override
  String get subscriptionActivated => 'Подписка активирована!';
  @override
  String get subscriptionRestored => 'Ваша подписка успешно восстановлена.';
  @override
  String get noSubscriptionFound => 'Подписка не найдена';
  @override
  String get noPaymentFound =>
      'Завершённого платежа для вашего аккаунта не найдено. Если вы только что '
      'оплатили, подождите немного и попробуйте снова.';

  // ── Settings: diagnostics + file filter ──
  @override
  String get diagnosticsSection => 'Диагностика';
  @override
  String get logCollectorUrl => 'URL сборщика логов';
  @override
  String get logCollectorDescription =>
      'WebSocket-адрес, куда стримятся логи. Используйте wss:// — iOS молча '
      'блокирует обычный ws://.';
  @override
  String get sendLogsToCollector => 'Отправлять логи в сборщик';
  @override
  String get sendLogsDescription =>
      'По умолчанию выключено — ничего не логируется, пока не включите. Стримит '
      'отладочные логи этого устройства на адрес выше. Логи включают пути '
      'файлов, id, хэши, размеры и тайминги — но не содержимое файлов.';
  @override
  String get fileTypesSection => 'Типы файлов';
  @override
  String get dontSyncExtensions => 'Не синхронизировать эти расширения';
  @override
  String get dontSyncDescription =>
      'Список через запятую (напр. pdf, zip, mp4). Файлы с этими расширениями '
      'пропускаются только на этом устройстве — не загружаются и не скачиваются. '
      'Другие устройства не затронуты. Оставьте пустым, чтобы синхронизировать '
      'всё. Возврат типа скачает его файлы при следующей синхронизации.';
  @override
  String get forceBinaryExtensions =>
      'Синхронизировать эти расширения целиком';
  @override
  String get forceBinaryDescription =>
      'Список через запятую (напр. excalidraw, drawio). Такие файлы '
      'синхронизируются целыми снимками по правилу «последний победил», а не '
      'построчным слиянием — это верный выбор для структурных форматов '
      '(рисунки, диаграммы), которые слияние текста испортит. Общий список для '
      'всех ваших устройств. .excalidraw.md и .canvas всегда обрабатываются так. '
      'Существующие файлы переведутся при следующем изменении. Нажмите '
      '«Сохранить», чтобы применить.';
  @override
  String get forceBinarySave => 'Сохранить';
  @override
  String get forceBinarySaved =>
      'Список сохранён. Он применится на всех устройствах.';
  @override
  String forceBinarySaveFailed(Object error) =>
      'Не удалось сохранить: $error';

  // ── Settings: external storage ──
  @override
  String get externalStorageSection => 'Внешнее хранилище';
  @override
  String get connected => 'Подключено';
  @override
  String get disconnectStorage => 'Отключить хранилище';
  @override
  String get disconnectStorageDescription =>
      'Перестать использовать внешнее хранилище. Новые блобы пойдут через '
      'сервер синхронизации.';
  @override
  String get externalStorageDisconnected => 'Внешнее хранилище отключено.';
  @override
  String couldNotDisconnectStorage(Object error) =>
      'Не удалось отключить внешнее хранилище: $error';
  @override
  String get bringYourOwnStorage => 'Своё хранилище';
  @override
  String get bringYourOwnDescription =>
      'Храните содержимое файлов в своём S3 или WebDAV. Сервер синхронизации '
      'будет обрабатывать только лёгкие метаданные.';
  @override
  String get s3Compatible => 'S3-совместимое';
  @override
  String get s3Description => 'AWS S3, MinIO, Cloudflare R2, Backblaze B2';
  @override
  String get webdavName => 'WebDAV';
  @override
  String get webdavDescription => 'Nextcloud, ownCloud или любой WebDAV-сервер';
  @override
  String externalStorageConnected(String kind) =>
      'Внешнее хранилище подключено: $kind';
  @override
  String couldNotSaveStorage(Object error) =>
      'Не удалось сохранить внешнее хранилище: $error';
  @override
  String get s3ConfigTitle => 'Настройка S3-хранилища';
  @override
  String get webdavConfigTitle => 'Настройка WebDAV-хранилища';
  @override
  String get endpoint => 'Endpoint';
  @override
  String get bucket => 'Бакет';
  @override
  String get accessKey => 'Access Key';
  @override
  String get secretKey => 'Secret Key';
  @override
  String get region => 'Регион';
  @override
  String get username => 'Логин';
  @override
  String get password => 'Пароль';

  // ── Settings: settings-sync + storage usage ──
  @override
  String get reuploadSettingsTitle => 'Перезалить настройки с этого устройства?';
  @override
  String get reuploadSettingsBody =>
      'Настройки на сервере будут заменены настройками .obsidian с этого '
      'устройства. Другие устройства пересинхронизируются автоматически.';
  @override
  String get settingsReuploadFinished => 'Перезалив настроек завершён.';
  @override
  String settingsReuploadFailed(Object error) =>
      'Перезалив настроек не удался: $error';
  @override
  String get downloadSettingsTitle => 'Скачать настройки с сервера?';
  @override
  String get downloadSettingsBody =>
      'Настройки .obsidian этого устройства будут заменены серверной версией. '
      'Большинство изменений применится после перезапуска Obsidian.';
  @override
  String get settingsDownloadFinished =>
      'Скачивание настроек завершено — перезапустите Obsidian для применения.';
  @override
  String settingsDownloadFailed(Object error) =>
      'Скачивание настроек не удалось: $error';
  @override
  String get settingsSyncSection => 'Синхронизация настроек (.obsidian)';
  @override
  String get syncSettingsName => 'Синхронизировать настройки (.obsidian)';
  @override
  String get syncSettingsDescription =>
      'Синхронизируйте настройки приложения, горячие клавиши, темы и настройки '
      'плагинов между устройствами. Большинство изменений применится после '
      'перезапуска Obsidian.';
  @override
  String get reuploadSettingsRowName =>
      'Перезалить настройки с этого устройства';
  @override
  String get reuploadSettingsRowDesc =>
      'Использовать это устройство как источник истины. Серверные настройки '
      'заменяются настройками .obsidian этого устройства; остальные устройства '
      'пересинхронизируются автоматически.';
  @override
  String get downloadSettingsRowName => 'Скачать настройки с сервера';
  @override
  String get downloadSettingsRowDesc =>
      'Заменить настройки .obsidian этого устройства серверной версией. '
      'Используйте, если настройки на этом устройстве устарели или неверны. '
      'Большинство изменений применится после перезапуска Obsidian.';
  @override
  String get settingsCatAppSettings => 'Настройки приложения';
  @override
  String get settingsCatAppSettingsDesc =>
      'app.json, graph.json (редактор, файлы и ссылки)';
  @override
  String get settingsCatAppearance => 'Внешний вид';
  @override
  String get settingsCatAppearanceDesc =>
      'Тема, тёмный режим, включённые сниппеты';
  @override
  String get settingsCatHotkeys => 'Горячие клавиши';
  @override
  String get settingsCatHotkeysDesc => 'Пользовательские горячие клавиши';
  @override
  String get settingsCatCorePluginsEnabled =>
      'Основные плагины (список включённых)';
  @override
  String get settingsCatCorePluginsEnabledDesc =>
      'Какие основные плагины включены';
  @override
  String get settingsCatCorePluginSettings => 'Настройки основных плагинов';
  @override
  String get settingsCatCorePluginSettingsDesc =>
      'Ежедневные заметки, шаблоны и т.д.';
  @override
  String get settingsCatCommunityPluginsEnabled =>
      'Сторонние плагины (список включённых)';
  @override
  String get settingsCatCommunityPluginsEnabledDesc =>
      'Какие сторонние плагины включены';
  @override
  String get settingsCatCommunityPluginSettings =>
      'Настройки сторонних плагинов';
  @override
  String get settingsCatCommunityPluginSettingsDesc =>
      'data.json каждого плагина';
  @override
  String get settingsCatThemesSnippets => 'Темы и сниппеты';
  @override
  String get settingsCatThemesSnippetsDesc =>
      'Скачанные темы и CSS-сниппеты';
  @override
  String get storageSection => 'Хранилище';

  // ── Sync panel ──
  @override
  String get endToEndEncrypted => 'Сквозное шифрование';
  @override
  String syncedAgo(String ago) => 'синхр. $ago';
  @override
  String get notConnected => 'Нет подключения';
  @override
  String get panelStorageLabel => 'Хранение';
  @override
  String get vaultSizeLabel => 'Размер хранилища';
  @override
  String get settingsSizeLabel => 'Размер настроек';
  @override
  String get storageDetails => 'Подробнее о хранилище →';
  @override
  String get refreshStorageUsage => 'Обновить занятость хранилища';
  @override
  String get textMergesLine =>
      'Слияние текста: без конфликтов (CRDT) — параллельные правки не затирают '
      'друг друга.';
  @override
  String uploadDownloadReport(int up, int down) =>
      '↑ отправлено $up   ↓ скачано $down';
  @override
  String get resumeSync => 'Возобновить';
  @override
  String get pauseSync => 'Пауза';
  @override
  String get settingsButton => 'Настройки';
  @override
  String activeTransfers(int n) => 'Активные передачи ($n)';
  @override
  String get recent => 'Недавние';
  @override
  String get browseVersions => 'История версий';
  @override
  String tooLargeToSync(int n) => 'Слишком большие для синка ($n)';
  @override
  String get tooLargeHint =>
      'Больше лимита на файл в вашем плане. Остаются только локально, пока не '
      'уменьшатся ниже лимита или вы не обновите план.';
  @override
  String blockedMeta(String size, String limit) => '$size · лимит $limit';
  @override
  String andMore(int n) => '…и ещё $n';
  @override
  String conflictsLostContent(int n) => 'Конфликты с потерей содержимого ($n)';
  @override
  String storageMeterTitle(String plan) => 'Хранилище · $plan';
  @override
  String get syncStopped => 'Синхронизация остановлена';
  @override
  String get connecting => 'Подключение…';
  @override
  String get reconnecting => 'Переподключение…';
  @override
  String get reconnect => 'Переподключить';
  @override
  String get offlineCantReach => 'Офлайн — сервер недоступен';
  @override
  String get upToDate => 'Актуально';
  @override
  String get pendingChanges => 'Есть несохранённые изменения';
  @override
  String syncingProgress(int completed, int total) =>
      'Синхронизация $completed/$total';
  @override
  String get syncingEllipsis => 'Синхронизация…';
  @override
  String get syncErrorStatus => 'Ошибка синхронизации';
  @override
  String get sessionExpiredStatus => 'Сессия истекла';
  @override
  String get subscriptionRequiredStatus => 'Требуется подписка';
  @override
  String get pausedStatus => 'На паузе';

  // ── Self-host modal ──
  @override
  String get selfHostModalTitle => 'Свой сервер';
  @override
  String get selfHostModalDescription =>
      'Синхронизация через ваш собственный сервер вместо управляемого сервиса. '
      'Перезагрузите плагин после сохранения, чтобы применить.';
  @override
  String get serverUrl => 'URL сервера';
  @override
  String get accessToken => 'Токен доступа';
  @override
  String get enableAndSave => 'Включить и сохранить';
  @override
  String get serverUrlTokenRequired =>
      'URL сервера и токен доступа обязательны.';
  @override
  String get disable => 'Отключить';

  // ── DB recovery ──
  @override
  String get dbRecoveryTitle => 'База данных повреждена';
  @override
  String get dbCorruptedText =>
      'Локальная база синхронизации повреждена и не может использоваться.';
  @override
  String get dbRecoveryDescription =>
      'Такое бывает после сбоя или прерванной записи. Сброс базы удалит локально '
      'кэшированные данные — ваши файлы и данные на сервере не затрагиваются. '
      'После сброса плагин перезагрузится и пересинхронизируется с сервера.';
  @override
  String get resetDatabase => 'Сбросить базу';

  // ── Status bar / floating pill ──
  @override
  String labelUp(int completed, int total) => '↑ $completed/$total';
  @override
  String labelDown(int completed, int total) => '↓ $completed/$total';
  @override
  String labelRepair(int completed, int total) => 'починка $completed/$total';
  @override
  String get overlaySettings => 'настройки';
  @override
  String tipUploading(int completed, int total) =>
      'Rhyolite Sync: загрузка $completed из $total файлов';
  @override
  String tipDownloading(int completed, int total) =>
      'Rhyolite Sync: скачивание $completed из $total файлов';
  @override
  String tipRepairing(int completed, int total) =>
      'Rhyolite Sync: починка $completed из $total файлов — пересборка состояния, '
      'это может занять время';
  @override
  String get tipStopped => 'Rhyolite Sync: остановлено';
  @override
  String get tipOffline => 'Rhyolite Sync: офлайн — сервер недоступен, повтор';
  @override
  String get tipConnecting => 'Rhyolite Sync: подключение…';
  @override
  String get tipConnected => 'Rhyolite Sync: подключено';
  @override
  String get tipUploadingChanges => 'Rhyolite Sync: отправка изменений';
  @override
  String get tipDownloadingChanges => 'Rhyolite Sync: скачивание изменений';
  @override
  String get tipUploadingInitial => 'Rhyolite Sync: первичная загрузка файлов';
  @override
  String get tipDownloadingFiles => 'Rhyolite Sync: скачивание файлов';
  @override
  String get tipRepairingVault =>
      'Rhyolite Sync: починка хранилища — пересборка состояния';
  @override
  String get tipError => 'Rhyolite Sync: ошибка — нажмите, чтобы открыть настройки';
  @override
  String get tipAuthExpired =>
      'Rhyolite Sync: сессия истекла — нажмите, чтобы открыть настройки';
  @override
  String get tipSubExpired =>
      'Rhyolite Sync: подписка истекла — нажмите, чтобы открыть настройки';
  @override
  String get tipSyncingSettings => 'Rhyolite Sync: синхронизация настроек';

  // ── Commands ──
  @override
  String get cmdSyncNow => 'Синхронизировать сейчас';
  @override
  String get cmdReconnect => 'Переподключиться сейчас';
  @override
  String get cmdSyncSettingsNow => 'Синхронизировать настройки (.obsidian)';
  @override
  String get cmdCleanupStorage => 'Очистить хранилище (история + блобы)';
  @override
  String get cmdManageDevices => 'Управление устройствами синхронизации';
  @override
  String get cmdReclaimOrphans => 'Освободить осиротевшие блобы';
  @override
  String get cmdConfigureSelfHost => 'Настроить свой сервер';
  @override
  String get cmdShowHistory => 'История версий текущего файла';
  @override
  String get cmdRestoreBackup => 'Восстановить из бэкапа';

  // ── Payment activation ──
  @override
  String get activatingSubscription => 'Активирую подписку…';
  @override
  String get confirmingPayment => 'Подождите, подтверждаем ваш платёж.';
  @override
  String get checking => 'Проверяю…';
  @override
  String get subscriptionNowActive =>
      'Ваша подписка активна. Синхронизация скоро начнётся.';
  @override
  String get gotIt => 'Понятно';
  @override
  String get paymentNotConfirmed => 'Платёж не подтверждён';
  @override
  String get paymentNotConfirmedBody =>
      'Не удалось подтвердить платёж за 5 минут. Если вы завершили оплату, '
      'перезапустите Obsidian. Если проблема остаётся — напишите в поддержку.';
}
