/// כל המלל שהחבילה מציגה — הודעות חריגים, סיבות תוכנית ושלבי התקדמות.
///
/// ברירת המחדל עברית. צרכן שמציג שפה אחרת מציב ב-[current] מימוש בלי מצב
/// (נשלח בין isolates); החבילה מעבירה אותו ל-isolates שלה, והצרכן — לשלו.
abstract class LibraryUpdaterMessages {
  const LibraryUpdaterMessages();

  /// המימוש הפעיל ב-isolate הנוכחי.
  static LibraryUpdaterMessages current = const HebrewLibraryUpdaterMessages();

  // יחידות גודל.
  String megabytes(String amount);
  String gigabytes(String amount);

  // מניפסט ה-delta.
  String unsupportedPatchCompression(String compression);
  String get manifestMissingPatchFiles;
  String manifestMissingField(String key);
  String get manifestMissingPatchFormatVersion;
  String manifestInvalidOptionalField(String key);
  String manifestInvalidHashMap(String key);

  // GitHub.
  String releasesRequestFailed(int statusCode);
  String get releasesResponseNotList;
  String manifestDownloadFailed(String url, int statusCode);
  String manifestNotJsonObject(String url);
  String splitManifestDownloadFailed(String name, int statusCode);

  // מראה מקומית.
  String mirrorManifestMissing(String fileName, String mirrorDir);
  String mirrorManifestCorrupt(String fileName, String mirrorDir, String error);
  String mirrorManifestUnexpectedShape(String fileName, String mirrorDir);
  String mirrorPatchManifestMissing(String url);
  String mirrorPatchManifestCorrupt(String url, String error);
  String mirrorPatchManifestNotJson(String url);

  // התאוששות וגרסה מקומית.
  String get interruptedUpdateFound;
  String get interruptedUpdateWithoutBackup;
  String get interruptedUpdateRestored;
  String get localDbLocked;
  String get localDbInterruptedWrite;
  String get localDbReadOnlyLocation;

  // תכנון — מסלול מקוון.
  String get planLocalVersionUnknown;
  String planNoDeltaRoute(int localVersion, int latestVersion);
  String planNoFullDbEither(String reason);
  String planSchemaNeedsAppUpdate(int schemaVersion, int supportedSchema);
  String planSchemaBarrierNeedsFullDownload(int schemaVersion);
  String planDeltaNeedsAppUpdate(
    int latestVersion,
    int supportedSchema,
    int supportedPatchFormat,
  );
  String planHeavyDelta(String deltaSize, String localDbSize);

  // תכנון — מסלול המראה.
  String planContentChangedWithoutVersionBump(String releaseTag);
  String planFullDbFasterThanPatches(
    int stepCount,
    int patchMinutes,
    int fullDbMinutes,
  );
  String planPatchSchemaTooNew(int schemaVersion, int latestVersion);
  String planPatchFormatTooNew(int patchFormatVersion, int latestVersion);
  String planFullDbWouldNotProgress(
    int reachableVersion,
    int localVersion,
    int latestVersion,
  );
  String planNewSchemaNeedsFullDb(int latestVersion, int schemaVersion);
  String planPartialDeltaSchemaStop(
    int reachedVersion,
    int latestVersion,
    int schemaVersion,
  );
  String planPartialDeltaFormatStop(
    int reachedVersion,
    int latestVersion,
    int patchFormatVersion,
  );

  // החלת patch.
  String unsupportedSchemaForHashOrder(int schemaVersion);
  String localVersionMismatch(int? localVersion, int expected);
  String localSchemaMismatch(int localSchema, int expected);
  String get contentHashMismatchNeedsFullDownload;
  String patchUniqueConflictNeedsFullDownload(String table, String detail);
  String foreignKeyViolationsGrew(int before, int after);
  String resultHashMismatch(String actual, String expected);
  String tableHashMismatch(String tables);
  String patchOpenFailed(String path, String detail);
  String get patchMetaSchemaVersionMissing;
  String patchFormatTooNew(int patchFormatVersion, int supported);
  String patchFormatMismatch(int inPatch, int inManifest);
  String patchVersionRangeMismatch(
    int? from,
    int? to,
    int manifestFrom,
    int manifestTo,
  );

