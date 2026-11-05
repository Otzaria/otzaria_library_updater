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

## Streaming extraction (0.9.0)

Hosts with a native streaming decoder should use
`StreamingPatchDownloader(extractor: extractFile)` for remote and local delta
assets. The existing `PatchDownloader(decompress: ...)` API remains available
for compatibility. `downloadToFile` is already streamed in both classes.

The shared `FileExtractor` contract is:

```dart
Future<FileExtractionResult> extractFile(
  String sourcePath,
  String outputPath, {
  required int maxOutputBytes,
  bool Function()? isCancelled,
  void Function(int bytesWritten)? onProgress,
});
```

The decoder must reject an output chunk **before writing past the limit**, await
each write, and use bounded input/output buffers and a bounded native decoding
window. Check cancellation between output chunks, including inside a single
highly compressed input chunk. Return `FileExtractionResult(bytesWritten: ...,
sha256: ...)` only after the complete compressed stream has been validated, the
output has been flushed and all handles have closed. Compute SHA-256 while
writing (the exported `Sha256Stream` provides an incremental implementation).
The host owns platform library loading and must run CPU-heavy decoding/hashing
outside its UI isolate.

Cancellation must throw `PatchDownloadCancelled`. Invalid compressed data must
throw `FormatException` or `PatchDownloadException`. Use a different type for
resource failures (for example `StateError`); such failures preserve the verified
archive for retry. The downloader removes incomplete output on every failure,
checks the reported digest and the actual output length, and only then renames
the output into its reusable cache path. A fresh extraction does not re-read the
output to hash it. Reusing an old cache file always verifies its hash from disk.

`onExtractionProgress(written, total)` distinguishes extraction from compressed
download progress. For existing callers supplying only `onVerifyProgress`, that
callback receives progress of the streamed output hash as well. Final callbacks
and cancellation checks run before publication. A process crash can leave an
`.extracting` file; it is never reused and is removed before retrying.

For complete archives without a declared output size, hosts can use the
configurable `kDefaultMaxExtractedBytes` ceiling (64 GiB). A patch always uses
its exact manifest size. This is an output/disk limit, separate from the native
decoder's memory/window limit.

Consumers can protect a complete install/rollback pipeline with
`withFileOperationLock(dbPath, () async { ... })`. Create the parent directory
first, and use a shared key for any pipeline sharing staging paths. Hold the
lock until all worker futures and cleanup have completed. The lock is fail-fast,
non-reentrant, and works across isolates/processes; never delete its `.lock`
sidecar or nest `downloadToFile` for that same destination. A separate archive
path is safe. Database replacement and DB-level verification remain the host's
responsibility; the shared downloader only publishes verified patch files.

נדרש Dart ‏3.10 ומעלה לצריכת החבילה, בהתאם לדרישה של `sqlite3` שכבר הייתה
תלות בחבילה. להרצת כלי הפיתוח והבדיקות העדכניים נדרש Dart ‏3.11 ומעלה.
גרסאות `sqlite3` ו־`ffi` המינימליות מיושרות לגרסאות שבאוצריא; העדכון אינו
מעלה את דרישות מערכות ההפעלה של הבינאריים הרשמיים של SQLite.

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
