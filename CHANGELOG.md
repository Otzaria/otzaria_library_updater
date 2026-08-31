# Changelog

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
