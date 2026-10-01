import 'dart:io';

import 'package:seforim_library_updater/src/sqlite/sqlite3_api.dart' as sqlite3;

import '../models/delta_manifest.dart';
import '../models/patch_table_spec.dart';
import 'logical_content_hasher.dart';

/// הטבלאות ששינוי בהן ממופה למזהי ספרים ב-[PatchApplyResult.booksTouched].
/// חייב להישאר תואם ל-queries ב-`PatchApplier._collectBooksTouched`.
///
/// `line_ref` ו-`line_dh` (סכמה 4) מוחרגות במכוון: הן אינדקסים נגזרים
/// (הפניה→שורה, דיבור-המתחיל→שורה) ולא תוכן שנכנס לאינדקס החיפוש, ושינוי
/// בהן לבדן לא צריך לגרור רענון אינדקס לספר — שינוי תוכן אמיתי מגיע תמיד
/// דרך `line` / `line_content` שכבר מכוסות.
const Set<String> kBooksTouchedTables = {
  'book',
  'line',
  'line_content',
  'tocEntry',
  'line_toc',
  'tocText',
  'alt_toc_structure',
  'alt_toc_entry',
  'line_alt_toc',
  'book_author',
  'book_base_text',
  'book_topic',
  'book_acronym',
};

/// גודל מנת ה-upsert/delete בשורות. ראו [PatchApplier.applyChunkSize].
const int kDefaultApplyChunkSize = 50000;

/// תקרת ה-page cache בשלב ה-upserts/deletes, ב-KiB. ראו [PatchApplier.cacheSizeKib].
const int kDefaultApplyCacheSizeKib = 256 * 1024;

/// cache_size בזמן חישוב ה-hash, ב-KiB. ראו [PatchApplier.hashCacheSizeKib].
const int kDefaultHashCacheSizeKib = 64 * 1024;

/// שם הטבלה ב-patch שנושאת את `sqlite_stat1` של ה-DB היעד.
const String kPatchStat1SnapshotTable = 'stat1_snapshot';

/// URI של SQLite לפתיחת [path] לקריאה בלבד. `file:////host/share` שומר על
/// נתיב UNC; רק `%`, `?` ו-`#` מקודדים, והיתר עובר כ-UTF-8 כפי שהוא.
String readOnlyFileUri(String path) {
  var p = File(path).absolute.path;
  // מחוץ ל-Windows לוכסן הפוך הוא תו רגיל בשם קובץ.
  if (Platform.isWindows) p = p.replaceAll('\\', '/');
  if (!p.startsWith('/')) p = '/$p';
  p = p.replaceAll('%', '%25').replaceAll('?', '%3F').replaceAll('#', '%23');
  return 'file://$p?mode=ro';
}

/// מנות ה-rowid של טבלת patch אחת. [ranges] null — אין rowid, statement יחיד.
class _ChunkPlan {
  final int rows;
  final List<({int lo, int hi, int rows})>? ranges;

  const _ChunkPlan(this.rows, this.ranges);
}

/// מונה שורות ה-patch שהוחלו, משותף לשלבי ה-upserts וה-deletes.
class _ApplyProgress {
  final Map<String, _ChunkPlan> plans;
  final void Function(int rowsDone, int rowsTotal)? _callback;
  final int total;
  int _done = 0;

  _ApplyProgress(this.plans, this._callback)
      : total = plans.values.fold<int>(0, (a, p) => a + p.rows);

  void advance(int rows) {
    _done += rows;
    emit();
  }

  void emit() => _callback?.call(_done, total);
}

/// תוצאת החלת patch מוצלחת.
class PatchApplyResult {
  final int migrations;

  /// שורות שנוספו או השתנו בפועל, לכל טבלה. שורת patch זהה לקיימת לא נספרת.
  final Map<String, int> upserts;
  final Map<String, int> deletes;

  /// ה-hash הכולל של ה-DB אחרי ה-apply. באימות חלקי לא חושב בפועל — זה
  /// `toContentHash` שבמניפסט.
  final String resultHash;

  /// מזהי הספרים שתוכן האינדקס שלהם הושפע מה-patch — שינויים בטבלאות
  /// [kBooksTouchedTables] בלבד (book/line/TOC כולל tocText ו-alt-TOC,
  /// ושיוכי מחבר/נושא/ראשי-תיבות). מאפשר רענון אינדקס לספרים שהשתנו בלבד.
  ///
  /// זו לא רשימת "כל מה שמשפיע על חיפוש": שינוי בטבלה שאינה מכוסה (למשל
  /// שינוי שם ב-author/topic/category) לא ממופה לספרים, ו-[upserts]/[deletes]
  /// נותנים ספירות בלבד — אי אפשר לגזור מהם מזהים. צרכן שהאינדקס שלו תלוי
  /// בטבלאות כאלה צריך להתייחס ל-[hasChangesOutsideBooksTouched] כ-trigger
  /// לרענון מלא.
  final Set<int> booksTouched;

  /// הטבלאות שאומתו בפועל מול `toTableContentHashes`. באימות DB מלא — ריק.
  final List<String> verifiedTables;

  /// הטבלאות שדולגו כי ה-patch לא נגע בהן וה-hash שלהן זהה ב-from וב-to.
  /// הצרכן יכול לאמת אותן אחרי ה-commit (ראו [PatchApplier.verifyTableHashes]).
  final List<String> deferredTables;

