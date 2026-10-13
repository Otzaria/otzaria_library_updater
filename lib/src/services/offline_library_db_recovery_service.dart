import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/src/sqlite/sqlite3_api.dart' as sqlite3;

import '../messages/library_updater_messages.dart';
import 'library_db_recovery_service.dart';
import 'local_db_version_reader.dart';

/// התאוששות למסלול המראה (offline), **בלי גיבוי של המסד**: patch עטוף
/// ב-transaction, ומסד מלא מחולץ ל-`<db>.new` ומוחלף ב-rename רק אחרי אימות.
/// סימון שנמצא מחזיר [RecoveryAction.interrupted]; `<db>.backup` הוא שארית.
class OfflineLibraryDbRecoveryService {
  const OfflineLibraryDbRecoveryService();

  String markerPathFor(String dbPath) => '$dbPath.applying';

  /// סימון "המסד בגרסה X אך תוכנו לא אומת ב-hash" — ראו [markUnverified].
  String unverifiedMarkerPathFor(String dbPath) => '$dbPath.unverified';

  /// שאריות של מנגנון הגיבוי שהוסר — נמחקות בעלייה כדי לא להשאיר ~1GB תלוי
  /// אצל מי שעדכן מגרסה שכן יצרה גיבוי.
  static const List<String> _legacySuffixes = [
    '.backup',
    '.backup.tmp',
    '.restore.tmp',
  ];

  String patchTmpDirFor(String dbPath) =>
      p.join(p.dirname(dbPath), '.seforim-update-tmp');

  Future<RecoveryResult> recoverIfNeeded(String dbPath) async {
    _deleteLegacyArtifacts(dbPath);
    _restoreRetiredDb(dbPath);
    _deleteAbandonedStaging(dbPath);
    _deleteAbandonedPatches(dbPath);

    if (!File(markerPathFor(dbPath)).existsSync()) {
      _deleteSupersededRetiredDb(dbPath);
      return const RecoveryResult(RecoveryAction.none);
    }
    return RecoveryResult(
      RecoveryAction.interrupted,
      LibraryUpdaterMessages.current.interruptedUpdateFound,
    );
  }

  void _deleteSupersededRetiredDb(String dbPath) {
    try {
      final retired = File('$dbPath.old');
      if (!retired.existsSync()) return;
      final current =
          const LocalDbVersionReader(busyTimeout: Duration.zero).read(dbPath);
      if (!current.hasVersionMeta) return;
      retired.deleteSync();
    } catch (_) {}
  }

  void _deleteAbandonedPatches(String dbPath) {
    try {
      final dir = Directory(patchTmpDirFor(dbPath));
      if (!dir.existsSync()) return;
      for (final entity in dir.listSync()) {
        if (entity is File && entity.path.endsWith('.db')) {
          _deleteQuietly(entity.path);
        }
      }
    } catch (_) {}
  }

  /// מחזיר את `<db>.old` לשמו כשאין `<db>` בכלל, או כשיושב שם קובץ באורך 0.
  ///
  /// ההחלפה היא שני rename, ומוות בין השניים (הפסקת חשמל) מותיר את המסד השלם
  /// תחת `.old` ואת `seforim.db` לא-קיים. בלי השחזור הזה `resolveDbPath()`
  /// מחזיר `null` בעלייה הבאה, כל מסלול ההתאוששות מדולג כי זו "התקנה טרייה",
  /// ומסד שלם של ~7GB שיושב שם נזרק ומורד מחדש.
  ///
  /// ציבורי כי `LibraryManager` חייב לקרוא לזה **לפני** שהוא מסיק שאין מסד —
  /// כלומר לפני [recoverIfNeeded], שרץ רק כשמסד כבר אותר.
  void restoreRetiredDbIfOrphaned(String dbPath) => _restoreRetiredDb(dbPath);

  void _restoreRetiredDb(String dbPath) {
    try {
      final db = File(dbPath);
      final retired = File('$dbPath.old');
      if (!retired.existsSync() || retired.lengthSync() == 0) return;
      if (db.existsSync()) {
        // מסד באורך 0 הוא נתיב ש-sqlite פתחה בין שני ה-rename ולא כתבה —
        // בלי הפינוי `.old` השלם נשאר בצד לנצח.
        if (db.lengthSync() != 0) return;
        db.deleteSync();
      }
      retired.renameSync(dbPath);
    } catch (_) {
      // כשל שחזור אינו מחמיר דבר — הקבצים נשארים והמשתמש יכול לבחור ידנית.
    }
  }

