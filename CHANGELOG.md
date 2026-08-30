# Changelog

## 0.3.0

תמיכה בסכמת patch 4 — טבלת `line_ref` (אינדקס הפניות קנוני), וחיסון הלקוח
מול שדרוגי סכמה עתידיים.

- `kPatchTablesInFkOrder`: נוספה `line_ref` (junction טהורה,
  PK ‏`bookId, refKeyHash, lineIndex`) מיד אחרי `line_toc` — אותו מיקום כמו
  בצד הקוטליני.
- סדר ה-hash של סכמה-3 הוקפא כ-`kHashTableOrderSchema3` (35 טבלאות);
  `kHashTableOrder` הנוכחי (סכמה 4) כולל את `line_ref` — 36 טבלאות.
- `kSupportedPatchSchemaVersion` (=4) — קבוע משותף ל-`PatchApplier`
  ול-`LibraryUpdatePlanner`, כך ששניהם מסכימים תמיד.
- `LibraryUpdatePlanner` מודע לגרסת הסכמה: edges שדורשים סכמה חדשה מהנתמכת
  נפסלים מהגרף, והלקוח מתכנן הורדה מלאה (עם סיבה שמציינת שנדרש עדכון
  אפליקציה) במקום להוריד patch שיידחה ב-preflight בלי מוצא.
- `booksTouched`/`hasChangesOutsideBooksTouched`: ‏`line_ref` מוחרגת במכוון —
  אינדקס ניווט, לא תוכן חיפוש; שינוי בה לבדה אינו דורש רענון אינדקס.

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