  /// מספר הבתים שהוזרמו ל-SHA לכל טבלה שאומתה — רמז התקדמות לריצה הבאה.
  final Map<String, int> verifyTableBytes;

  /// האם ה-patch שינה טבלאות שאינן מכוסות ב-[booksTouched] (מלבד schema_meta,
  /// שמתעדכן בכל patch, ו-line_ref/line_dh, שאינן תוכן חיפוש — ראו
  /// [kBooksTouchedTables]). כש-true, צרכן שהאינדקס שלו תלוי בטבלאות האלה
  /// צריך רענון מלא — אין דרך לגזור מהן מזהי ספרים מדויקים.
  bool get hasChangesOutsideBooksTouched {
    const ignored = {'schema_meta', 'line_ref', 'line_dh'};
    bool changed(MapEntry<String, int> e) =>
        e.value > 0 &&
        !ignored.contains(e.key) &&
        !kBooksTouchedTables.contains(e.key);
    return upserts.entries.any(changed) || deletes.entries.any(changed);
  }

  const PatchApplyResult({
    required this.migrations,
    required this.upserts,
    required this.deletes,
    required this.resultHash,
    this.booksTouched = const {},
    this.verifiedTables = const [],
    this.deferredTables = const [],
    this.verifyTableBytes = const {},
  });
}

/// השלב שבו hash לוגי לא תאם לערך שב-manifest.
enum PatchHashMismatchStage {
  /// ה-DB לפני apply לא תאם ל-fromContentHash.
  fromContentHash,

  /// התוצאה לפני commit לא תאמה ל-toContentHash.
  toContentHash,
}

/// נזרק כאשר preflight או אימות נכשלים — ה-DB לא שונה (לא בוצע commit).
class PatchApplyException implements Exception {
  final String message;

  /// true כשה-hash הלוגי אינו תואם (from או to), ולכן אין לסמוך על מסלול
  /// הדלתא ויש להציע fallback להורדה מלאה.
  ///
  /// אי-התאמת toContentHash אינה מוכיחה לבדה שהמקור המקומי סטה: היא עשויה
  /// להעיד גם על patch/manifest לא עקביים או על באג ב-applier. ראו
  /// [hashMismatchStage] לאבחון מדויק.
  final bool isContentMismatch;

  /// null בכשל שאינו hash; אחרת מציין איזה אימות hash נכשל.
  final PatchHashMismatchStage? hashMismatchStage;

  /// שמות הטבלאות שה-hash שלהן לא תאם, כשהאימות היה לפי טבלאות. null אחרת.
  final List<String>? mismatchedTables;

  /// השגיאה המקורית, כשהכשל עטוף (למשל פתיחת קובץ ה-patch).
  final Object? cause;

  const PatchApplyException(
    this.message, {
    bool isContentMismatch = false,
    this.hashMismatchStage,
    this.mismatchedTables,
    this.cause,
  }) : isContentMismatch = isContentMismatch || hashMismatchStage != null;
  @override
  String toString() => 'PatchApplyException: $message';
}

/// בוחר את סדר ה-hash לפי גרסת הסכמה: 1 → [kHashTableOrderSchema1] (33),
/// 2 → [kHashTableOrderSchema2] (34), 3 → [kHashTableOrderSchema3] (35),
/// 4 → [kHashTableOrderSchema4], 5 → [kHashTableOrderSchema5] (37),
/// 6 → [kHashTableOrderSchema6] (38), 7 → [kHashTableOrderSchema7] (39, הנוכחי).
/// כל ערך אחר → זריקה (fail loudly).
List<String> hashTableOrderForSchemaVersion(int schemaVersion) {
  switch (schemaVersion) {
    case 1:
      return kHashTableOrderSchema1;
    case 2:
      return kHashTableOrderSchema2;
    case 3:
      return kHashTableOrderSchema3;
    case 4:
      return kHashTableOrderSchema4;
    case 5:
      return kHashTableOrderSchema5;
    case 6:
      return kHashTableOrderSchema6;
    case 7:
      return kHashTableOrderSchema7;
    default:
      throw PatchApplyException(
        'גרסת סכמה $schemaVersion אינה נתמכת לבחירת סדר hash',
      );
  }
}

/// מחיל patch DB דלתאי על `seforim.db` בצורה אטומית, ומשכפל את
/// `PatchApplier.kt` בצד הייצור.
///
/// הזרימה: preflight (גרסה/סכמה/hash) → ATTACH → migrations → upserts (סדר FK)
/// → deletes (סדר FK הפוך) → foreign_key_check → אימות `toContentHash` →
/// COMMIT. כל כשל גורם ל-ROLLBACK וזריקה, וה-DB נשאר ללא שינוי.
///
/// המתודה סינכרונית וחוסמת — יש להריצה ב-Isolate או אחרי
/// `closeForExternalWrite`.
class PatchApplier {
  final LogicalContentHasher hasher;

  /// גרסת פורמט patch.db הגבוהה ביותר שהאפליקציה יודעת להחיל.
  final int supportedPatchFormatVersion;

  /// מספר שורות ה-patch שמוחלות בכל statement. הפיצול קיים כדי שדיווח
  /// ההתקדמות יהיה רציף — patch של מיליוני שורות אינו קופץ מ-0 ל-100.
  final int applyChunkSize;

