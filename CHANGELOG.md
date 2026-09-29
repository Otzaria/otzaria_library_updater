# Changelog

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
