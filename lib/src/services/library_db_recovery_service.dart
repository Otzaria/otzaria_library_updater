import 'dart:convert';
import 'dart:io';

import 'package:seforim_library_updater/src/sqlite/sqlite3_api.dart' as sqlite3;

/// הפעולה שבוצעה (או נדרשת) בעת בדיקת התאוששות בעליית האפליקציה.
enum RecoveryAction {
  /// אין עדכון שנקטע — שום דבר לא נדרש.
  none,

  /// נמצא עדכון שנקטע וה-DB שוחזר מהגיבוי.
  restored,

  /// נמצא סימון עדכון שנקטע אך ללא גיבוי. במסלול דלתא זה תקין (ה-apply אטומי,
  /// אין גיבוי לשחזר) — הקורא צריך לוודא תקינות (quick_check) ולנקות את הסימון.
  blockedMissingBackup,
}

class RecoveryResult {
  final RecoveryAction action;
  final String? detail;
  const RecoveryResult(this.action, [this.detail]);
}

/// מנהל גיבוי, סימון (marker) ושחזור של `seforim.db` סביב החלת עדכון, כדי
/// שקריסה באמצע apply תהיה ניתנת לשחזור.
///
/// קבצים ליד ה-DB:
/// * `<db>.backup`   — ה-DB המקורי עצמו, שהוזז ב-rename (יחד עם ה-sidecars שלו).
/// * `<db>.applying` — סימון JSON (fromVersion/toVersion/timestamp).
///
/// הגיבוי הוא rename ולא העתקה: מיידי, ואינו דורש מקום פנוי בגודל ה-DB. לכן
/// אחרי [beginApply] עם גיבוי ה-DB **אינו** נמצא עוד ב-dbPath — מסלול זה מתאים
/// רק להחלפת קובץ (הורדה מלאה), לא לכתיבה לתוך ה-DB החי.
///
/// הסימון נכתב **לפני** ה-rename: `.backup` ללא סימון פירושו שאריות שמותר
/// למחוק, ולכן אסור שיהיה רגע שבו הגיבוי הוא העותק היחיד ואין סימון.
class LibraryDbRecoveryService {
  const LibraryDbRecoveryService();

  String backupPathFor(String dbPath) => '$dbPath.backup';
  String markerPathFor(String dbPath) => '$dbPath.applying';

  static const _sidecarSuffixes = ['-wal', '-shm', '-journal'];

  /// נקרא בעליית האפליקציה, **לפני** פתיחת ה-DB.
  ///
  /// * marker + backup קיימים → שחזור מהגיבוי (הורדה מלאה שנקטעה).
  /// * marker בלבד (ללא backup) → [RecoveryAction.blockedMissingBackup]; מסלול
  ///   דלתא תקין — הקורא מריץ [checkDbHealthAfterCrash] ומנקה את הסימון.
  /// * backup יתום (ללא marker) → שאריות; מוחקים אותו.
  Future<RecoveryResult> recoverIfNeeded(String dbPath) async {
    // שאריות עותקים זמניים מגרסאות שגיבו בהעתקה — עשויות לשקול כמו ה-DB.
    _deleteQuietly('$dbPath.backup.tmp');
    _deleteQuietly('$dbPath.restore.tmp');

    final marker = File(markerPathFor(dbPath));
    final backup = File(backupPathFor(dbPath));

    if (!marker.existsSync()) {
      if (backup.existsSync()) _deleteWithSidecars(backup.path);
      return const RecoveryResult(RecoveryAction.none);
    }

    if (!backup.existsSync()) {
      return const RecoveryResult(
        RecoveryAction.blockedMissingBackup,
        'נמצא סימון עדכון שלא הושלם ללא גיבוי — יש לוודא תקינות ה-DB',
      );
    }

    _restore(backup.path, dbPath);
    _deleteQuietly(marker.path);
    return const RecoveryResult(
      RecoveryAction.restored,
      'עדכון שנקטע זוהה — ה-DB שוחזר מהגיבוי',
    );
  }