  /// תקרת ה-page cache בשלב ה-upserts/deletes (KiB). ב-2MB של ברירת המחדל
  /// עדכון אינדקסים אקראי ב-link מפנה ומשפיך דפים שוב ושוב.
  final int cacheSizeKib;

  /// cache_size בזמן ה-hash (KiB). הסריקה רציפה, אבל SQLite קובע לפיו גם את
  /// זיכרון המיון של טבלה בלי id — ערך גדול מנפח זיכרון בלי להאיץ.
  final int hashCacheSizeKib;

  const PatchApplier({
    this.hasher = const LogicalContentHasher(),
    this.supportedPatchFormatVersion = kSupportedPatchFormatVersion,
    this.applyChunkSize = kDefaultApplyChunkSize,
    this.cacheSizeKib = kDefaultApplyCacheSizeKib,
    this.hashCacheSizeKib = kDefaultHashCacheSizeKib,
  })  : assert(supportedPatchFormatVersion >= 1),
        assert(applyChunkSize > 0),
        assert(cacheSizeKib > 0),
        assert(hashCacheSizeKib > 0);

  /// מחיל את ה-patch שב-[patchPath] על ה-DB שב-[dbPath] לפי [manifest].
  ///
  /// [verifyFromHash] — אם פעיל, מחשב את ה-hash המקומי לפני apply ומשווה ל-
  /// `fromContentHash` (יקר אך מזהה DB ששונה ידנית/corruption).
  /// [checkForeignKeys] — אם פעיל, מוודא ש-`foreign_key_check` לא גדל.
  /// [onApplyProgress] — מדווח `(rowsDone, rowsTotal)` לאורך שלבי ה-upserts
  /// וה-deletes. `rowsTotal` הוא סך שורות טבלאות ה-patch שיעובדו בפועל,
  /// ונמדד פעם אחת לפני ה-transaction. הקריאה הראשונה היא `(0, rowsTotal)`
  /// בתחילת ה-upserts; אחריה קריאה אחרי כל מנה. ויסות הוא באחריות הקורא.
  /// [verifyTableBytesHint] — בתים לכל טבלה מריצה קודמת, למד התקדמות מדויק
  /// כשהמניפסט מאפשר אימות חלקי (ראו [PatchApplyResult.deferredTables]).
  /// [enablePartialTableVerification] — מאפשר להחליף את אימות ה-DB המלא
  /// באימות הטבלאות שהשתנו ובדחיית היתר. ברירת המחדל היא false כדי לשמר את
  /// חוזה [apply] עבור צרכנים קיימים: חזרה מוצלחת פירושה שה-DB כולו אומת
  /// לפני ה-commit. צרכן שמפעיל זאת חייב להריץ [verifyTableHashes] על
  /// [PatchApplyResult.deferredTables] אחרי ה-commit.
  PatchApplyResult apply({
    required String dbPath,
    required String patchPath,
    required DeltaManifest manifest,
    bool verifyFromHash = true,
    bool checkForeignKeys = true,
    void Function(String stage)? onStage,
    void Function(int hashedBytes, int totalBytes)? onVerifyProgress,
    void Function(int rowsDone, int rowsTotal)? onApplyProgress,
    int? verifyTotalBytesHint,
    Map<String, int>? verifyTableBytesHint,
    bool enablePartialTableVerification = false,
  }) {
    // ── preflight: שני סדרי ה-hash נפתרים לפני כל פתיחה/כתיבה — גרסת סכמה
    // לא מוכרת (from או to) זורקת כאן, גם כש-verifyFromHash כבוי.
    final fromOrder =
        hashTableOrderForSchemaVersion(manifest.fromSchemaVersion);
    final toOrder = hashTableOrderForSchemaVersion(manifest.toSchemaVersion);

    // עם hint (סך-הבתים מריצה קודמת) ה-total מדויק; בלעדיו נופלים לגודל
    // הקובץ — הערכת-יתר (אינדקסים ודפים לא נכנסים ל-hash), שנמדדת מחדש לפני
    // כל אימות כי ה-patch משנה את הגודל. בשני המסלולים זו הערכה למד בלבד.
    var totalBytes = 0;
    int refreshTotal() =>
        totalBytes = verifyTotalBytesHint ?? File(dbPath).lengthSync();
    final void Function(int)? verifyProgress = onVerifyProgress == null
        ? null
        : (bytes) => onVerifyProgress(bytes, totalBytes);

    // uri: true — רק כדי ש-ATTACH יכבד mode=ro; נתיב ה-DB עצמו אינו URI.
    final db = sqlite3.sqlite3.open(dbPath, uri: true);
    var attached = false;
    var inTransaction = false;
    try {
      db.execute('PRAGMA busy_timeout = 5000');
      // אכיפת FK פעילה (כמו צד הייצור). מחוץ ל-transaction — לא ניתן לשינוי
      // בתוך transaction. בתוך ה-transaction מוסיפים defer_foreign_keys.
      db.execute('PRAGMA foreign_keys = ON');
      _tuneConnection(db, cacheSizeKib);

      // ── preflight: גרסה וסכמה מקומיות ──
      onStage?.call('preflight');
      final localVersion = _readSchemaMetaInt(db, 'db_version', schema: 'main');
      final localSchema =
          _readSchemaMetaInt(db, 'db_schema_version', schema: 'main');
      if (localVersion != manifest.fromVersion) {
        throw PatchApplyException(
          'גרסת ה-DB המקומי ($localVersion) אינה תואמת ל-patch '
          '(${manifest.fromVersion})',
        );
      }
      if (localSchema != null && localSchema != manifest.fromSchemaVersion) {
        throw PatchApplyException(
          'סכמת ה-DB המקומי ($localSchema) אינה תואמת ל-patch '
          '(${manifest.fromSchemaVersion})',
        );
      }

      // ── preflight: hash מקומי מול fromContentHash ──
      if (verifyFromHash) {
        onStage?.call('verifyFromHash');
        if (verifyProgress != null) refreshTotal();
        _setCacheSize(db, hashCacheSizeKib);
        // ה-DB *לפני* apply הוא בסכמת המקור — הסדר נבחר לפי fromSchemaVersion.
        final localHash = hasher.compute(
          db,
          tableOrder: fromOrder,
          onProgress: verifyProgress,
        );
        _setCacheSize(db, cacheSizeKib);
        if (localHash != manifest.fromContentHash) {
          throw PatchApplyException(
            'ה-DB המקומי שונה מהצפוי — hash לא תואם ל-fromContentHash. '
            'נדרשת הורדה מלאה.',
            hashMismatchStage: PatchHashMismatchStage.fromContentHash,
          );
        }
      }

      // ── ATTACH (חייב להיות מחוץ ל-transaction) ──
      onStage?.call('attach');
      _attachPatch(db, patchPath);
      attached = true;
      _assertPatchCompatible(db, manifest);

      final preFk = checkForeignKeys ? _countFkViolations(db) : 0;

      final progress = _ApplyProgress(_planPatchChunks(db), onApplyProgress);

      // ── transaction ──
      db.execute('BEGIN');
      inTransaction = true;
      db.execute('PRAGMA defer_foreign_keys = ON');

      onStage?.call('migrations');
      final migrations = _runMigrations(db);

      onStage?.call('upserts');
      progress.emit();
      final upserts = _runUpserts(db, progress);

      // חייב לרוץ אחרי ה-upserts (שורות חדשות כבר ב-main עבור ה-JOINs)
      // ולפני ה-deletes (שורות שיימחקו עדיין קיימות למיפוי bookId).
      final booksTouched = _collectBooksTouched(db);

      onStage?.call('deletes');
      final deletes = _runDeletes(db, progress);

      _applyStat1Snapshot(db);

      if (checkForeignKeys) {
        onStage?.call('foreignKeyCheck');
        final postFk = _countFkViolations(db);
        if (postFk > preFk) {
          throw PatchApplyException(
            'מספר הפרות מפתח זר גדל ($preFk→$postFk) — ה-patch אינו תקין',
          );
        }
      }

      onStage?.call('verifyToHash');
      // מקטין רק דפים נקיים; הדפים המלוכלכים של ה-transaction נשארים.
      _setCacheSize(db, hashCacheSizeKib);
      // ה-DB *אחרי* apply הוא בסכמת היעד — הסדר נבחר לפי toSchemaVersion.
      final toTables = enablePartialTableVerification
          ? _tablesToVerify(db, manifest, fromOrder, toOrder)
          : null;
      final String resultHash;
      var verifiedTables = const <String>[];
      var deferredTables = const <String>[];
      var verifyTableBytes = const <String, int>{};
      if (toTables == null) {
        if (verifyProgress != null) refreshTotal();
        resultHash = hasher.compute(
          db,
          tableOrder: toOrder,
          onProgress: verifyProgress,
        );
        if (resultHash != manifest.toContentHash) {
          throw PatchApplyException(
            'ה-hash אחרי apply ($resultHash) אינו תואם ל-toContentHash '
            '(${manifest.toContentHash})',
            hashMismatchStage: PatchHashMismatchStage.toContentHash,
          );
        }
      } else {
        final expected = manifest.toTableContentHashes!;
        if (verifyProgress != null) {
          totalBytes = _hintedTotal(verifyTableBytesHint, toTables);
          if (totalBytes == 0) refreshTotal();
        }
        final report = hasher.computeReport(
          db,
          tableOrder: toOrder,
          only: toTables.toSet(),
          onProgress: verifyProgress,
        );
        final mismatched = [
          for (final t in toTables)
            if (report.tableHashes[t] != expected[t]) t,
        ];
        if (mismatched.isNotEmpty) {
          throw PatchApplyException(
            'ה-hash אחרי apply אינו תואם ל-toTableContentHashes בטבלאות: '
            '${mismatched.join(', ')}',
            hashMismatchStage: PatchHashMismatchStage.toContentHash,
            mismatchedTables: mismatched,
          );
        }
        verifiedTables = toTables;
        deferredTables = [
          for (final t in toOrder)
            if (!report.tableHashes.containsKey(t)) t,
        ];
        verifyTableBytes = report.tableBytes;
        // אומת לפי טבלאות; ה-hash הכולל הצפוי הוא זה שבמניפסט.
        resultHash = manifest.toContentHash;
      }

      onStage?.call('commit');
      db.execute('COMMIT');
      inTransaction = false;

      db.execute('DETACH DATABASE patch');
      attached = false;

      return PatchApplyResult(
        migrations: migrations,
        upserts: upserts,
        deletes: deletes,
        resultHash: resultHash,
        booksTouched: booksTouched,
        verifiedTables: verifiedTables,
        deferredTables: deferredTables,
        verifyTableBytes: verifyTableBytes,
      );
    } catch (_) {
      if (inTransaction) {
        try {
          db.execute('ROLLBACK');
        } catch (_) {}
      }
      if (attached) {
        try {
          db.execute('DETACH DATABASE patch');
        } catch (_) {}
      }
      rethrow;
    } finally {
      db.close();
    }
  }