  // הורדה.
  String get networkInterrupted;
  String get compressedFileSizeLabel;
  String get compressedFileHashLabel;
  String get extractedFileSizeLabel;
  String get extractedFileHashLabel;
  String get patchExtractionFailed;
  String get deleteExistingWithoutResumeIdentityFailed;
  String get deletePartialFromPreviousVersionFailed;
  String get deletePartialWithoutValidatorFailed;
  String get deletePartialFromPreviousRepresentationFailed;
  String get deletePartialBeforeRetryFailed;
  String get deletePreviousArchiveFailed;
  String fullDbSizeMismatch(int downloaded, int expected);
  String get fullDbHashMismatch;
  String joinedArchiveSizeMismatch(int written, int expected);
  String get joinedArchiveHashMismatch;
  String resumeRoundLimit(int maxRounds, String url);
  String contentLengthMismatch(int responseLength, int expectedSize);
  String truncatedBody(int declared, int received);
  String downloadHttpError(int statusCode, String url);
  String resumeMadeNoProgress(String url);
  String resumeFailedAfterRetry(String url);
  String downloadExceedsExpectedSize(int expectedSize);
  String saveDownloadedFileFailed(String error);
  String tooManyRedirects(String url);
  String writeResumeSidecarFailed(String path, String error);
  String checksumMismatchDetailed(String label, String expected, String actual);
  String checksumMismatch(String label);
  String localFileNotFound(String path);
  String localFileTooLarge(int maxBytes, String path);
  String localSourceNotFound(String url);
  String localFileSizeMismatch(int expected, int actual, String url);
  String localFileHashMismatch(String url);

  // ייצוא המראה.
  String get exportLoadingReleases;
  String get exportNoReleases;
  String exportPersonalFrom(int localVersion);
  String exportPersonalUpToDate(int localVersion);
  String exportReusingFullDb(int version, String tag);
  String exportDownloading(String tag, String asset);
  String exportVerifying(String tag, String asset, int percent);
  String exportAssembling(String tag, String asset, int percent);
  String exportSplitFullDbSkipped(String tag, String detail);
  String exportSplitPartCorrupted(String asset, String parts);
  String exportAssembledReplaceFailed(String path, String detail);
  String exportWritingManifest(String fileName);
  String get exportDone;
  String get exportCancelled;
  String get exporterDoesNotExtract;
  String exportManifestUnreadable(String asset, String detail);
  String exportManifestFetchFailed(String asset, String detail);
  String exportPatchAssetMissing(String tag, String file);
  String exportSkippingUnappliablePatch(
    String tag,
    String file,
    int schemaVersion,
  );
  String exportSkippingUnsupportedPatchFormat(
    String tag,
    String file,
    int patchFormatVersion,
  );
  String exportFullDbRequiredBySchema(int schemaVersion, int latestVersion);
  String exportFullDbRequiredByPatchFormat(
    int patchFormatVersion,
    int latestVersion,
  );
  String exportFullDbSchemaUnsupported(String tag, int schemaVersion);
  String exportSkippingPatchesFullDbWins(int fileCount, int fullDbVersion);
  String exportFullDbInsteadOfSlowPatches(
    int fileCount,
    int patchMinutes,
    int fullDbMinutes,
    int toVersion,
  );
  String exportPersonalNeedsFullDb(int fromVersion, int latestVersion);
  String exportPersonalNoFullDbEither(int fromVersion, int latestVersion);
  String mirrorNotEnoughDiskSpace(String dir, String needed, String free);
}

/// המלל העברי — ברירת המחדל של [LibraryUpdaterMessages.current].
class HebrewLibraryUpdaterMessages extends LibraryUpdaterMessages {
  const HebrewLibraryUpdaterMessages();

  @override
  String megabytes(String amount) => '$amount מ״ב';
  @override
  String gigabytes(String amount) => '$amount ג״ב';

  @override
  String unsupportedPatchCompression(String compression) =>
      'דחיסה לא נתמכת ב-patch: $compression';
  @override
  String get manifestMissingPatchFiles =>
      'שדה חובה חסר או ריק ב-manifest: patchFiles';
  @override
  String manifestMissingField(String key) =>
      'שדה חובה חסר או לא תקין ב-manifest: $key';
  @override
  String get manifestMissingPatchFormatVersion =>
      'שדה חובה חסר במניפסט של schema 4+: patchFormatVersion';
  @override
  String manifestInvalidOptionalField(String key) =>
      'שדה אופציונלי לא תקין במניפסט: $key';
  @override
  String manifestInvalidHashMap(String key) =>
      'ערך לא תקין במפת ה-hash במניפסט: $key';

