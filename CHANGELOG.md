# Changelog

## Unreleased

- Split archive publication uses asynchronous rename, keeping disk I/O off the
  caller isolate. Cancellation is accepted until publication starts; a cancel
  during rename cannot turn successful publication into failure. Split-part and
  mirror cleanup finish each directory listing before deleting its entries.
- 0.9.1: split-archive assembly now checks cancellation between bounded 1 MiB
  reads/writes and keeps all downloaded parts until the verified archive is
  committed. A cancelled or failed join removes `.joining` output, allowing a
  retry to reuse complete parts. Failed size/hash checks invalidate cached part
  verification markers so corrupted retained content is checked again.
- Final assembly progress is delivered before the caller checks cancellation
  and atomically publishes the archive; cancellation from that final callback
  cannot publish an archive or turn an already committed result into failure.
  Local-copy and split-payload cleanup now use asynchronous file operations.
- Consumers of `downloadSplitToFile`/split `downloadReleaseAssetToFile` must
  reserve an additional full `SplitAsset.size` for staging, because the parts
  and assembled archive coexist until commit. Range-segment assembly overhead
  is unchanged; `LibraryMirrorExporter` already reserves the full split output.
- Split mirror assembly enforces part/archive limits before writes and verifies
  exact sizes before publication. It honors final-stage cancellation, closes
  handles before asynchronous cleanup, and preserves the old output until a
  verified replacement is ready. Disk preflight gives no credit to an unverified
  assembled output; cancelled/failed assembly retains valid parts for retry.