  /// מאמת את [tables] ב-DB שב-[dbPath] (חיבור קריאה-בלבד) מול [expected],
  /// ומחזיר את שמות הטבלאות שלא תאמו (ריק = הכול תואם).
  List<String> verifyTableHashes({
    required String dbPath,
    required int schemaVersion,
    required Map<String, String> expected,
    required List<String> tables,
    void Function(int hashedBytes, int totalBytes)? onProgress,
    Map<String, int>? tableBytesHint,
  }) {
    final order = hashTableOrderForSchemaVersion(schemaVersion);
    final only = tables.toSet();
    var totalBytes = _hintedTotal(tableBytesHint, tables);
    if (totalBytes == 0) totalBytes = File(dbPath).lengthSync();
    final db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
    try {
      _tuneConnection(db, hashCacheSizeKib);
      final report = hasher.computeReport(
        db,
        tableOrder: order,
        only: only,
        onProgress: onProgress == null
            ? null
            : (bytes) => onProgress(bytes, totalBytes),
      );
      return [
        for (final t in order)
          if (report.tableHashes.containsKey(t) &&
              report.tableHashes[t] != expected[t])
            t,
      ];
    } finally {
      db.close();
    }
  }

  /// סכום רמזי הבתים עבור [tables]; 0 כשאין רמז שימושי.
  int _hintedTotal(Map<String, int>? hint, List<String> tables) {
    if (hint == null) return 0;
    var sum = 0;
    for (final t in tables) {
      sum += hint[t] ?? 0;
    }
    return sum;
  }