  @override
  String releasesRequestFailed(int statusCode) =>
      'שגיאה בקבלת רשימת ה-releases: $statusCode';
  @override
  String get releasesResponseNotList => 'תשובת ה-releases מ-GitHub אינה רשימה';
  @override
  String manifestDownloadFailed(String url, int statusCode) =>
      'שגיאה בהורדת manifest ($url): $statusCode';
  @override
  String manifestNotJsonObject(String url) =>
      'manifest אינו אובייקט JSON תקין: $url';
  @override
  String splitManifestDownloadFailed(String name, int statusCode) =>
      'שגיאה בהורדת מניפסט הפיצול ($name): $statusCode';

  @override
  String mirrorManifestMissing(String fileName, String mirrorDir) =>
      'לא נמצא קובץ $fileName בתיקייה: $mirrorDir — ודא/י שזו תיקיית מראה '
      'תקינה שנוצרה דרך "הכנת עדכון להעברה".';
  @override
  String mirrorManifestCorrupt(
    String fileName,
    String mirrorDir,
    String error,
  ) =>
      'קובץ $fileName בתיקייה $mirrorDir פגום: $error';
  @override
  String mirrorManifestUnexpectedShape(String fileName, String mirrorDir) =>
      'קובץ $fileName בתיקייה $mirrorDir אינו בפורמט הצפוי.';
  @override
  String mirrorPatchManifestMissing(String url) =>
      'קובץ manifest חסר במראה המקומית: $url';
  @override
  String mirrorPatchManifestCorrupt(String url, String error) =>
      'קובץ manifest פגום ($url): $error';
  @override
  String mirrorPatchManifestNotJson(String url) =>
      'manifest אינו אובייקט JSON תקין: $url';

  @override
  String get interruptedUpdateFound =>
      'נמצא סימון עדכון שלא הושלם — יש לוודא תקינות ה-DB';
  @override
  String get interruptedUpdateWithoutBackup =>
      'נמצא סימון עדכון שלא הושלם ללא גיבוי — יש לוודא תקינות ה-DB';
  @override
  String get interruptedUpdateRestored =>
      'עדכון שנקטע זוהה — ה-DB שוחזר מהגיבוי';
  @override
  String get localDbLocked =>
      'לא ניתן לקרוא את גרסת הספרייה המקומית כי המסד נעול, כנראה מפני '
      'שאוצריא פתוחה. יש לסגור את אוצריא ולבדוק שוב.';
  @override
  String get localDbInterruptedWrite =>
      'לא ניתן לקרוא את גרסת הספרייה המקומית: המסד נשאר באמצע כתיבה שנקטעה. '
      'יש לפתוח את אוצריא ולסגור אותה, ואז לבדוק שוב.';
  @override
  String get localDbReadOnlyLocation =>
      'לא ניתן לקרוא את גרסת הספרייה המקומית, כי התיקייה שלה מוגנת מפני '
      'כתיבה. יש לאפשר כתיבה לתיקייה ולבדוק שוב.';

  @override
  String get planLocalVersionUnknown =>
      'גרסת ה-DB המקומי אינה ידועה (חסר schema_meta.db_version)';
  @override
  String planNoDeltaRoute(int localVersion, int latestVersion) =>
      'אין מסלול דלתא רציף מגרסה $localVersion לגרסה $latestVersion';
  @override
  String planNoFullDbEither(String reason) =>
      '$reason, ואין DB מלא זמין להורדה';
  @override
  String planSchemaNeedsAppUpdate(int schemaVersion, int supportedSchema) =>
      'הספרייה עברה לסכמת DB $schemaVersion, '
      'חדשה מהנתמך (DB $supportedSchema) — נדרש עדכון אפליקציה';
  @override
  String planSchemaBarrierNeedsFullDownload(int schemaVersion) =>
      'הספרייה עברה לסכמת DB $schemaVersion; המעבר מחייב הורדה מלאה';
  @override
  String planDeltaNeedsAppUpdate(
    int latestVersion,
    int supportedSchema,
    int supportedPatchFormat,
  ) =>
      'מסלול הדלתא לגרסה $latestVersion דורש סכמת DB או פורמט patch '
      'חדשים מהנתמך (DB $supportedSchema, '
      'patch $supportedPatchFormat) — נדרש עדכון אפליקציה';
  @override
  String planHeavyDelta(String deltaSize, String localDbSize) =>
      'מסלול הדלתא פורס $deltaSize לעומת DB מקומי בגודל '
      '$localDbSize, ושלב ההחלה עלול להימשך זמן רב';