- `downloadToFile`: מחיקת שאריות הטווחים ומחיקת היעד בכשל אורך או sha256
  אסינכרוניות. מחיקה סינכרונית של טווח בגודל של כמה GB תקעה את ה-UI של אוצריא
  ל-17 שניות (Otzaria/otzaria#4070). `deleteSegmentFiles` נשאר סינכרוני.
- 0.9.0: `StreamingPatchDownloader` and the injectable `FileExtractor` contract
  share bounded file-to-file patch extraction between online and offline hosts.
  The decoder receives an exact output limit, cancellation and byte progress,
  and returns a digest computed while writing. Compressed input is still
  verified independently by `downloadToFile`; output size/digest are checked
  before a same-directory rename publishes a reusable patch.
- Extraction failures remove `.extracting` output. Cancellation and resource
  failures preserve verified/resumable input; `FormatException` and
  `PatchDownloadException` discard invalid compressed input. Reuse validates
  existing extracted files, while a fresh extraction needs no second hash pass.
  Whole-operation locks include decoding, verification and cleanup.
- `withFileOperationLock` exposes the downloader's fail-fast SQLite lock for a
  consumer's complete update/install/rollback operation, across isolates and
  processes. Lock sidecars are persistent and must not be removed.
- Local file copies reject source/destination aliases before deletion, enforce
  the input length while writing, verify the final length, and check cancellation
  after the last chunk. Existing in-memory APIs and DB/patch schemas are retained.
- Preserve the APIs and resume fixes consumed by Offline from
  `Yehuda-Zakesh/otzaria_library_updater@cd744641`: per-asset connections,
  separate assembly progress, per-part progress/baselines, split destination
  locks, reuse of stored segment plans, and exact remaining assembly space.
  Upstream asynchronous sidecar/state writes remain asynchronous. Legacy
  download observers retain their non-fatal progress-error behavior; streaming
  extraction observers stop the worker and propagate errors after teardown.
- Split downloads reject local sources that alias managed outputs, parts,
  sidecars or locks before cleanup. Assembly checks the byte budget before
  writing and rejects truncated segment files before recording completion.

- `LibraryUpdatePlan.blockReason` (`LibraryUpdateBlockReason`): סיווג מובנה של
  תוכנית `blocked`. `appUpdateRequired` כשהעדכון דורש סכמה או פורמט patch
  שהצרכן אינו מכיר, אחרת `other`. הצרכן מבחין בין המקרים בלי לנתח את `reason`
  (Otzaria/otzaria#3406).
- `PatchDownloader`: הורדה שנייה לאותו יעד בזמן שהראשונה רצה (בחלון אחר או
  בעותק אחר של אוצריא) מדווחת עכשיו `downloadAlreadyInProgress`, ולא כשל בכתיבת
  קובץ הזהות להמשך ההורדה (Otzaria/otzaria#3927).
- `PatchDownloader`: קובץ הצד (`.resume`), קובץ המצב של הטווחים (`.segments`)
  ובדיקות האורך והמחיקה בזמן ההורדה עברו ל-IO אסינכרוני. ב-Windows ה-isolate
  של ה-UI רץ על ה-thread של הפלטפורמה, ו-`writeAsStringSync(flush: true)` תקע
  את אוצריא באמצע הורדת ספרייה (Otzaria/otzaria#3780). `recordVerified` מחזיר
  עכשיו `Future<void>`.
- `downloadToFile`: כשהשרת מכבד `Range`, קובץ מרוחק של 64MB ומעלה
  (`segmentThresholdBytes`) יורד ב-`maxConnections` (ברירת מחדל 4) טווחים
  מקבילים, אחרי שהבקשה הראשונה מאשרת 206 עם הגודל הצפוי. שרת שעונה 200
  (כך עונים כרגע נכסי GitHub ברשת נטפרי) ננטש לפני הגוף, וההורדה ממשיכה
  בחיבור אחד. כל טווח ממשיך לבד אחרי קטיעה וגם אחרי הפעלה מחדש (`<dest>.segments`,
  `<dest>.seg-N`, כבולים לטוקן, לכתובת, לגודל, ל-sha256 ול-ETag), והטווחים
  מצורפים לפי הסדר ב-isolate. sha256 שגוי מקבל ניסיון נקי אחד.
  `maxConnections: 1` מבטל. `PatchDownloader.deleteSegmentFiles` מנקה שאריות.
  הורדה שנייה לאותו יעד נכשלת מיד (`<dest>.lock`) בלי לגעת בקבצים.
- נעילת יעד ההורדה חלה גם בין isolates ובין תהליכים דרך SQLite, בלי המתנה
  ובלי כתיבת נתונים. קובץ `<dest>.lock` נשאר ריק וקבוע אחרי השחרור; גם ניקוי
  המראה וטווחי הפיצול משמר אותו ואת תיקייתו, אף אם הנכס הוסר מהמניפסט.
- `LibraryMirrorExporter`: מקבל `maxConnections`/`segmentThresholdBytes`; סך
  החיבורים בייצוא עד `maxTotalConnections` (8), מחולק שווה בין משבצות ה-scheduler.
  בדיקת המקום הפנוי כוללת את הטווח הגדול ביותר של כל קובץ שיורד בטווחים.
- סכמת DB 7: `banner` (טקסטי הבאנר לפי מזהה קבוע), `book_banner` (`bookId` →
  `bannerId`), `book_protection`, `line_divine_name`, `line_note`
  (הערות השוליים של השורה: `lineId`, `noteIndex`, `charPos`, `hasMarker`, `body`)
  ו-`line_note_divine_name` (שמות הקודש בגוף ההערה, FK מורכב ל-`line_note`) הן
  טבלאות חוזה רגילות. `kSupportedDbSchemaVersion` = 7; `kPatchTablesInFkOrder`
  ו-`kHashTableOrderSchema7` (45 טבלאות) מוסיפים את ששתן, בסדר הזה, מיד לפני
  `schema_meta`; `hashTableOrderForSchemaVersion(7)` נתמך, והסדרים 1–6 קפואים.
  `kDefaultConsumerDbSchemaVersion` נשאר 5 — צרכן שקורא סכמה 7 מצהיר על כך.
- patch 6→7 הוא דלתא רגילה בפורמט 4: ה-`CREATE TABLE IF NOT EXISTS` של שש
  הטבלאות ב-`migrations` ואחריהן upserts. ה-hash לפני ההחלה בסדר סכמה 6 ואחריה
  בסדר סכמה 7. מחיקת `line`/`book` מתגלגלת אליהן ב-`ON DELETE CASCADE`, ומחיקת
  `line_note` מתגלגלת ל-`line_note_divine_name`.
- `line_note` ממופה ל-`booksTouched` דרך `line`; שינוי בטבלאות התצוגה
  (`banner`, `book_banner`, `book_protection`, `line_divine_name`,
  `line_note_divine_name`)
  לבדן אינו מסמן `hasChangesOutsideBooksTouched`.
- `patch_tables_contract.json` בסכמה 7, בלי הסעיף `optionalTables`.
- סכמת DB 7: `book.contentHash INTEGER NOT NULL DEFAULT 0` — טביעה אטומה של 64 ביט
  לטקסט השורות ולהערות של הספר (0 = לא ידוע). patch 6→7 מוסיף אותה ב-`ALTER TABLE
  … ADD COLUMN` שב-`migrations` ומעדכן את כל הספרים, ולכן `booksTouched` שלו כולל
  את כולם; ב-7→7 ספר נכנס ל-`booksTouched` כשהערך שלו השתנה. אין שינוי בקוד:
  העמודות של ה-upserts ושל ה-hash נקראות מה-DB.
- `downloadSplitToFile`: חיבור החלקים (קריאה, sha256 וכתיבה) רץ ב-isolate נפרד,
  אל קובץ זמני שעובר ל-`destPath` רק אחרי האימות. ה-API לא השתנה.
- אימות sha256 של קובץ שכבר שלם (`downloadToFile`) או ארכיון שכבר חובר
  (`downloadSplitToFile`) רץ ב-isolate נפרד; ביטול עדיין נתפס באמצע החישוב.
- ביטול נבדק גם עם חזרת ה-hash מה-isolate, כך שחישוב קצר שמסתיים בין
  דגימות הביטול אינו מדווח הצלחה ואינו מוחק את שרידי החלקים לפני resume.

### Hash לוגי

- **שינוי API ו-hash:** מסכמה 7 השורות של כל טבלה נכתבות לזרם ה-hash לפי
  המפתח הראשי שמוצהר ב-`kPatchTablesInFkOrder`, כמו `LogicalContentHasher.kt`;
  סכמות 1–6 שומרות על הכלל הקפוא (`id`, אחרת כל העמודות).
  `LogicalContentHasher.compute`/`computeReport` מקבלים `rowOrder` חובה (`null`
  רק לסכמה 6 ומטה), ש-`hashRowOrderForSchemaVersion` בוחר לפי סכמת ה-DB.
  ייצואים חדשים: `kHashRowOrder`, `kHashRowOrderBySchemaVersion`,
  `kPkRowOrderSchemaVersion`, `hashOrderByClause`, `hashRowOrderForSchemaVersion`.
- **שינוי hash:** ערכי REAL נכתבים לזרם ה-hash בפורמט `Double.toString` של
  Java (`1.0E-4`, `1.0E7`), כמו `LogicalContentHasher.kt`. עד עכשיו Dart כתב
  `0.0001`/`10000000.0`, וה-hash לא תאם ליצרן בכל טבלה עם ערך כזה.
  `javaDoubleToString` חדש.
- `FastSha256` / `Sha256Stream`: SHA-256 דרך CNG ב-Windows ו-CommonCrypto
  ב-macOS וב-iOS, עם בדיקה עצמית ונפילה ל-`package:crypto` (גם כשפתיחת חישוב
  נכשלת). `close()` אחרי `dispose()` זורק `StateError`. נטען בייבוא מותנה —
  בלי `dart:ffi` ב-web. בתי-הסוג של שורה נקראים כמסכה אחת; זרם הבתים זהה.

### גילוי ותכנון

- `parseVersionFromTag` מעוגן לתחילת ה-tag (`^v?(\d+)`): `lines-snapshot-sha256-…`
  כבר אינו גרסה 256. `LibraryUpdateDiscovery.releaseVersionOf` ציבורית.
- `LibraryRelease.fromJson` מתעלם מנכסים שעדיין עולים (`state` שאינו
  `uploaded`), ו-`fullDbAssetFor` מתעלם מ-DB מלא בגודל 0.
- `PatchEdge.hasSupportedSchema`/`hasSupportedPatchFormat`/`isApplicable`,
  `isSupportedSchemaVersion`, `isSupportedPatchFormatVersion`,
  `kHashTableOrderBySchemaVersion` והסדרים הקפואים מיוצאים.
- `LibraryUpdatePlan`: `fullDownloadFallback`, `followUpDelta`,
  `finalTargetVersion`, ו-`reason` גם בתוכנית delta.

### מסלול המראה המקומית (offline)

- `LibraryReleaseSource`, `LocalMirrorLibraryReleaseClient`,
  `LibraryMirrorExporter`, `DownloadScheduler`/`ByteProgressAggregator`,
  `DiskSpaceProbe`, `ApplyTimeEstimate`; `ReleaseAsset`/`LibraryRelease`
  מקבלים `toMirrorJson`/`fromMirrorJson`.
- `OfflineLibraryUpdateDiscovery`, `OfflineLibraryUpdatePlanner`,
  `OfflineLibraryDbRecoveryService` — מדיניות המראה, לצד המחלקות המקוונות שלא
  השתנו. הסכמה הנתמכת היא פרמטר חובה. `RecoveryAction.interrupted` הוא שם נוסף
  ל-`blockedMissingBackup`.
- `GithubLibraryReleaseClient` מממש `LibraryReleaseSource`, שולח User-Agent
  (`userAgent`), ו-`timeout` ניתן לשינוי.

### החלה והורדה

- `PatchApplier.apply(verifyToHash:)`; `PatchApplyResult.resultHash` הוא עכשיו
  `String?` (null כשהאימות כובה). התנגשות UNIQUE ב-upsert נזרקת כ-
  `PatchApplyException`, ו-`sqlite_stat4` מתנקה כשה-patch מחליף את `sqlite_stat1`.
- `PatchDownloader`: העתקה ממראה מקומית (נתיב במקום URL), `verifyExistingFile`,
  `recordVerified`, `storedResumeToken`, ו-`onVerifyProgress`/`onExistingBytes`
  ב-`downloadToFile`. קובץ הצד `.resume` מקבל שורה שלישית — סימון אימות
  `sha256|גודל|זמן-שינוי` — ונכס שלם שסימונו תואם אינו מגובב שוב. נכס שלם
  ופגום יורד מחדש במקום להיכשל; נכס שפורסם מחדש באותו תוכן נקשר לטוקן החדש.
  `connectTimeout`/`stallTimeout` ניתנים לשינוי.
- `LocalDbVersionReader`: מסד נעול או כתיבה שנקטעה נזרקים כ-
  `LocalDbUnreadableException` (במקום "אין גרסה"); מסד פגום מחזיר
  `hasVersionMeta=false`. `readInIsolate` ו-`busyTimeout` חדשים.

### מלל

- כל המלל עובר דרך `LibraryUpdaterMessages.current`, עם ברירת מחדל עברית
  זהה למלל הקודם; צרכן מציב מימוש משלו. החבילה מעבירה אותו ל-isolates שלה.
- `toString()` של `PatchApplyException` ו-`PatchDownloadException` הוא ההודעה
  עצמה, בלי קידומת שם המחלקה.

## 0.8.1

DB מלא מפוצל: כשה-DB המלא גדול ממגבלת ה-2 GiB לנכס ב-GitHub, SeforimLibrary
מפרסם אותו כ-`seforim-schema<N>.db.zst.part-NNN` ולצדם
`seforim-schema<N>.db.zst.manifest.json` (אותה צורה של `split_release_asset.sh`
באוצריא: גודל ו-sha256 לכל חלק ולשלם).

- `SplitAsset` / `SplitAssetPart`: פענוח ואימות של מניפסט הפיצול מול נכסי ה-release.
- `ReleaseAsset.split`, `isSplitFullDbManifest`, `advertisedFullDbSchemaVersion`.
  `fullDbAssetFor` בוחר גם מניפסט פיצול; קובץ יחיד גובר באותה סכמה.
- `GithubLibraryReleaseClient.resolveSplitAsset` — מניפסט ← נכס עם הגודל וה-sha256 של השלם.
  `LibraryUpdateDiscovery` מפענח את ה-DB המפוצל של ה-release האחרון; מניפסט
  פגום מבטל את ה-fallback המלא בלבד.
- `PatchDownloader.downloadSplitToFile`: כל חלק עם resume ו-sha256 משלו, חיבור
  שמוחק כל חלק אחרי צירופו ואימות ה-sha256 של השלם.
  `downloadReleaseAssetToFile` מכסה קובץ יחיד ומפוצל בקריאה אחת.

## 0.8.0

סכמת DB 6: פיצול `line` לטבלה צרה ול-`line_content(id, content)`, ו-
`version_line.content` שמותר בה NULL (NULL = זהה לטקסט הבסיס).

- `kSupportedDbSchemaVersion` = 6, ומיוצא עכשיו מה-barrel — כדי שהצרכן ידחה DB
  מלא שסכמתו חדשה מהנתמך ויבחר את שם ה-asset בהתקנה ראשונה.
- `kPatchTablesInFkOrder`: `line_content` (PK `id`, updatable) מיד אחרי `line`.
  patch של סכמה 5 אינו כולל `upsert_line_content` ומדולג כרגיל.
- סדרי hash קפואים: `kHashTableOrderSchema5` (זהה לסכמה 4) ו-
  `kHashTableOrderSchema6` (38 טבלאות, `line_content` אחרי `line`);
  `kHashTableOrder` מצביע על סכמה 6, ו-`hashTableOrderForSchemaVersion(6)` נתמך.
- שם ה-DB המלא: `seforim.db.zst` שמור לסכמה 5 ומטה; מסכמה 6 —
  `seforim-schema<N>.db.zst`. חדשים: `fullDbArchiveNameForSchema`,
  `ReleaseAsset.fullDbSchemaVersion`, `LibraryRelease.fullDbAssetFor`.
  `fullDbAsset` בוחר את הסכמה הגבוהה ביותר שנתמכת.
- `LibraryUpdateDiscovery`: פרמטר `supportedDbSchemaVersion`; release שה-DB
  המלא היחיד שלו בסכמה לא נתמכת אינו מספק fallback מלא.
- גילוי הגרסה האחרונה אינו תלוי בסכמה נתמכת או בהצלחת הורדת מניפסט:
  release עם DB מלא בלבד או מניפסט שאינו זמין עדיין מזוהה. להעברת סיבת
  "נדרש עדכון אפליקציה" ללא edge, מעבירים את
  `LibraryDiscoveryResult.latestDbSchemaVersion` לפרמטר האופציונלי
  `LibraryUpdatePlanner.plan(latestDbSchemaVersion:)`.
- מניפסט מחסום (`fullRebase: true`): לעולם אינו שלב במסלול דלתא. כשהוא יוצא
  מהמצב המקומי ואין מסלול רגיל, ה-planner מחזיר הורדה מלאה עם סיבה מפורשת,
  או סיבת "נדרש עדכון אפליקציה" כשסכמת היעד אינה נתמכת. לקוח ישן רואה את
  המחסום כ-edge לא נתמך (פורמט 999) ונחסם — לעולם לא מוריד סכמה 6.
- fixtures החוזה (`patch_tables_contract.json`, `logical_hash_contract.json`)
  עודכנו לסכמה 6.
- תמיכה בסכמה 6 היא הצהרה של הצרכן: ברירת המחדל של `LibraryUpdatePlanner`,
  `LibraryUpdateDiscovery` ו-`LibraryRelease.fullDbAsset` היא
  `kDefaultConsumerDbSchemaVersion` = 5. אפליקציה שקוראת `line_content` מעבירה
  `supportedDbSchemaVersion: 6`. build של קוד אפליקציה ישן מול `ref: main` צף
  לא יוריד DB בסכמה 6. ה-planner גם מתעלם מ-DB מלא בסכמה שאינה נתמכת.

## 0.7.0

החלת patch מהירה יותר, ו-sqlite_stat1 מגיע גם ללקוחות שמתעדכנים בדלתא.

- `PatchApplier`: פרמטרי בנאי `cacheSizeKib` (ברירת מחדל 256MB, לשלב
  ה-upserts/deletes) ו-`hashCacheSizeKib` (ברירת מחדל 64MB, לחישובי ה-hash),
  ו-`temp_store=FILE`. מיון ה-hash של `version_line` לא נשמר עוד כולו בזיכרון.
  ב-Android רק כש-`sqlite3.tempDirectory` (או `TMPDIR`) מוגדר, אחרת SQLite
  לא מוצא היכן לפתוח קובץ זמני.
- upsert של שורה זהה לקיימת כבר לא כותב אותה. ההשוואה מבחינה גם בסוג הערך
  וברישיות, כמו ה-hash. `PatchApplyResult.upserts` סופר רק שורות שנוספו או
  השתנו בפועל.
- ה-patch מוצמד לקריאה בלבד (`mode=ro`), והחיבור נפתח עם `uri: true`.
  כשל בפתיחת ה-patch (קובץ חסר או שאינו SQLite) נזרק כ-`PatchApplyException`,
  והשגיאה המקורית נשמרת ב-`cause` החדש.
- מעבר ה-`count(*)` הנפרד הוסר: גבולות המנות וספירת השורות נאספים יחד לפני
  ה-transaction. חוזה `onApplyProgress` לא השתנה.
- טבלת `stat1_snapshot` ב-patch (אופציונלית) מחליפה את `sqlite_stat1` בתוך
  ה-transaction. patch בלעדיה משאיר את הסטטיסטיקות הקיימות, ו-applier ישן
  מתעלם ממנה.

## 0.6.0

ניסיון חוזר אוטומטי אחרי קטיעת רשת, עם המשך מהנקודה שנעצרה (Otzaria issue #1244).

- `PatchDownloader`: פרמטר בנאי `networkRetryDelays` (ברירת מחדל
  `defaultNetworkRetryDelays` = 2s, 5s, 15s). קטיעת רשת חולפת — `SocketException`, `HandshakeException`,
  `HttpException`, `TimeoutException` (חיבור או זרם תקוע) או `http.ClientException`
  — מנוסה שוב לפי הרשימה. ב-`downloadToFile` הניסיון החוזר ממשיך מהחלקי דרך
  `Range`/`If-Range` כשהוא ניתן-לחידוש (validator שמור), ואחרת מתחיל מאפס;
  ב-`downloadAndExtract` ה-patch הקטן מורד מחדש. ביטול נתפס גם באמצע ההשהיה.
  שגיאות פרוטוקול ואימות (קוד HTTP, sha256, גודל) אינן מנוסות שוב.
- `PatchNetworkException`: נזרק כשגם הניסיונות החוזרים נכשלו, עם `cause` =
  החריגה המקורית והודעה עברית קצרה. הוא נפרד מ-`PatchDownloadException`, כדי
  שצרכן שמוחק נכס פגום לא ימחק partial תקין בעקבות כשל רשת. קובץ חלקי
  ניתן-לחידוש נשמר, כך שקריאה חוזרת ממשיכה אותו.
- אחרי קטיעה, sha256 של הורדה גדולה אינו מחושב מחדש על כל ה-partial לפני כל
  ניסיון; הקובץ המוגמר מאומת במעבר יחיד לאחר הצלחת ה-retry.
- `PatchDownloader.isTransientNetworkError(error)` — הסיווג חשוף לצרכנים.

## 0.5.0

התקדמות אמיתית בהחלת patch, ותכנון שמביא בחשבון את עלות ההחלה ולא רק את
גודל ההורדה (Otzaria issue #1211).

- `PatchDownloader.downloadAndExtract`: פרמטר אופציונלי
  `onVerifyProgress(bytesDone, bytesTotal)` לדיווח על קידום אימות ה-sha256 של
  הקובץ המחולץ. המימוש הבסיסי אינו קורא לו; הוא קיים כדי שמימוש יורש (כמו
  ההורדה הזורמת באוצריא) יוכל להציג מד על אימות קובץ של כמה GB.
- `PatchApplier.apply`: פרמטר `onApplyProgress(rowsDone, rowsTotal)`.
  `rowsTotal` נספר פעם אחת לפני ה-transaction — סך השורות בכל טבלאות
  `upsert_*`/`delete_*` שיעובדו בפועל. הקריאה הראשונה היא `(0, rowsTotal)`
  בתחילת שלב `upserts`, ואחריה קריאה אחרי כל מנה, לאורך `upserts` ו-`deletes`
  יחד. ויסות הדיווח הוא באחריות הקורא.
- `PatchApplier`: פרמטר בנאי `applyChunkSize` (ברירת מחדל
  `kDefaultApplyChunkSize` = 50,000). ה-upserts וה-deletes רצים כעת במנות של
  טווחי `rowid` בטבלת ה-patch, באותו transaction ועם `defer_foreign_keys=ON`,
  ולכן מצב הסיום זהה ל-statement יחיד. טבלת patch שהוגדרה `WITHOUT ROWID`
  נופלת אוטומטית למסלול ה-statement היחיד.
- `LibraryUpdatePlanner.plan`: פרמטר `localDbSizeBytes`. כשהוא ידוע ומסלול
  הדלתא פורס יותר מ-`maxDeltaUncompressedRatio` מגודל ה-DB המקומי
  (ברירת מחדל `kDefaultMaxDeltaUncompressedRatio` = 0.25), התוכנית נשארת
  `delta` אך מסומנת ב-`heavyDeltaReason` — החלת upserts על DB מאונדקס יקרה
  בהרבה מכתיבה סדרתית של קובץ. הבחירה בין דלתא ארוכה להורדה מלאה נשארת של
  המשתמש; הסימון מוצג בין אם יש DB מלא זמין ובין אם לא. `localDbSizeBytes`
  null או 0 — התנהגות ללא שינוי.
- `LibraryUpdatePlan`: שדה `heavyDeltaReason` (טקסט עברי עם הגדלים) ו-
  `isHeavyDelta`. `fullDbAsset`/`fullDbReleaseTag`/`toFullDownloadFallback`
  זמינים גם בתוכנית כזו, כדי שהצרכן יוכל להחליף מסלול.
- `LibraryUpdatePlanner`: שדה `maxDeltaUncompressedRatio`.
- `LibraryUpdatePlan.deltaUncompressedBytes` ו-`PatchEdge.uncompressedSize` —
  הגודל הפרוס, לתצוגה ולהחלטה. 0 בתוכנית שאינה דלתא.

## 0.4.0

hash תוכן לוגי לכל טבלה — אימות אחרי apply רק על הטבלאות שהשתנו, במקום
הזרמת כל ה-DB (‏~80% מ-6GB) בכל צעד בשרשרת.

- `LogicalContentHasher.computeReport` — מעבר יחיד שמחזיר גם את ה-hash הכולל
  וגם `tableHashes`/`tableBytes` לכל טבלה. `tableHash(t)` הוא sha256 של בדיוק
  הבתים שהטבלה תורמת לזרם הכולל (כולל הקידומת `" table:<t> "`), ולכן
  `wholeHash == sha256` של שרשור הזרמים. `compute` נשאר עם אותה חתימה ומאציל.
  `only` מבקש תת-קבוצה של טבלאות, ואז `wholeHash` הוא null.
- `DeltaManifest`: שדות אופציונליים `fromTableContentHashes` ו-
  `toTableContentHashes` (מפה `<table> -> <hex>`). שניהם יחד או אף אחד —
  מניפסט שנושא רק אחד מהם נקרא כאילו אין מפות; ערך קיים שאינו מפה של מחרוזות
  לא ריקות זורק `FormatException`.
- `PatchApplier.apply`: כש-`enablePartialTableVerification: true` והמניפסט
  נושא שתי מפות שמפתחותיהן הם בדיוק סדרי ה-hash של
  `fromSchemaVersion`/`toSchemaVersion`, שלב `verifyToHash` מאמת רק
  `{טבלאות ש-from≠to} ∪ {טבלאות שה-patch נגע בהן} ∪ {schema_meta}`. אחרת —
  אימות ה-DB המלא בדיוק כמו קודם.
- `PatchApplyResult`: ‏`verifiedTables`, `deferredTables` (הטבלאות שדולגו,
  לאימות אחרי ה-commit) ו-`verifyTableBytes` (רמז התקדמות לריצה הבאה).
  `apply` מקבל `verifyTableBytesHint` שקובע את ה-total של מד ההתקדמות.
- `PatchApplyException.mismatchedTables` — שמות הטבלאות שלא תאמו, כשהאימות
  היה לפי טבלאות (null באימות מלא). כל אי-התאמה עדיין גוררת ROLLBACK.
- `PatchApplier.verifyTableHashes` — אימות קריאה-בלבד של טבלאות נבחרות מול
  מפה נתונה, ללא transaction. נועד לצרכן שרוצה לאמת את `deferredTables`
  אחרי שה-commit הסתיים והספרייה כבר קריאה.
- `test/logical_hash_contract.json` — oracle משותף עם צד ה-Kotlin (עותק זהה
  אות-באות), נאכף ב-`contract.yml` ב-`cmp`.

## 0.3.0

תמיכה בסכמת patch 4 — טבלאות `line_ref` (אינדקס הפניות קנוני) ו-`line_dh`
(אינדקס דיבורי-המתחיל), וחיסון הלקוח מול שדרוגי סכמה עתידיים.

- `kPatchTablesInFkOrder`: נוספו `line_ref` (junction טהורה,
  PK ‏`bookId, refKeyHash, lineIndex`) ו-`line_dh` (PK ‏`bookId, dhText,
  lineIndex`) מיד אחרי `line_toc` — אותו מיקום כמו בצד הקוטליני.
- סדר ה-hash של סכמה-3 הוקפא כ-`kHashTableOrderSchema3` (35 טבלאות);
  `kHashTableOrder` הנוכחי (סכמה 4) כולל את `line_ref` ו-`line_dh` —
  37 טבלאות.
- חוזי היכולת הופרדו: `kSupportedDbSchemaVersion` לסכמת ה-DB הלוגית,
  ו-`kSupportedPatchFormatVersion` לפורמט `patch.db`. מניפסט חדש יכול לפרסם
  `patchFormatVersion`; החל מ-DB schema 4 השדה חובה וקשור ב-preflight בדיוק
  ל-`patch_meta.schema_version`. רק מניפסט היסטורי של schemas 1–3 רשאי
  להשמיטו.
- `LibraryUpdatePlanner` מסנן בנפרד סכמת DB לוגית ופורמט artifact. כששדה
  `patchFormatVersion` קיים, edge שדורש יכולת חדשה נפסל לפני הורדה; במניפסט
  היסטורי ללא השדה, `PatchApplier` נשאר שער ה-preflight והאפליקציה יכולה
  לעבור ל-full-download fallback.
- מסלול דלתא נשמר רציף גם ברמת הסכמה: `toSchemaVersion` של כל צעד חייב
  להתאים ל-`fromSchemaVersion` של הבא; `localSchemaVersion` הוא פרמטר חובה
  (nullable רק ל-DB ישן) כדי שה-planner יאמת גם את הצעד הראשון ולא יוריד
  patch שה-applier עתיד לדחות.
- תלות rollout מחייבת: לפני פרסום schema 4, צד Kotlin ב-SeforimLibrary חייב
  לכתוב `patchFormatVersion = PatchDbSchema.CURRENT_VERSION` בכל manifest.
  ללא השדה updater 0.3.0 דוחה את המניפסט fail-closed; הכתיבה תתווסף ל-PR 20
  לפני ששער ה-stamp מאפשר release.
- `booksTouched`/`hasChangesOutsideBooksTouched`: ‏`line_ref` ו-`line_dh`
  מוחרגות במכוון — אינדקסים נגזרים, לא תוכן חיפוש; שינוי בהן לבדן אינו
  דורש רענון אינדקס.

## 0.2.0

fallback להורדה מלאה כשתוכן ה-DB המקומי סטה מהקנוני.

- `PatchApplyException.isContentMismatch` — מבחין כשל hash (from/to) מכשלי
  preflight אחרים, כדי שהצרכן יציע הורדה מלאה במקום לולאת נסה-שוב;
  `hashMismatchStage` שומר אם הכשל היה ב-from או ב-to לצורכי אבחון.
- `LibraryUpdatePlan`: תוכניות דלתא נושאות את ה-DB המלא כ-fallback
  (`toFullDownloadFallback`), רק כאשר הוא שייך לגרסת היעד.

## 0.1.0

גרסה ראשונית — הוצאה מ-`otzaria/lib/library_update/` לחבילת Dart עצמאית.

- **מקור:** commit `d6d4e9facf5da322e83bdfbc199b899d3b210915` בריפו Otzaria.
- מנוע צריכת הפצות SeforimLibrary: מודלים, גילוי/תכנון מסלול, הורדה ואימות,
  hash לוגי (תואם `LogicalContentHasher.kt` של Kotlin), והחלת patch אטומית.
- חבילת Dart טהורה — ללא תלות ב-Flutter. חילוץ zstd מוזרק על-ידי הצרכן.