  /// רשימת הטבלאות לאימות לפי כלל האימות החלקי, או null כשהמניפסט אינו נושא
  /// מפות עקביות — ואז מאמתים את ה-DB כולו כמו קודם.
  List<String>? _tablesToVerify(sqlite3.Database db, DeltaManifest manifest,
      List<String> fromOrder, List<String> toOrder) {
    final from = manifest.fromTableContentHashes;
    final to = manifest.toTableContentHashes;
    if (from == null || to == null) return null;
    if (!_sameKeys(from.keys, fromOrder) || !_sameKeys(to.keys, toOrder)) {
      return null;
    }
    return [
      for (final t in toOrder)
        if (t == 'schema_meta' ||
            from[t] != to[t] ||
            _patchHasRows(db, 'upsert_$t') ||
            _patchHasRows(db, 'delete_$t'))
          t,
    ];
  }

  bool _sameKeys(Iterable<String> keys, List<String> order) =>
      keys.length == order.length && keys.toSet().containsAll(order);

  /// האם ל-patch יש טבלת [name] עם שורה אחת לפחות.
  bool _patchHasRows(sqlite3.Database db, String name) {
    if (!_hasTable(db, 'patch', name)) return false;
    return db.select('SELECT 1 FROM patch."$name" LIMIT 1').isNotEmpty;
  }

  /// כשל פתיחה נזרק כ-[PatchApplyException], כדי שהצרכן יציע הורדה מלאה.
  /// ATTACH פותח בעצלות: קובץ שאינו SQLite נכשל רק בקריאה הראשונה.
  void _attachPatch(sqlite3.Database db, String patchPath) {
    try {
      db.execute('ATTACH DATABASE ? AS patch', [readOnlyFileUri(patchPath)]);
      db.select('SELECT 1 FROM patch.sqlite_master LIMIT 1');
    } on sqlite3.SqliteException catch (e) {
      if (_isAttached(db, 'patch')) db.execute('DETACH DATABASE patch');
      throw PatchApplyException(
        'לא ניתן לפתוח את קובץ ה-patch ($patchPath): ${e.message}',
        cause: e,
      );
    }
  }

  static bool _isAttached(sqlite3.Database db, String name) => db.select(
      'SELECT 1 FROM pragma_database_list WHERE name = ?', [name]).isNotEmpty;

  void _assertPatchCompatible(sqlite3.Database db, DeltaManifest manifest) {
    final schemaVersion = _readPatchMetaInt(db, 'schema_version');
    if (schemaVersion == null) {
      throw const PatchApplyException('patch_meta.schema_version חסר ב-patch');
    }
    if (schemaVersion < 1 || schemaVersion > supportedPatchFormatVersion) {
      throw PatchApplyException(
        'גרסת פורמט ה-patch ($schemaVersion) מחוץ לטווח הנתמך '
        '(1–$supportedPatchFormatVersion) — נדרש עדכון תוכנה או patch תקין',
      );
    }
    final declaredFormat = manifest.patchFormatVersion;
    if (manifest.toSchemaVersion >= 4 && declaredFormat == null) {
      throw const PatchApplyException(
        'patchFormatVersion חסר במניפסט של schema 4 ומעלה',
      );
    }
    if (declaredFormat != null && schemaVersion != declaredFormat) {
      throw PatchApplyException(
        'גרסת פורמט ה-patch ($schemaVersion) אינה תואמת למניפסט '
        '($declaredFormat)',
      );
    }
    final from = _readPatchMetaInt(db, 'from_version');
    final to = _readPatchMetaInt(db, 'to_version');
    if (from != manifest.fromVersion || to != manifest.toVersion) {
      throw PatchApplyException(
        'גרסאות ה-patch ($from→$to) אינן תואמות ל-manifest '
        '(${manifest.fromVersion}→${manifest.toVersion})',
      );
    }
  }

