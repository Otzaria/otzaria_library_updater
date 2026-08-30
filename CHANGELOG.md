# Changelog

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