  @override
  String planContentChangedWithoutVersionBump(String releaseTag) =>
      'תוכן המסד עודכן ב-$releaseTag ללא שינוי מספר הגרסה';
  @override
  String planFullDbFasterThanPatches(
    int stepCount,
    int patchMinutes,
    int fullDbMinutes,
  ) =>
      'החלת $stepCount קובצי העדכון תארך כ-$patchMinutes דקות, לעומת כ-'
      '$fullDbMinutes דקות של החלפת המסד המלא — ולכן המסד המלא מוחלף';
  @override
  String planPatchSchemaTooNew(int schemaVersion, int latestVersion) =>
      'הגרסה האחרונה של הספרייה ($latestVersion) בנויה על סכמת מסד '
      '$schemaVersion, שגרסה זו של התוכנה אינה יודעת להחיל דרך קובצי עדכון';
  @override
  String planPatchFormatTooNew(int patchFormatVersion, int latestVersion) =>
      'קובצי העדכון של הגרסה האחרונה ($latestVersion) בנויים בפורמט '
      '$patchFormatVersion, שגרסה זו של התוכנה אינה יודעת להחיל';
  @override
  String planFullDbWouldNotProgress(
    int reachableVersion,
    int localVersion,
    int latestVersion,
  ) =>
      'המסד המלא הזמין להורדה מגיע רק לגרסה $reachableVersion, שאינה חדשה '
      'מהגרסה שכבר מותקנת ($localVersion) — התקנתו תחליף את הספרייה בגרסה '
      'ישנה יותר במקום לעדכן אותה לגרסה $latestVersion. לכן העדכון לא בוצע: '
      'נדרש מסד מלא חדש יותר, או גרסה חדשה יותר של התוכנה.';
  @override
  String planNewSchemaNeedsFullDb(int latestVersion, int schemaVersion) =>
      'גרסה $latestVersion עברה לפורמט מסד חדש (סכמה $schemaVersion), ולכן '
      'המסד כולו מורד מחדש במקום קובצי עדכון';
  @override
  String planPartialDeltaSchemaStop(
    int reachedVersion,
    int latestVersion,
    int schemaVersion,
  ) =>
      'העדכון מגיע לגרסה $reachedVersion. גרסה $latestVersion עברה לפורמט '
      'מסד חדש (סכמה $schemaVersion) שאין אליו קובצי עדכון — כדי להגיע '
      'אליה נדרש מסד מלא חדש.';
  @override
  String planPartialDeltaFormatStop(
    int reachedVersion,
    int latestVersion,
    int patchFormatVersion,
  ) =>
      'העדכון מגיע לגרסה $reachedVersion. קובצי העדכון של גרסה $latestVersion '
      'בנויים בפורמט $patchFormatVersion שהתוכנה אינה יודעת להחיל — כדי '
      'להגיע אליה נדרש מסד מלא חדש.';