  int _runMigrations(sqlite3.Database db) {
    final result =
        db.select('SELECT sql FROM patch.migrations ORDER BY version ASC');
    var count = 0;
    for (final row in result) {
      db.execute(row['sql'] as String);
      count++;
    }
    return count;
  }

  Map<String, int> _runUpserts(sqlite3.Database db, _ApplyProgress progress) {
    final counts = <String, int>{};
    for (final table in kPatchTablesInFkOrder) {
      final patchTable = 'upsert_${table.name}';
      if (!_hasTable(db, 'patch', patchTable)) continue;
      final cols = _patchTableColumns(db, patchTable);
      if (cols.isEmpty) continue;

      final colsCsv = cols.map((c) => '"$c"').join(',');
      final pkCsv = table.primaryKey.map((c) => '"$c"').join(',');
      final nonPkCols =
          cols.where((c) => !table.primaryKey.contains(c)).toList();

      final String conflictClause;
      if (!table.updatable || nonPkCols.isEmpty) {
        conflictClause = 'ON CONFLICT($pkCsv) DO NOTHING';
      } else {
        final assignments =
            nonPkCols.map((c) => '"$c" = excluded."$c"').join(',');
        // שורה זהה לא נכתבת. ההשוואה כמו ב-hash: typeof מבדיל 2 מ-2.0, ו-BINARY
        // עוקף COLLATE NOCASE של העמודה.
        final changed = nonPkCols
            .map((c) => '"${table.name}"."$c" IS NOT excluded."$c" '
                'COLLATE BINARY OR typeof("${table.name}"."$c") IS NOT '
                'typeof(excluded."$c")')
            .join(' OR ');
        conflictClause =
            'ON CONFLICT($pkCsv) DO UPDATE SET $assignments WHERE $changed';
      }

      final head = 'INSERT INTO "${table.name}" ($colsCsv) '
          'SELECT $colsCsv FROM patch."$patchTable"';
      counts[table.name] = _runChunked(
        db,
        plan: progress.plans[patchTable],
        progress: progress,
        // תנאי ה-rowid ממלא גם את תפקיד `WHERE true` — בלעדיו ה-parser
        // משייך את ON CONFLICT ל-SELECT ולא ל-INSERT.
        chunkSql: (range) => '$head WHERE $range $conflictClause',
        wholeSql: '$head WHERE true $conflictClause',
      );
    }
    return counts;
  }

  Map<String, int> _runDeletes(sqlite3.Database db, _ApplyProgress progress) {
    final counts = <String, int>{};
    for (final table in kPatchTablesInFkOrder.reversed) {
      final patchTable = 'delete_${table.name}';
      if (!_hasTable(db, 'patch', patchTable)) continue;
      if (table.primaryKey.isEmpty) continue;

      final pkCsv = table.primaryKey.map((c) => '"$c"').join(',');
      final keys =
          table.primaryKey.length == 1 ? '"${table.primaryKey.first}"' : pkCsv;
      final target = table.primaryKey.length == 1 ? keys : '($pkCsv)';
      String sql(String where) => 'DELETE FROM "${table.name}" WHERE $target '
          'IN (SELECT $keys FROM patch."$patchTable"$where)';

      counts[table.name] = _runChunked(
        db,
        plan: progress.plans[patchTable],
        progress: progress,
        chunkSql: (range) => sql(' WHERE $range'),
        wholeSql: sql(''),
      );
    }
    return counts;
  }

  /// מריץ [chunkSql] על מנות ה-rowid של [plan] ומחזיר את סך `updatedRows`.
  /// נופל ל-[wholeSql] כשלטבלת ה-patch אין rowid.
  int _runChunked(
    sqlite3.Database db, {
    required _ChunkPlan? plan,
    required _ApplyProgress progress,
    required String Function(String rowidRange) chunkSql,
    required String wholeSql,
  }) {
    final ranges = plan?.ranges;
    if (ranges == null) {
      db.execute(wholeSql);
      // נקרא לפני הדיווח — callback שיריץ SQL ידרוס את `updatedRows`.
      final updated = db.updatedRows;
      progress.advance(plan?.rows ?? 0);
      return updated;
    }
    var updated = 0;
    for (final r in ranges) {
      db.execute(chunkSql('rowid > ${r.lo} AND rowid <= ${r.hi}'));
      updated += db.updatedRows;
      progress.advance(r.rows);
    }
    return updated;
  }

  /// מתכנן מראש את מנות כל טבלאות ה-patch שיעובדו — אותם תנאי דילוג כמו
  /// ב-[_runUpserts] וב-[_runDeletes]. סכום השורות הוא `rowsTotal` של המד.
  Map<String, _ChunkPlan> _planPatchChunks(sqlite3.Database db) {
    final plans = <String, _ChunkPlan>{};
    for (final table in kPatchTablesInFkOrder) {
      final upsertTable = 'upsert_${table.name}';
      if (_hasTable(db, 'patch', upsertTable) &&
          _patchTableColumns(db, upsertTable).isNotEmpty) {
        plans[upsertTable] = _planChunks(db, upsertTable);
      }
      final deleteTable = 'delete_${table.name}';
      if (table.primaryKey.isNotEmpty && _hasTable(db, 'patch', deleteTable)) {
        plans[deleteTable] = _planChunks(db, deleteTable);
      }
    }
    return plans;
  }

