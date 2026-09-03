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
  String get passphraseTooShort =>
      'Нужно минимум 12 символов — длина важнее спецсимволов.';

  @override
  String get passphraseTooFewClasses =>
      'Смешайте хотя бы три из: строчные, заглавные, цифры, символы.';

  @override
  String passphraseCommonWord(String word) =>
      'Содержит распространённое слово («$word»). Возьмите несвязанные слова.';

  @override
  String get passphraseHasSequence =>
      'Уберите последовательности вроде «abcd» или «1234» — они почти не '
      'добавляют стойкости.';

  @override
  String get passphraseHasRepetition =>
      'Уберите повторы вроде «aaaa» или «1111».';

  @override
  String get passphraseTooPredictable =>
      'Слишком предсказуемо. Сделайте длиннее или возьмите несколько '
      'несвязанных слов.';
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
  String get backupsUnavailable => 'Бэкапы недоступны — движок не подключён';
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
  String get notConnectedNoCapture => 'Нет подключения — точка не создана.';
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
  String get reclaimStorageByoDescription =>
      'Объекты в вашем хранилище, на которые больше не ссылается ни один файл, '
      'ни запись истории, ни точка восстановления — обычно остатки прерванных '
      'загрузок. Устройство перечисляет бакет, а решение принимает сервер: '
      'только он видит данные всех ваших устройств.';
  @override
  String reclaimedByo(int n) => 'Освобождено объектов: $n.';
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
  String get contentSize => 'Размер';
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
  String get notConnectedNothingCleared =>
      'Нет подключения — ничего не очищено.';
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
  String nothingToCleanOlderThan(int days) => 'Нечего очищать старше $days дн.';
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
  String oldestEntryToDelete(String when) =>
      'Самая старая запись к удалению: $when';
  @override
  String newestEntryToDelete(String when) =>
      'Самая новая запись к удалению: $when';
  @override
  String oldestEntryRemaining(String when) =>
      'Самая старая из оставшихся: $when';
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
  String deviceAlreadyGone(String name) =>
      'Устройство $name уже отсутствовало.';
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
  String get historyPickFile => 'Выбор файла';
  @override
  String historyPickHint(int paths, int events) =>
      'путей с историей: $paths (из последних $events записей). Удалённые и '
      'переименованные файлы тоже здесь — их версии лежат под тем именем, '
      'которое у них было.';
  @override
  String get historyFilterPlaceholder => 'Фильтр по пути';
  @override
  String historyPathMeta(int versions, String when) =>
      'записей: $versions  ·  $when';
  @override
  String get historyGoneMark => 'удалён';
  @override
  String get historyOtherFile => 'Другой файл…';
  @override
  String get historyEmpty => 'В истории пока пусто.';
  @override
  String get historyNothingMatches => 'Ничего не найдено.';
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
      'будет заменена файлами с этого устройства, а остальные устройства '
      'заменят свою копию на эту.';
  @override
  String get reuploadConfirmTitle => 'Перезалить с этого устройства?';
  @override
  String get reuploadConfirmBody =>
      'История на сервере будет заменена файлами с этого устройства. Каждое '
      'остальное устройство сотрёт свою копию хранилища и скачает эти файлы, '
      'поэтому заметка, которой здесь нет, исчезнет и на них — запускайте с '
      'самого полного устройства. Файлы на этом устройстве не трогаются.';
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
      'Локальные файлы будут удалены и заменены серверной версией. Папки и '
      'типы файлов, исключённые из синхронизации, не трогаются. Это касается '
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
      'файлов на диске не меняется.\n\n'
      'Содержимое этого устройства станет главным: история правок сбрасывается, '
      'и если в этот момент кто-то правит те же заметки на другом устройстве, '
      'удалённый здесь текст может вернуться.';
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
  String planEndedOn(String date) => 'Подписка закончилась $date';
  @override
  String get planEndedNoDate => 'Подписка закончилась';
  @override
  String planEndingOn(String date) => 'Подписка заканчивается $date';
  @override
  String get planEndedHint =>
      'Синхронизация продолжается на бесплатных лимитах: выгрузка сверх '
      'бесплатной квоты отклоняется.';
  @override
  String get planEndingHint => 'Продлите, чтобы сохранить текущие лимиты.';
  @override
  String get planRenew => 'Продлить';
  @override
  String get planQuotaFull => 'Место закончилось';
  @override
  String get planQuotaFullHint =>
      'Новые и изменённые файлы не выгружаются, пока не освободится место или '
      'не вырастет лимит.';
  @override
  String get planSeePlans => 'Тарифы';
  @override
  String activeUntil(String date) => 'Активна до $date';
  @override
  String endedOn(String date) => 'Закончилась $date';
  @override
  String get subscriptionEnded =>
      'Хранилище работает на бесплатных лимитах. Продлите, чтобы вернуть прежние.';
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
      'По умолчанию выключено. Стримит логи этого устройства на адрес выше в '
      'реальном времени. Логи всегда хранятся на устройстве — это лишь '
      'добавляет удалённую копию. Они включают пути файлов, id, хэши, размеры '
      'и тайминги — но не содержимое файлов.';

  // ── Отчёт об ошибке ──
  @override
  String get bugReportSettingName => 'Отчёт об ошибке';
  @override
  String get bugReportSettingDescription =>
      'Соберёт всё, что нужно для разбора проблемы синхронизации, отправит в '
      'поддержку и оставит копию в хранилище. Названия заметок заменяются на '
      'псевдонимы, содержимого в отчёте нет.';
  @override
  String get bugReportCommand => 'Создать отчёт об ошибке';
  @override
  String get bugReportTitle => 'Создать отчёт об ошибке';
  @override
  String get bugReportIntro =>
      'Опишите, что пошло не так. Помогает любая деталь: что вы делали, на '
      'каком устройстве и примерно когда.';
  @override
  String get bugReportPlaceholder =>
      'Правки с телефона перестали приходить на компьютер около 14:30.';
  @override
  String get bugReportContents =>
      'В отчёт войдут версия плагина и настройки, статистика хранилища и '
      'недавние логи этого устройства. Названия заметок и папок заменяются на '
      'псевдонимы: видно расширения и структуру папок, но не имена. '
      'Содержимого заметок в отчёте нет. Пароли, ключи и токены вырезаются.';
  @override
  String get bugReportWillSend =>
      'Готовый отчёт уйдёт в поддержку, а копия останется в хранилище — её '
      'можно открыть и прочитать целиком.';
  @override
  String get bugReportWillSaveOnly =>
      'Отчёт сохранится в хранилище и никуда не отправится — вы сами решаете, '
      'кому его передать.';
  @override
  String get bugReportCreate => 'Создать отчёт';
  @override
  String get bugReportCollecting => 'Собираю диагностику…';
  @override
  String bugReportFailed(Object error) => 'Не удалось собрать отчёт: $error';
  @override
  String get bugReportReadyTitle => 'Отчёт готов';
  @override
  String get bugReportSent => 'Отправлен в поддержку. Номер отчёта:';
  @override
  String get bugReportSentHint =>
      'Больше ничего делать не нужно — назовите этот номер, когда напишете. '
      'Копия сохранена в хранилище, её можно удалить.';
  @override
  String bugReportNotSent(String reason) =>
      'Отправить в поддержку не удалось ($reason) — приложите файл вручную.';
  @override
  String get bugReportTooLargeToSend => 'отчёт больше, чем принимает сервер';
  @override
  String get bugReportSavedTo => 'Сохранён в хранилище как:';
  @override
  String get bugReportSummaryTitle => 'Что в отчёте';
  @override
  String get bugReportSendHint =>
      'Это сжатый архив. Приложите его через выбор файлов — хранилище '
      'обычная папка на устройстве. Он не синхронизируется, и после отправки '
      'его можно удалить.';
  @override
  String bugReportSaveFailed(Object error) =>
      'Не удалось сохранить отчёт в хранилище: $error';
  @override
  String get bugReportOpenTelegram => 'Открыть Telegram';
  @override
  String get bugReportLogUnavailable =>
      'Файл логов прочитать не удалось — здесь только то, что осталось в '
      'памяти от текущей сессии.';
  @override
  String get clearLogsName => 'Логи диагностики';
  @override
  String get clearLogsDescription =>
      'Логи хранятся только на этом устройстве, занимают не больше ~26 МБ, и '
      'старые удаляются сами. Удаление сейчас потеряет историю, которую унёс '
      'бы отчёт об ошибке; запись логов при этом продолжится.';
  @override
  String get clearLogsButton => 'Удалить логи';
  @override
  String clearLogsDone(String freed) => 'Логи диагностики удалены ($freed).';
  @override
  String clearLogsFailed(Object error) => 'Не удалось удалить логи: $error';
  @override
  String get deviceSettingsSection => 'Только на этом устройстве';
  @override
  String get deviceSettingsNote =>
      'Хранится в этой установке и никуда не передаётся. Другие ваши устройства '
      'не затронуты, а исключённое остаётся и на диске, и на сервере.';
  @override
  String get sharedSettingsSection => 'Общие для всех устройств';
  @override
  String get sharedSettingsNote =>
      'Хранится вместе с хранилищем, поэтому значение одинаково на каждом '
      'устройстве, где вы синхронизируетесь.';
  @override
  String get syncOnlyPaths => 'Синхронизировать только эти папки';
  @override
  String get syncOnlyPathsDescription =>
      'Список через запятую (напр. Работа, Личное/Дневник). Если он задан, это '
      'устройство не синхронизирует ничего за пределами этих папок. Оставьте '
      'пустым, чтобы синхронизировать всё хранилище. Возврат папки скачает её '
      'файлы при следующей синхронизации.';
  @override
  String get dontSyncPaths => 'Не синхронизировать эти папки';
  @override
  String get dontSyncPathsDescription =>
      'Список через запятую, применяется поверх списка выше — можно '
      'синхронизировать Работа, но пропустить Работа/черновики.';
  @override
  String get deviceFiltersSaved =>
      'Фильтры сохранены. Синхронизация перезапускается.';
  @override
  String get dontSyncExtensions => 'Не синхронизировать эти расширения';
  @override
  String get dontSyncDescription =>
      'Список через запятую (напр. pdf, zip, mp4). Файлы с этими расширениями '
      'не загружаются и не скачиваются. Оставьте пустым, чтобы синхронизировать '
      'все типы. Возврат типа скачает его файлы при следующей синхронизации.';
  @override
  String get forceBinaryExtensions => 'Синхронизировать эти расширения целиком';
  @override
  String get forceBinaryDescription =>
      'Список через запятую (напр. excalidraw, drawio). Такие файлы '
      'синхронизируются целыми снимками по правилу «последний победил», а не '
      'построчным слиянием — это верный выбор для структурных форматов '
      '(рисунки, диаграммы), которые слияние текста испортит. .excalidraw.md и '
      '.canvas всегда обрабатываются так. Существующие файлы переведутся при '
      'следующем изменении.';
  @override
  String get forceBinarySaved => 'Сохранено. Применится на всех устройствах.';
  @override
  String filtersSaveFailed(Object error) => 'Не удалось сохранить: $error';

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
  String get reuploadSettingsTitle =>
      'Перезалить настройки с этого устройства?';
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
  String get settingsCatCommunityPluginCode => 'Сами сторонние плагины';
  @override
  String get settingsCatCommunityPluginCodeDesc =>
      'Плагины будут установлены на всех устройствах, одна версия на хранилище. '
      'Занимает намного больше места, чем остальные категории.';
  @override
  String settingsCatCommunityPluginCodeSize(String size) =>
      'Плагины на этом устройстве занимают $size.';
  @override
  String get pluginCodeUnavailableQuota =>
      'Нужно больше места, чем даёт текущий тариф. Доступно на Pro, со своим '
      'S3/WebDAV или на своём сервере.';
  @override
  String get pluginCodeUnavailableUnknown =>
      'Ждём данные о тарифе — откройте настройки чуть позже.';
  @override
  String get settingsCatThemesSnippets => 'Темы и сниппеты';
  @override
  String get settingsCatThemesSnippetsDesc => 'Скачанные темы и CSS-сниппеты';
  @override
  String get pluginsSection => 'Плагины (хранилище)';
  @override
  String get themesSection => 'Темы (хранилище)';
  @override
  String get manageAction => 'Управление';
  @override
  String get storageUsedLabel => 'Занято';
  @override
  String pluginsOutOfSyncHere(int n) => 'Не синхронизировано здесь: $n';
  @override
  String get storageOverviewAction => 'Обзор';
  @override
  String get storageOverviewRowDesc =>
      'Что лежит в хранилище — на сервере и на этом устройстве.';
  @override
  String get pluginMgmtTitle => 'Плагины в хранилище';
  @override
  String pluginMgmtDescription(int count, String size) =>
      'Плагинов: $count, $size. Удаление убирает плагин со всех устройств и '
      'освобождает место.';
  @override
  String get pluginMgmtNoPlugins => 'В хранилище пока нет плагинов.';
  @override
  String get pluginMgmtAction => 'Плагины';
  @override
  String get pluginRemoveAction => 'Удалить';
  @override
  String pluginRemoveTitle(String id) => 'Удалить $id из хранилища?';
  @override
  String pluginRemoveBody(String size) =>
      'Плагин будет удалён на всех устройствах, освободится $size. '
      'Если установить его снова, он снова засинкается.';
  @override
  String get pluginRemoveConfirm => 'Удалить везде';
  @override
  String pluginRemovedFromVault(String id) => '$id удалён из хранилища';
  @override
  String get pluginRemoveUnavailable => 'Синхронизация плагинов не запущена';
  @override
  String pluginRemoveFailed(String id, Object error) =>
      'Не удалось удалить $id: $error';
  @override
  String pluginFromDevice(String device) => 'с $device';
  @override
  String pluginLine(String id, String version, String size, String note) =>
      '$id $version — $size${note.isEmpty ? '' : ' · $note'}';
  @override
  String get pluginNotInstalledHere => 'ещё не на этом устройстве';
  @override
  String get pluginDesktopOnlySkipped => 'только для десктопа, пропущен здесь';
  @override
  String pluginVersionHere(String version) => 'здесь версия $version';
  @override
  String get pluginsSizeLabel => 'Плагины';
  @override
  String get storageSection => 'Хранилище';

  // ── Sync panel ──
  @override
  String get panelStarting => 'Rhyolite Sync запускается...';

  @override
  String get faqButton => 'Вопросы и ответы';
  @override
  String get faqSettingName => 'Вопросы и ответы';
  @override
  String get faqSettingDescription =>
      'Как ведёт себя синхронизация, что она делает с конфликтами и что '
      'делать, если что-то выглядит не так. Откроется в браузере.';

  @override
  String get endToEndEncrypted => 'Сквозное шифрование';
  @override
  String syncedAgo(String ago) => 'синхр. $ago';
  @override
  String get notConnected => 'Нет подключения';
  @override
  String get panelStorageLabel => 'Хранение';
  @override
  String get vaultSizeLabel => 'Хранилище';
  @override
  String get settingsSizeLabel => 'Настройки';
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
  String vanishedFiles(int n) => 'Пропали с прошлого запуска ($n)';
  @override
  String get vanishedFilesHint =>
      'Эти файлы были на этом устройстве и больше их нет. Rhyolite в тот '
      'момент не работал и не может отличить, удалили вы их или хранилище '
      'просто было недоступно, — и не станет угадывать: неверный ответ удалит '
      'их везде.';
  @override
  String get vanishedDelete => 'Удалить на всех устройствах';
  @override
  String get vanishedKeep => 'Оставить';
  @override
  String vanishedDeleted(int n) => 'Удалено на всех устройствах: $n.';
  @override
  String needsNewerClient(int n) => 'Нужна свежая версия ($n)';
  @override
  String get needsNewerClientHint =>
      'Сохранены устройством с более новым Rhyolite. Обновите плагин до '
      'последней версии — и они синхронизируются. До этого файлы не трогаются '
      'ни на диске, ни на сервере, а правки здесь не синхронизируются.';
  @override
  String databaseFull(String size, String limit) =>
      'Локальная база заполнена ($size из $limit)';
  @override
  String get databaseFullHint =>
      'Кеш очищен, но место не вернулось — значит, занято рабочими данными. '
      'Синхронизация продолжается, но база, которой некуда расти, рано или '
      'поздно перестанет принимать запись. Место возвращает сжатие.';
  @override
  String tooLargeToFetch(int n) => 'Слишком большие для загрузки сюда ($n)';
  @override
  String get tooLargeToFetchHint =>
      'Больше лимита на файл для этого устройства, поэтому на диск они не '
      'записаны. Ничего не потеряно: файлы целы на сервере и на устройствах, '
      'которым они по силам.';
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

  @override
  String get blockedSignedOut => 'Вход не выполнен';
  @override
  String get blockedSignedOutHint =>
      'Войдите в аккаунт Rhyolite, чтобы включить синхронизацию.';
  @override
  String get blockedNoVault => 'Хранилище не подключено';
  @override
  String get blockedNoVaultHint =>
      'Выберите удалённое хранилище для этого устройства.';
  @override
  String get blockedLocked => 'Хранилище заблокировано';
  @override
  String get blockedLockedHint =>
      'Введите парольную фразу — без ключа синхронизация невозможна.';
  @override
  String get blockedNoServer => 'Сервер не настроен';
  @override
  String get blockedNoServerHint => 'Укажите адрес сервера и токен доступа.';
  @override
  String syncNotStartedNotice(String reason) =>
      'Rhyolite: синхронизация не запущена — $reason. Откройте панель синхронизации.';

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
  @override
  String get localStateLostNotice =>
      'Rhyolite: локальная база синхронизации потеряна, хранилище '
      'восстанавливается с сервера — все файлы скачиваются заново. Если файл, '
      'удалённый на этом устройстве, вернулся, удалите его ещё раз.';
  @override
  String get noDurableStorageNotice =>
      'Rhyolite: устройство не дало плагину постоянного хранилища, состояние '
      'синхронизации держится в памяти и теряется при закрытии Obsidian. '
      'Хранилище будет скачиваться заново при каждом запуске.';

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
  String get tipError =>
      'Rhyolite Sync: ошибка — нажмите, чтобы открыть настройки';
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
  String get cmdDatabaseReport => 'Сохранить отчёт о локальной базе';

  @override
  String get cmdCompactDatabase => 'Сжать локальную базу';

  @override
  String categoriesCount(int n) {
    final t = n % 10, h = n % 100;
    if (t == 1 && h != 11) return '$n категория';
    if (t >= 2 && t <= 4 && (h < 12 || h > 14)) return '$n категории';
    return '$n категорий';
  }

  @override
  String get featureOff => 'Выкл';

  @override
  String get databaseSection => 'Локальная база';

  @override
  String get databaseFileSize => 'Размер файла';

  @override
  String get databaseEmptySpace => 'Пустого места';

  @override
  String get databaseCompactHint =>
      'Файл в основном пуст. Сжатие перепишет его и вернёт место; '
      'это надолго, поэтому сначала поставьте синхронизацию на паузу.';

  @override
  String get databaseReportAction => 'Отчёт';

  @override
  String get databaseCompactAction => 'Сжать';


  @override
  String compactOffer(String free) =>
      'В локальной базе $free пустого места — сжать';

  @override
  String get compactRunning =>
      'Сжимаю — база переписывается целиком, это может занять время. '
      'Не закрывайте Obsidian.';

  @override
  String compactDone(String before, String after) =>
      'База сжата: $before -> $after.';
  @override
  String get cmdSyncSettingsNow => 'Синхронизировать настройки (.obsidian)';
  @override
  String get cmdConfigureSelfHost => 'Настроить свой сервер';
  @override
  String get cmdShowHistory => 'История версий текущего файла';

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
  @override
  String get storageSwitchedTitle => 'Хранилище переключено';
  @override
  String get storageSwitchedBody =>
      'Всё, что синхронизировалось раньше, лежит в прежнем хранилище — новое '
      'о нём не знает, и само ничего не переносится.\n\n'
      'Всё, что вы измените дальше, попадёт уже в новое хранилище. Остальное '
      'останется доступным только там, где оно лежит сейчас.';
  @override
  String get blockedStorageRefused => 'Хранилище отклоняет запросы';
  @override
  String get blockedStorageRefusedHint =>
      'Ваше хранилище не принимает файлы — обычно это неверный логин, пароль '
      'или путь. Пока это не исправлено, изменения не отправляются.';
  @override
  String get blockedStorageRefusedAction => 'Открыть настройки';
}