  @override
  String unsupportedSchemaForHashOrder(int schemaVersion) =>
      'גרסת סכמה $schemaVersion אינה נתמכת לבחירת סדר hash';
  @override
  String localVersionMismatch(int? localVersion, int expected) =>
      'גרסת ה-DB המקומי ($localVersion) אינה תואמת ל-patch ($expected)';
  @override
  String localSchemaMismatch(int localSchema, int expected) =>
      'סכמת ה-DB המקומי ($localSchema) אינה תואמת ל-patch ($expected)';
  @override
  String get contentHashMismatchNeedsFullDownload =>
      'ה-DB המקומי שונה מהצפוי — hash לא תואם ל-fromContentHash. '
      'נדרשת הורדה מלאה.';
  @override
  String patchUniqueConflictNeedsFullDownload(String table, String detail) =>
      'ה-patch אינו מתאים למסד שעל המחשב: התנגשות ערך ייחודי בטבלה "$table". '
      'העדכון המצטבר בוטל והמסד לא נגע. נדרשת הורדה מלאה של הספרייה. '
      '($detail)';
  @override
  String foreignKeyViolationsGrew(int before, int after) =>
      'מספר הפרות מפתח זר גדל ($before→$after) — ה-patch אינו תקין';
  @override
  String resultHashMismatch(String actual, String expected) =>
      'ה-hash אחרי apply ($actual) אינו תואם ל-toContentHash ($expected)';
  @override
  String tableHashMismatch(String tables) =>
      'ה-hash אחרי apply אינו תואם ל-toTableContentHashes בטבלאות: $tables';
  @override
  String patchOpenFailed(String path, String detail) =>
      'לא ניתן לפתוח את קובץ ה-patch ($path): $detail';
  @override
  String get patchMetaSchemaVersionMissing =>
      'patch_meta.schema_version חסר ב-patch';
  @override
  String patchFormatTooNew(int patchFormatVersion, int supported) =>
      'גרסת פורמט ה-patch ($patchFormatVersion) מחוץ לטווח הנתמך '
      '(1–$supported) — נדרש עדכון תוכנה או patch תקין';
  @override
  String patchFormatMismatch(int inPatch, int inManifest) =>
      'גרסת פורמט ה-patch ($inPatch) אינה תואמת למניפסט ($inManifest)';
  @override
  String patchVersionRangeMismatch(
    int? from,
    int? to,
    int manifestFrom,
    int manifestTo,
  ) =>
      'גרסאות ה-patch ($from→$to) אינן תואמות ל-manifest '
      '($manifestFrom→$manifestTo)';

  @override
  String get networkInterrupted => 'החיבור לרשת נקטע במהלך ההורדה';
  @override
  String get compressedFileSizeLabel => 'גודל הקובץ הדחוס';
  @override
  String get compressedFileHashLabel => 'sha256 של הקובץ הדחוס';
  @override
  String get extractedFileSizeLabel => 'גודל הקובץ המחולץ';
  @override
  String get extractedFileHashLabel => 'sha256 של הקובץ המחולץ';
  @override
  String get patchExtractionFailed => 'חילוץ ה-patch נכשל או החזיר ריק';
  @override
  String get deleteExistingWithoutResumeIdentityFailed =>
      'מחיקת קובץ קיים ללא זהות resume נכשלה — לא ניתן להמשיך בהורדה';
  @override
  String get deletePartialFromPreviousVersionFailed =>
      'מחיקת קובץ חלקי מגרסה קודמת נכשלה — לא ניתן להמשיך בהורדה';
  @override
  String get deletePartialWithoutValidatorFailed =>
      'מחיקת קובץ חלקי ללא validator נכשלה — לא ניתן להמשיך בהורדה';
  @override
  String get deletePartialFromPreviousRepresentationFailed =>
      'מחיקת קובץ חלקי מייצוג קודם נכשלה — לא ניתן להמשיך בהורדה';
  @override
  String get deletePartialBeforeRetryFailed =>
      'מחיקת קובץ חלקי לפני ניסיון חוזר נכשלה — לא ניתן להמשיך בהורדה';
  @override
  String get deletePreviousArchiveFailed =>
      'מחיקת ארכיון קודם נכשלה — לא ניתן לחבר את חלקי ההורדה';
  @override
  String fullDbSizeMismatch(int downloaded, int expected) =>
      'גודל ה-DB שהורד ($downloaded) אינו תואם לצפוי ($expected)';
  @override
  String get fullDbHashMismatch => 'sha256 של ה-DB המלא אינו תואם';
  @override
  String joinedArchiveSizeMismatch(int written, int expected) =>
      'גודל הארכיון המחובר ($written) אינו תואם לצפוי ($expected)';
  @override
  String get joinedArchiveHashMismatch => 'sha256 של הארכיון המחובר אינו תואם';
  @override
  String resumeRoundLimit(int maxRounds, String url) =>
      'חידוש ההורדה חרג ממספר הסבבים המרבי ($maxRounds): $url';
  @override
  String contentLengthMismatch(int responseLength, int expectedSize) =>
      'Content-Length של ההורדה ($responseLength) אינו תואם לגודל הצפוי '
      '($expectedSize)';
  @override
  String truncatedBody(int declared, int received) =>
      'גוף ההורדה נקטע: Content-Length הצהיר $declared בייטים, '
      'אך התקבלו $received';
  @override
  String downloadHttpError(int statusCode, String url) =>
      'שגיאה בהורדה ($statusCode): $url';
  @override
  String resumeMadeNoProgress(String url) => 'חידוש ההורדה לא התקדם: $url';
  @override
  String resumeFailedAfterRetry(String url) =>
      'חידוש ההורדה נכשל לאחר ניסיון חוזר: $url';
  @override
  String downloadExceedsExpectedSize(int expectedSize) =>
      'ההורדה חורגת מהגודל הצפוי ($expectedSize בייטים)';
  @override
  String saveDownloadedFileFailed(String error) =>
      'שמירת הקובץ שהורד לדיסק נכשלה: $error';
  @override
  String tooManyRedirects(String url) => 'יותר מדי הפניות (redirects): $url';
  @override
  String writeResumeSidecarFailed(String path, String error) =>
      'כתיבת קובץ הזהות להמשך ההורדה נכשלה ($path): $error';
  @override
  String checksumMismatchDetailed(
    String label,
    String expected,
    String actual,
  ) =>
      '$label אינו תואם: צפוי $expected, התקבל $actual';
  @override
  String checksumMismatch(String label) => '$label אינו תואם';
  @override
  String localFileNotFound(String path) => 'קובץ מקומי לא נמצא: $path';
  @override
  String localFileTooLarge(int maxBytes, String path) =>
      'הקובץ המקומי חורג מהגודל הצפוי ($maxBytes בייטים): $path';
  @override
  String localSourceNotFound(String url) => 'קובץ מקור מקומי לא נמצא: $url';
  @override
  String localFileSizeMismatch(int expected, int actual, String url) =>
      'גודל הקובץ המקומי אינו תואם: צפוי $expected, בפועל $actual ($url)';
  @override
  String localFileHashMismatch(String url) =>
      'sha256 של הקובץ המקומי אינו תואם: $url';