  /// גבולות המנות ומספר השורות במעבר יחיד על ה-rowid-ים: כל גבול מדלג
  /// [applyChunkSize] שורות, ורק שארית המנה האחרונה נספרת.
  _ChunkPlan _planChunks(sqlite3.Database db, String patchTable) {
    if (!_patchTableHasRowid(db, patchTable)) {
      final row =
          db.select('SELECT count(*) AS c FROM patch."$patchTable"').first;
      return _ChunkPlan(row['c'] as int, null);
    }
    final bounds = db.select(
        'SELECT min(rowid) AS lo, max(rowid) AS hi FROM patch."$patchTable"');
    final maxRowid = bounds.first['hi'];
    if (maxRowid is! int) return const _ChunkPlan(0, []);

    final ranges = <({int lo, int hi, int rows})>[];
    var rows = 0;
    var lo = (bounds.first['lo'] as int) - 1;
    while (true) {
      final boundary = _chunkBoundary(db, patchTable, lo);
      if (boundary == null) {
        final tail = db.select(
          'SELECT count(*) AS c FROM patch."$patchTable" WHERE rowid > ?',
          [lo],
        ).first['c'] as int;
        if (tail > 0) ranges.add((lo: lo, hi: maxRowid, rows: tail));
        return _ChunkPlan(rows + tail, ranges);
      }
      ranges.add((lo: lo, hi: boundary, rows: applyChunkSize));
      rows += applyChunkSize;
      lo = boundary;
    }
  }

  /// ה-rowid של השורה ה-[applyChunkSize] אחרי [afterRowid], או null כשנותרו
  /// פחות שורות — סימן שזו המנה האחרונה.
  int? _chunkBoundary(sqlite3.Database db, String patchTable, int afterRowid) {
    final rows = db.select(
      'SELECT rowid AS r FROM patch."$patchTable" WHERE rowid > ? ORDER BY rowid '
      'LIMIT 1 OFFSET ${applyChunkSize - 1}',
      [afterRowid],
    );
    return rows.isEmpty ? null : rows.first['r'] as int;
  }