  /// מוחק שאריות staging של הורדה מלאה שנקטעה — עד ~9GB תלויים.
  ///
  /// **רק מכאן**, כלומר בעלייה, ולא מ-[beginApply]: שם `<db>.new` הוא הקובץ
  /// המחולץ והמאומת שממתין להחלפה, ומחיקתו הייתה מבטלת עדכון שכבר הצליח.
  void _deleteAbandonedStaging(String dbPath) {
    for (final suffix in const [
      '.new',
      '.download.zst',
      '.download.zst.resume'
    ]) {
      try {
        final file = File('$dbPath$suffix');
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }

  /// בודק תקינות DB אחרי עדכון שנקטע. מחזיר `true` אם ה-DB תקין (עבר
  /// `quick_check`).
  ///
  /// חובה לפתוח RW: קריסה באמצע transaction משאירה hot journal, ו-SQLite חייב
  /// גישת כתיבה כדי לגלגלו אחורה. פתיחת readOnly על hot journal נכשלת ב-"attempt
  /// to write a readonly database". הפתיחה כאן מגלגלת ומנקה את ה-journal, כך
  /// שפתיחת ה-read-only הראשית של האפליקציה אחריה מצליחה.
  bool checkDbHealthAfterCrash(String dbPath) =>
      _checkDbHealthInIsolate(dbPath);

  /// אותה בדיקה, ב-isolate נפרד. `quick_check` על מסד של ~7GB חוסם **דקות**,
  /// והקורא היחיד הוא `checkForUpdate` שרץ על ה-isolate הראשי — כלומר קפיאה
  /// מלאה של הלאנצ'ר בעלייה, בלי מד ובלי אנימציה, בדיוק במחשב שהעדכון בו
  /// נקטע. הסוגר קורא לפונקציה top-level ומקבל מחרוזת בלבד, כמו כל שאר
  /// מעברי ה-isolate כאן.
  Future<bool> checkDbHealthAfterCrashAsync(String dbPath) =>
      Isolate.run(() => _checkDbHealthInIsolate(dbPath));

  /// נקרא לפני apply: כותב את הסימון (ומנקה שאריות קודמות תחילה).
  Future<void> beginApply({
    required String dbPath,
    required int fromVersion,
    required int toVersion,
    required String timestamp,
  }) async {
    _deleteLegacyArtifacts(dbPath);
    File(markerPathFor(dbPath)).writeAsStringSync(
      jsonEncode({
        'fromVersion': fromVersion,
        'toVersion': toVersion,
        'timestamp': timestamp,
      }),
      flush: true,
    );
  }

  /// נקרא אחרי apply מוצלח — ה-DB תקין, מוחקים את הסימון.
  void finishSuccess(String dbPath) => _deleteQuietly(markerPathFor(dbPath));

  /// מסמן שה-DB הגיע ל-[version] בהחלה שה-hash שלה **לא** חושב.
  ///
  /// נכתב לפני הצעד שלא יאומת, כדי לכסות קריסה אחרי COMMIT.
  /// כשל כתיבה חייב לעצור את ההחלה לפני שינוי המסד.
  void markUnverified(String dbPath, int version) {
    File(unverifiedMarkerPathFor(dbPath))
        .writeAsStringSync(jsonEncode({'version': version}), flush: true);
  }

  /// הגרסה שסומנה כלא-מאומתת, או `null` כשאין סימון (או שאינו קריא).
  int? unverifiedVersion(String dbPath) {
    try {
      final file = File(unverifiedMarkerPathFor(dbPath));
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync());
      return json is Map && json['version'] is int
          ? json['version'] as int
          : null;
    } catch (_) {
      return null;
    }
  }

  /// נקרא אחרי אימות hash שהצליח, או אחרי התקנת מסד מלא מאומת.
  void clearUnverified(String dbPath) =>
      _deleteQuietly(unverifiedMarkerPathFor(dbPath));

  /// מנקה סימון תקוע — גם אחרי apply שנכשל (וה-DB נשאר בגרסה שלפניו), וגם
  /// אחרי שזוהה מצב לא תקין ודווח (לא מחיקה שקטה).
  void clearStaleArtifacts(String dbPath) =>
      _deleteQuietly(markerPathFor(dbPath));

  void _deleteLegacyArtifacts(String dbPath) {
    for (final suffix in _legacySuffixes) {
      _deleteQuietly('$dbPath$suffix');
    }
  }

  void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}

bool _checkDbHealthInIsolate(String dbPath) {
  sqlite3.Database? db;
  try {
    db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readWrite);
    db.execute('PRAGMA busy_timeout = $_healthCheckBusyTimeoutMs');
    final result = db.select('PRAGMA quick_check');
    return result.isNotEmpty && result.first.values.first?.toString() == 'ok';
  } on sqlite3.SqliteException catch (e) {
    if (LocalDbVersionReader.isPermanentlyUnreadable(e.extendedResultCode)) {
      return false;
    }
    final reason = switch (LocalDbVersionReader.unreadableReasonFor(
      e.extendedResultCode,
      opened: db != null,
    )) {
      LocalDbUnreadableReason.interruptedWrite =>
        LocalDbUnreadableReason.readOnlyLocation,
      final other => other,
    };
    if (reason != null) {
      throw LocalDbUnreadableException(
        reason,
        e.extendedResultCode,
        e.message,
      );
    }
    rethrow;
  } finally {
    db?.close();
  }
}

const int _healthCheckBusyTimeoutMs = 2000;
