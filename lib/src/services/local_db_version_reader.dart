import 'dart:isolate';

import 'package:seforim_library_updater/src/sqlite/sqlite3_api.dart' as sqlite3;

import '../messages/library_updater_messages.dart';

/// גרסת ה-DB המקומי כפי שנקראה מטבלת `schema_meta`.
class LocalDbVersion {
  /// `schema_meta.db_version`. 0 אם השדה או הטבלה חסרים (DB ישן מאוד).
  final int dbVersion;

  /// `schema_meta.db_schema_version`. null אם חסר.
  final int? schemaVersion;

  /// `false` כאשר `schema_meta.db_version` לא נמצא — סימן שה-DB ישן מדי
  /// מכדי להחיל עליו patch, ויש לעבור למסלול הורדה מלאה.
  final bool hasVersionMeta;

  const LocalDbVersion({
    required this.dbVersion,
    required this.schemaVersion,
    required this.hasVersionMeta,
  });
}

/// קורא את גרסת הספרייה המקומית מטבלת `schema_meta` שב-`seforim.db`.
///
/// הפתיחה היא read-only ואינה משנה את ה-DB.
class LocalDbVersionReader {
  const LocalDbVersionReader({this.busyTimeout = const Duration(seconds: 2)});

  /// כמה זמן קריאה ממתינה לנעילה של חיבור אחר לפני שהיא מדווחת עליה.
  final Duration busyTimeout;

  /// [read] ב-isolate, כדי שה-busy timeout לא יחסום את ה-UI.
  Future<LocalDbVersion> readInIsolate(String dbPath) =>
      _runReadIsolate(dbPath, busyTimeout.inMilliseconds);

  static Future<LocalDbVersion> _runReadIsolate(String dbPath, int timeoutMs) =>
      Isolate.run(() => LocalDbVersionReader(
            busyTimeout: Duration(milliseconds: timeoutMs),
          ).read(dbPath));

  /// קורא את הגרסה והסכמה מ-DB שב-[dbPath].
  ///
  /// `hasVersionMeta=false` כשהשדה חסר או שהקובץ פגום לצמיתות. נעילה או כתיבה
  /// שנקטעה נזרקות כ-[LocalDbUnreadableException] — אין להן גרסה אמינה.
  LocalDbVersion read(String dbPath) {
    sqlite3.Database? db;
    try {
      db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
      db.execute('PRAGMA busy_timeout = ${busyTimeout.inMilliseconds}');
      if (!_hasSchemaMetaColumns(db)) return _noVersion;
      final dbVersion = _readIntMeta(db, 'db_version');
      final schemaVersion = _readIntMeta(db, 'db_schema_version');
      return LocalDbVersion(
        dbVersion: dbVersion ?? 0,
        schemaVersion: schemaVersion,
        hasVersionMeta: dbVersion != null,
      );
    } on sqlite3.SqliteException catch (e) {
      if (isPermanentlyUnreadable(e.extendedResultCode)) return _noVersion;
      final reason =
          unreadableReasonFor(e.extendedResultCode, opened: db != null);
      if (reason != null) {
        throw LocalDbUnreadableException(
            reason, e.extendedResultCode, e.message);
      }
      rethrow;
    } finally {
      db?.close();
    }
  }

  static const _noVersion =
      LocalDbVersion(dbVersion: 0, schemaVersion: null, hasVersionMeta: false);

  /// SQLITE_CORRUPT או SQLITE_NOTADB: הקובץ עצמו פגום, לצמיתות.
  static bool isPermanentlyUnreadable(int extendedResultCode) =>
      const {11, 26}.contains(extendedResultCode & 0xFF);

  /// למה שגיאת SQLite חולפת השאירה את הגרסה לא ידועה, או null כשהשגיאה
  /// אינה מהסוג הזה. CANTOPEN אחרי פתיחה ([opened]) הוא קובץ WAL שתיקייה
  /// לקריאה בלבד מונעת (כך Windows מדווחת); לפניה — ה-DB עצמו חסר.
  static LocalDbUnreadableReason? unreadableReasonFor(
    int extendedResultCode, {
    bool opened = false,
  }) =>
      switch (extendedResultCode) {
        _ when const {5, 6}.contains(extendedResultCode & 0xFF) =>
          LocalDbUnreadableReason.locked,
        264 || 776 => LocalDbUnreadableReason.interruptedWrite,
        // READONLY_CANTLOCK, READONLY_CANTINIT, READONLY_DIRECTORY.
        520 || 1288 || 1544 => LocalDbUnreadableReason.readOnlyLocation,
        14 when opened => LocalDbUnreadableReason.readOnlyLocation,
        _ => null,
      };

  /// `schema_meta` בלי עמודות `key`/`value` אינה הטבלה שאנו מכירים — או
  /// שאינה קיימת כלל (DB מלפני המערכת החדשה).
  bool _hasSchemaMetaColumns(sqlite3.Database db) {
    final columns = db
        .select("SELECT name FROM pragma_table_info('schema_meta')")
        .map((row) => row['name'].toString().toLowerCase())
        .toSet();
    return columns.containsAll(const {'key', 'value'});
  }

  int? _readIntMeta(sqlite3.Database db, String key) {
    final result = db.select(
      'SELECT value FROM schema_meta WHERE key = ? LIMIT 1',
      [key],
    );
    if (result.isEmpty) return null;
    return int.tryParse(result.first['value']?.toString() ?? '');
  }
}

/// למה [LocalDbVersionReader] לא הצליח לקרוא את ה-DB המקומי כרגע.
enum LocalDbUnreadableReason {
  /// SQLITE_BUSY / SQLITE_LOCKED: חיבור אחר מחזיק את ה-DB.
  locked,

  /// SQLITE_READONLY_ROLLBACK / _RECOVERY: journal או WAL של כתיבה שנקטעה,
  /// שפתיחה לקריאה בלבד אינה יכולה לגלגל.
  interruptedWrite,

  /// DB במצב WAL בתיקייה שאין הרשאת כתיבה אליה.
  readOnlyLocation,
}

/// ה-DB המקומי קיים אך גרסתו אינה ידועה כרגע, ולכן אין לבנות עליו תוכנית.
/// מחזיק פרימיטיבים בלבד כדי לשרוד מעבר בין isolates.
class LocalDbUnreadableException implements Exception {
  const LocalDbUnreadableException(
    this.reason,
    this.extendedResultCode,
    this.detail,
  );

  final LocalDbUnreadableReason reason;
  final int extendedResultCode;
  final String detail;

  @override
  String toString() {
    final messages = LibraryUpdaterMessages.current;
    return switch (reason) {
      LocalDbUnreadableReason.locked => messages.localDbLocked,
      LocalDbUnreadableReason.interruptedWrite =>
        messages.localDbInterruptedWrite,
      LocalDbUnreadableReason.readOnlyLocation =>
        messages.localDbReadOnlyLocation,
    };
  }
}