  @override
  String get exportLoadingReleases => 'טוען רשימת גרסאות מ-GitHub';
  @override
  String get exportNoReleases => 'לא נמצאו releases עם עדכוני DB להורדה.';
  @override
  String exportPersonalFrom(int localVersion) =>
      'עדכון אישי: מוריד קובצי עדכון מגרסה $localVersion ומעלה, בלי המסד המלא';
  @override
  String exportPersonalUpToDate(int localVersion) =>
      'אין גרסה חדשה מ-$localVersion — לא הורד דבר';
  @override
  String exportReusingFullDb(int version, String tag) =>
      'המסד המלא שכבר בתיקייה (גרסה $version, $tag) נשמר — יש ממנו מסלול '
      'קובצי עדכון לגרסה האחרונה, ולכן אין צורך להוריד אותו שוב';
  @override
  String exportDownloading(String tag, String asset) => 'מוריד $tag / $asset';
  @override
  String exportVerifying(String tag, String asset, int percent) =>
      'מאמת $tag / $asset — $percent%';
  @override
  String exportAssembling(String tag, String asset, int percent) =>
      'מרכיב $tag / $asset מחלקיו — $percent%';
  @override
  String exportSplitFullDbSkipped(String tag, String detail) =>
      'המסד המלא של $tag פורסם בחלקים, אבל המניפסט של החלקים פגום או אינו '
      'תואם להם — ולכן הוא לא ירד ($detail)';
  @override
  String exportSplitPartCorrupted(String asset, String parts) =>
      'חלקים של $asset נקראו מהכונן שונים ממה שירד ($parts) — ייתכן שהכונן '
      'פגום. החלקים האלה נמחקו ולא נכתב דבר למראה; נסו שוב, והם יורדו מחדש.';
  @override
  String exportAssembledReplaceFailed(String path, String detail) =>
      'לא ניתן היה לשמור את $path אחרי שהורכב מחלקיו — ייתכן שתוכנה אחרת '
      '(למשל אנטי-וירוס) מחזיקה אותו. נסו שוב. ($detail)';
  @override
  String exportWritingManifest(String fileName) => 'כותב $fileName';
  @override
  String get exportDone => 'הושלם';
  @override
  String get exportCancelled => 'הייצוא בוטל';
  @override
  String get exporterDoesNotExtract =>
      'LibraryMirrorExporter מוריד קבצים בלבד ואינו מחלץ אותם';
  @override
  String exportManifestUnreadable(String asset, String detail) =>
      'ה-manifest $asset אינו קריא ולכן דולג ($detail)';
  @override
  String exportManifestFetchFailed(String asset, String detail) =>
      'הבאת ה-manifest $asset נכשלה גם אחרי ניסיונות חוזרים. ההורדה נעצרה כדי '
      'לא לכתוב מראה חסרה — נסו שוב כשהחיבור יציב. ($detail)';
  @override
  String exportPatchAssetMissing(String tag, String file) =>
      'הקובץ $file של $tag אינו זמין להורדה כרגע (ייתכן שהוא עוד עולה), '
      'ולכן מסלול העדכון דרכו לא ייכנס למראה';
  @override
  String exportSkippingUnappliablePatch(
    String tag,
    String file,
    int schemaVersion,
  ) =>
      'קובץ העדכון $file של $tag בנוי על סכמה $schemaVersion שאינה ניתנת '
      'להחלה, ולכן הוא אינו מועתק למראה';
  @override
  String exportSkippingUnsupportedPatchFormat(
    String tag,
    String file,
    int patchFormatVersion,
  ) =>
      'קובץ העדכון $file של $tag בנוי בפורמט $patchFormatVersion שאינו ניתן '
      'להחלה, ולכן הוא אינו מועתק למראה';
  @override
  String exportFullDbRequiredBySchema(int schemaVersion, int latestVersion) =>
      'גרסה $latestVersion משתמשת בפורמט מסד חדש (סכמה $schemaVersion): '
      'מוריד את המסד המלא במקום קובצי העדכון';
  @override
  String exportFullDbRequiredByPatchFormat(
    int patchFormatVersion,
    int latestVersion,
  ) =>
      'קובצי העדכון של גרסה $latestVersion בנויים בפורמט חדש '
      '($patchFormatVersion): מוריד את המסד המלא במקומם';
  @override
  String exportFullDbSchemaUnsupported(String tag, int schemaVersion) =>
      'המסד המלא של $tag פורסם רק בסכמה $schemaVersion, שגרסה זו של התוכנה '
      'אינה יודעת להתקין — הוא לא ירד, והמחשב הלא-מקוון יציג שנדרש עדכון '
      'תוכנה';
  @override
  String exportSkippingPatchesFullDbWins(int fileCount, int fullDbVersion) =>
      'מדלג על $fileCount קובצי עדכון: המסד המלא (גרסה $fullDbVersion) מגיע '
      'גבוה מכל שרשרת שאפשר להחיל, ולכן אין בהם צורך';
  @override
  String exportFullDbInsteadOfSlowPatches(
    int fileCount,
    int patchMinutes,
    int fullDbMinutes,
    int toVersion,
  ) =>
      'העדכון לגרסה $toVersion שינה את המסד מקצה לקצה: החלת קובצי העדכון שלו '
      'תארך כ-$patchMinutes דקות במחשב שמתעדכן, לעומת כ-$fullDbMinutes דקות '
      'של החלפת המסד המלא. מדלג על $fileCount הקבצים האלה ומוריד את המסד '
      'המלא במקומם';
  @override
  String exportPersonalNeedsFullDb(int fromVersion, int latestVersion) =>
      'אין מסלול קובצי עדכון שיכול להעביר את גרסה $fromVersion לגרסה '
      '$latestVersion, ולכן מוריד את המסד המלא — למרות ש"עדכון אישי" בדרך '
      'כלל מדלג עליו';
  @override
  String exportPersonalNoFullDbEither(int fromVersion, int latestVersion) =>
      'אין מסלול קובצי עדכון מגרסה $fromVersion לגרסה $latestVersion, וגם '
      'אין מסד מלא בגרסה האחרונה. יש לכבות את "עדכון אישי" בהגדרות ולהוריד '
      'שוב.';
  @override
  String mirrorNotEnoughDiskSpace(String dir, String needed, String free) =>
      'אין מספיק מקום פנוי ב-$dir להורדה: נדרשים $needed ופנויים $free. '
      'פנו מקום בכונן ונסו שוב — מה שכבר ירד נשמר.';
}