  bool _patchTableHasRowid(sqlite3.Database db, String patchTable) {
    try {
      db.select('SELECT rowid FROM patch."$patchTable" LIMIT 1');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// temp_store=FILE: מיון ה-hash של version_line (בלי id) היה נשמר כולו
  /// בזיכרון, כי ה-build של sqlite3.dart מגדיר TEMP_STORE=2.
  void _tuneConnection(sqlite3.Database db, int cacheKib) {
    _setCacheSize(db, cacheKib);
    if (_sqliteHasTempDir()) db.execute('PRAGMA temp_store = FILE');
  }

  /// ב-Android אין לתהליך תיקיית temp ש-SQLite מוצא בעצמו; בלעדיה FILE נכשל
  /// ב-SQLITE_CANTOPEN בקובץ הזמני הראשון (מיון ה-hash, statement journal).
  static bool _sqliteHasTempDir() {
    if (!Platform.isAndroid || sqlite3.sqlite3.tempDirectory != null) {
      return true;
    }
    final env = Platform.environment;
    return (env['SQLITE_TMPDIR'] ?? env['TMPDIR'] ?? '').isNotEmpty;
  }

  void _setCacheSize(sqlite3.Database db, int kib) =>
      db.execute('PRAGMA cache_size = -$kib');

  /// מעתיק את `stat1_snapshot` של ה-patch ל-`sqlite_stat1`, כדי שלקוח דלתא
  /// יקבל את סטטיסטיקות המתכנן של ה-DB המלא. patch בלעדיה משאיר את הקיימות.
  void _applyStat1Snapshot(sqlite3.Database db) {
    if (!_hasTable(db, 'patch', kPatchStat1SnapshotTable)) return;
    // יוצר את sqlite_stat1 כשחסרה; CREATE TABLE על שם sqlite_* אסור.
    db.execute('ANALYZE main.sqlite_schema');
    db.execute('DELETE FROM main.sqlite_stat1');
    db.execute('INSERT INTO main.sqlite_stat1 (tbl, idx, stat) '
        'SELECT tbl, idx, stat FROM patch."$kPatchStat1SnapshotTable"');
  }

  /// אוסף את מזהי הספרים שתוכן האינדקס שלהם (כותרת/טקסט/הפניות TOC/מטא-דאטה)
  /// הושפע מה-patch.
  ///
  /// רץ אחרי ה-upserts ולפני ה-deletes, כך ששורות חדשות כבר ב-main ושורות
  /// שיימחקו עדיין בו — וכל מיפוי JOIN דרך main רואה את כולן. המיפוי נשען
  /// רק על עמודות ה-PK של טבלת ה-patch: עמודות אחרות (כמו bookId ב-line)
  /// אינן מובטחות ב-patch שמעדכן רק תת-קבוצה של עמודות.
  Set<int> _collectBooksTouched(sqlite3.Database db) {
    final touched = <int>{};
    // [joins] — טבלאות main שה-SQL עושה אליהן JOIN; אם אחת חסרה (סכמה ישנה
    // או DB חלקי בבדיקות) מדלגים במקום להפיל את ה-apply.
    void collect(String patchTable, String bookIdSql,
        {List<String> joins = const []}) {
      if (!_hasTable(db, 'patch', patchTable)) return;
      if (joins.any((t) => !_hasTable(db, 'main', t))) return;
      for (final row in db.select(bookIdSql)) {
        final id = row.values.first;
        if (id is int) touched.add(id);
      }
    }

    collect('upsert_book', 'SELECT DISTINCT id FROM patch.upsert_book');
    collect('delete_book', 'SELECT DISTINCT id FROM patch.delete_book');

    for (final op in const ['upsert', 'delete']) {
      collect(
          '${op}_line',
          'SELECT DISTINCT l.bookId FROM patch.${op}_line p '
              'JOIN main.line l ON l.id = p.id',
          joins: const ['line']);
      // סכמה 6: תוכן השורה ב-line_content, באותו id של line.
      collect(
          '${op}_line_content',
          'SELECT DISTINCT l.bookId FROM patch.${op}_line_content p '
              'JOIN main.line l ON l.id = p.id',
          joins: const ['line']);
      collect(
          '${op}_tocEntry',
          'SELECT DISTINCT t.bookId FROM patch.${op}_tocEntry p '
              'JOIN main.tocEntry t ON t.id = p.id',
          joins: const ['tocEntry']);
      collect(
          '${op}_line_toc',
          'SELECT DISTINCT l.bookId FROM patch.${op}_line_toc p '
              'JOIN main.line l ON l.id = p.lineId',
          joins: const ['line']);
      // טקסט TOC משותף בין ספרים — ממופה לכל מי שמפנה אליו, גם דרך alt-TOC
      collect(
          '${op}_tocText',
          'SELECT DISTINCT t.bookId FROM patch.${op}_tocText p '
              'JOIN main.tocEntry t ON t.textId = p.id',
          joins: const ['tocEntry']);
      collect(
          '${op}_tocText',
          'SELECT DISTINCT s.bookId FROM patch.${op}_tocText p '
              'JOIN main.alt_toc_entry a ON a.textId = p.id '
              'JOIN main.alt_toc_structure s ON s.id = a.structureId',
          joins: const ['alt_toc_entry', 'alt_toc_structure']);
      collect(
          '${op}_alt_toc_structure',
          'SELECT DISTINCT s.bookId FROM patch.${op}_alt_toc_structure p '
              'JOIN main.alt_toc_structure s ON s.id = p.id',
          joins: const ['alt_toc_structure']);
      collect(
          '${op}_alt_toc_entry',
          'SELECT DISTINCT s.bookId FROM patch.${op}_alt_toc_entry p '
              'JOIN main.alt_toc_entry a ON a.id = p.id '
              'JOIN main.alt_toc_structure s ON s.id = a.structureId',
          joins: const ['alt_toc_entry', 'alt_toc_structure']);
      collect(
          '${op}_line_alt_toc',
          'SELECT DISTINCT l.bookId FROM patch.${op}_line_alt_toc p '
              'JOIN main.line l ON l.id = p.lineId',
          joins: const ['line']);
      // כאן bookId הוא חלק מה-PK — מובטח בשורות ה-patch, אפשר לקרוא ישירות
      for (final t in const ['book_author', 'book_topic', 'book_acronym']) {
        collect('${op}_$t', 'SELECT DISTINCT bookId FROM patch.${op}_$t');
      }
      // book_base_text — שני הצדדים (bookId וגם baseBookId) הם מזהי ספרים
      // שחלק מה-PK, ושינוי בכל אחד מהם נוגע לספר המתאים.
      collect('${op}_book_base_text',
          'SELECT DISTINCT bookId FROM patch.${op}_book_base_text');
      collect('${op}_book_base_text',
          'SELECT DISTINCT baseBookId FROM patch.${op}_book_base_text');
    }
    return touched;
  }

  int _countFkViolations(sqlite3.Database db) {
    return db.select('PRAGMA foreign_key_check').length;
  }

  bool _hasTable(sqlite3.Database db, String schema, String name) {
    final result = db.select(
      "SELECT 1 FROM $schema.sqlite_master WHERE type='table' AND name=? "
      'LIMIT 1',
      [name],
    );
    return result.isNotEmpty;
  }

  List<String> _patchTableColumns(sqlite3.Database db, String name) {
    final result = db.select('PRAGMA patch.table_info("$name")');
    return result.map((r) => r['name'] as String).toList();
  }

  int? _readPatchMetaInt(sqlite3.Database db, String key) {
    try {
      final result = db.select(
        'SELECT value FROM patch.patch_meta WHERE key = ? LIMIT 1',
        [key],
      );
      if (result.isEmpty) return null;
      return int.tryParse(result.first['value']?.toString() ?? '');
    } catch (_) {
      return null;
    }
  }

  int? _readSchemaMetaInt(sqlite3.Database db, String key,
      {required String schema}) {
    try {
      final result = db.select(
        'SELECT value FROM $schema.schema_meta WHERE key = ? LIMIT 1',
        [key],
      );
      if (result.isEmpty) return null;
      return int.tryParse(result.first['value']?.toString() ?? '');
    } catch (_) {
      return null;
    }
  }
}