  /// בודק תקינות DB אחרי עדכון שנקטע ללא גיבוי (מסלול דלתא). מחזיר `true` אם
  /// ה-DB תקין (עבר `quick_check`).
  ///
  /// חובה לפתוח RW: קריסה באמצע transaction משאירה hot journal, ו-SQLite חייב
  /// גישת כתיבה כדי לגלגלו אחורה. פתיחת readOnly על hot journal נכשלת ב-"attempt
  /// to write a readonly database". הפתיחה כאן מגלגלת ומנקה את ה-journal, כך
  /// שפתיחת ה-read-only הראשית של האפליקציה אחריה מצליחה.
  bool checkDbHealthAfterCrash(String dbPath) {
    try {
      final db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readWrite);
      try {
        final result = db.select('PRAGMA quick_check');
        return result.isNotEmpty &&
            result.first.values.first?.toString() == 'ok';
      } finally {
        db.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// נקרא לפני apply: יוצר סימון, ואם [createBackup] — מזיז ב-rename את ה-DB
  /// (וה-sidecars שלו) אל `.backup`. מנקה שאריות קודמות תחילה.
  ///
  /// [createBackup] — `true` במסלול החלפת קובץ (הורדה מלאה): ה-DB חייב להיות
  /// סגור, ואחרי הקריאה הוא כבר אינו ב-dbPath. במסלול patch דלתאי חובה `false`:
  /// ה-apply כותב לתוך ה-DB החי בתוך transaction יחיד, וקריסה מתגלגלת מעצמה.
  Future<void> beginApply({
    required String dbPath,
    required int fromVersion,
    required int toVersion,
    required String timestamp,
    bool createBackup = true,
  }) async {
    // גיבוי ללא DB חי לצדו הוא העותק היחיד ואסור למחקו: ה-rename שאחריו ייכשל,
    // הסימון יישאר, והעלייה הבאה תשחזר ממנו.
    if (File(dbPath).existsSync()) {
      _deleteWithSidecars(backupPathFor(dbPath));
    }
    _deleteQuietly(markerPathFor(dbPath));

    File(markerPathFor(dbPath)).writeAsStringSync(
      jsonEncode({
        'fromVersion': fromVersion,
        'toVersion': toVersion,
        'timestamp': timestamp,
      }),
      flush: true,
    );

    if (createBackup) {
      try {
        _renameWithSidecars(dbPath, backupPathFor(dbPath));
      } catch (_) {
        // רק אם ה-DB לא זז כלל; אחרת הסימון הוא מה שמונע את מחיקת הגיבוי
        // כ"שאריות" בעלייה הבאה.
        if (File(dbPath).existsSync()) _deleteQuietly(markerPathFor(dbPath));
        rethrow;
      }
    }
  }

  /// נקרא אחרי apply מוצלח — ה-DB תקין, מוחקים סימון וגיבוי.
  void finishSuccess(String dbPath) {
    _deleteQuietly(markerPathFor(dbPath));
    _deleteWithSidecars(backupPathFor(dbPath));
  }

  /// מנקה סימון/גיבוי תקועים אחרי שזוהה מצב לא תקין ודווח (לא מחיקה שקטה).
  void clearStaleArtifacts(String dbPath) {
    _deleteQuietly(markerPathFor(dbPath));
    _deleteWithSidecars(backupPathFor(dbPath));
  }

  /// נקרא אחרי apply כושל — משחזר את הגיבוי ומנקה.
  Future<void> rollback(String dbPath) async {
    if (File(backupPathFor(dbPath)).existsSync()) {
      _restore(backupPathFor(dbPath), dbPath);
    }
    _deleteQuietly(markerPathFor(dbPath));
  }

  /// מחזיר את הגיבוי אל [dbPath] ב-rename (אותה תיקייה — אטומי, ללא העתקה).
  /// ה-sidecars של [dbPath] נמחקים קודם, כדי ש-journal של DB אחר לא יוחל עליו.
  void _restore(String backupPath, String dbPath) {
    _deleteWithSidecars(dbPath);
    _renameWithSidecars(backupPath, dbPath);
  }

  /// מזיז את הקובץ יחד עם ה-sidecars שלו, כדי ש-hot journal יגולגל על ה-DB
  /// שלו ולא על זה שיישב במקומו.
  void _renameWithSidecars(String from, String to) {
    File(from).renameSync(to);
    for (final suffix in _sidecarSuffixes) {
      final sidecar = File('$from$suffix');
      if (sidecar.existsSync()) sidecar.renameSync('$to$suffix');
    }
  }

  void _deleteWithSidecars(String path) {
    _deleteQuietly(path);
    for (final suffix in _sidecarSuffixes) {
      _deleteQuietly('$path$suffix');
    }
  }

  void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}
