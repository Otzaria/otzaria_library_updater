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

## DB מלא בפורמט zdb ו-VFS

מסכמה 6 ה‑DB המלא מופץ כ‑`seforim-schema<N>.zdb` — קובץ SQLite דחוס לפי דפים — יחד עם
`seforim-schema<N>.zdb.manifest.json` (`FullDbManifest`). ה‑zdb אינו מחולץ: הוא נקרא כמות שהוא
דרך ה‑VFS של האפליקציה (`otzaria_zvfs`), וכתיבות נשמרות ב‑overlay שלצדו (`<db>-zovl`).

**החבילה אגנוסטית ל‑VFS.** היא פותחת כל DB ב‑`sqlite3.open` עם ה‑VFS שמוגדר כברירת מחדל,
ואינה תלויה ב‑`otzaria_zvfs`. לכן לפני כל שימוש בחבילה על zdb — גילוי ה‑DB המקומי, `PatchApplier`,
`LogicalContentHasher`, `checkDbHealthAfterCrash` — **האפליקציה חייבת לרשום את zvfs כ‑VFS ברירת
המחדל** (`makeDefault`), בכל isolate שבו הקוד רץ. אימות ה‑zdb, התקנתו וקריאת הגודל הלוגי שלו
נשארים באפליקציה; ל‑`PatchApplier` מעבירים `logicalSizeOf` כדי שמדי ההתקדמות יתבססו על הגודל
הלוגי ולא על הקובץ הפיזי הקטן.

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
  `SEFORIM_LIBRARY_RELEASES_DIR` מצביע לתיקייה עם `v14/seforim.db` ו‑
  `v15/{seforim.db, patch-v14-v15.db, patch-v14-v15r.db}`. אחרת מדלגות.

```bash
dart test                                   # fixtures בלבד
SEFORIM_LIBRARY_RELEASES_DIR=/path/to/releases dart test   # + חוזה מלא
```
