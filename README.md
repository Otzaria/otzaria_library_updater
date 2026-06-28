# seforim_library_updater

לקוח Dart לצריכת הפצות הדלתא של [`Otzaria/SeforimLibrary`](https://github.com/Otzaria/SeforimLibrary).

החבילה היא צד‑הלקוח של פורמט ההפצה: היא מגלה גרסאות ב‑GitHub Releases, בוחרת מסלול עדכון
(דלתא או הורדה מלאה), מורידה ומאמתת קובצי `patch-vX-vY.db.zst`, מחילה אותם אטומית על ה‑DB
המקומי, ומוודאת שטביעת‑האצבע הלוגית (hash) של התוצאה תואמת למה שה‑Kotlin ייצר.

> **לא יצרן — צרכן.** מאגר ה‑Kotlin (`SeforimLibrary`) מייצר את ה‑DB וההפרשים; חבילה זו
> צורכת אותם. שני רכיבים כאן הם תרגום ישיר של לוגיקת ה‑Kotlin וחייבים להסכים איתה בית‑בית:
> `LogicalContentHasher` (תואם `LogicalContentHasher.kt`) ו‑`PatchApplier`.

## חבילת Dart טהורה

אין תלות ב‑Flutter. חילוץ zstd **מוזרק** על‑ידי הצרכן (ל‑`PatchDownloader.decompress`),
כדי שהחבילה תישאר אגנוסטית לפלטפורמה.

## ⚠️ פעולות חוסמות — הרץ ב‑Isolate

`LogicalContentHasher.compute` ו‑`PatchApplier.apply` הן **סינכרוניות וכבדות** (חישוב ה‑hash
עשוי להימשך עשרות שניות על DB מלא). **אל תריץ אותן על ה‑UI isolate** — עטוף ב‑`Isolate.run`:

```dart
await Isolate.run(() => const PatchApplier().apply(/* ... */));
```

## בדיקות

- **fixtures inline** — הבדיקות בונות DB זעירים בזיכרון (`openInMemory`), כולל golden hash
  קבוע ומקרה BOM; רצים תמיד ולוכדים רגרסיה בחוזה מול Kotlin.
- **בדיקות מול הפצות אמיתיות** — אופציונליות, מופעלות כשמשתנה הסביבה
  `SEFORIM_LIBRARY_RELEASES_DIR` מצביע לתיקייה עם `v1/`, `v2/`, `v3/`. אחרת מדלגות.

```bash
dart test                                   # fixtures בלבד
SEFORIM_LIBRARY_RELEASES_DIR=/path/to/releases dart test   # + חוזה מלא
```
