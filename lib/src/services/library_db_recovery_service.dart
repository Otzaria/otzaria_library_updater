import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// הפעולה שבוצעה (או נדרשת) בעת בדיקת התאוששות בעליית האפליקציה.
enum RecoveryAction {
  /// אין עדכון שנקטע — שום דבר לא נדרש.
  none,

  /// נמצא עדכון שנקטע וה-DB שוחזר מהגיבוי.
  restored,

  /// נמצא סימון עדכון שנקטע אך ללא גיבוי — מצב לא תקין הדורש הורדה מלאה.
  blockedMissingBackup,
}

class RecoveryResult {
  final RecoveryAction action;
  final String? detail;
  const RecoveryResult(this.action, [this.detail]);
}

/// נזרק כשגיבוי שנוצר חלקי/מושחת (גודל לא תואם).
class BackupIntegrityException implements Exception {
  final String message;
  const BackupIntegrityException(this.message);
  @override
  String toString() => 'BackupIntegrityException: $message';
}

/// מנהל גיבוי, סימון (marker) ושחזור של `seforim.db` סביב החלת patch, כדי
/// שקריסה באמצע apply תהיה ניתנת לשחזור.
///
/// קבצים ליד ה-DB:
/// * `<db>.backup`     — עותק מאומת לפני העדכון.
/// * `<db>.backup.tmp` — עותק זמני לפני אימות (rename אטומי ל-.backup).
/// * `<db>.applying`   — סימון JSON (fromVersion/toVersion/timestamp).
///
/// אינווריאנט: `.backup` קיים ⟺ הוא שלם (נכתב ל-tmp, אומת, ועבר rename).
/// כך `rollback` לעולם לא משחזר גיבוי חלקי על DB תקין.
class LibraryDbRecoveryService {
  const LibraryDbRecoveryService();

  String backupPathFor(String dbPath) => '$dbPath.backup';
  String markerPathFor(String dbPath) => '$dbPath.applying';
  String _backupTmpFor(String dbPath) => '$dbPath.backup.tmp';
  String _restoreTmpFor(String dbPath) => '$dbPath.restore.tmp';

  /// נקרא בעליית האפליקציה, **לפני** פתיחת ה-DB.
  ///
  /// * marker + backup קיימים → שחזור מהגיבוי (העדכון נקטע).
  /// * marker בלבד (ללא backup) → [RecoveryAction.blockedMissingBackup]; לא
  ///   מוחקים בשקט — הקורא צריך להפעיל הורדה מלאה.
  /// * backup/tmp יתומים (ללא marker) → שאריות; מוחקים אותם.
  Future<RecoveryResult> recoverIfNeeded(String dbPath) async {
    _deleteQuietly(_backupTmpFor(dbPath));
    _deleteQuietly(_restoreTmpFor(dbPath));

    final marker = File(markerPathFor(dbPath));
    final backup = File(backupPathFor(dbPath));

    if (!marker.existsSync()) {
      if (backup.existsSync()) _deleteQuietly(backup.path);
      return const RecoveryResult(RecoveryAction.none);
    }

    if (!backup.existsSync()) {
      return const RecoveryResult(
        RecoveryAction.blockedMissingBackup,
        'נמצא סימון עדכון שלא הושלם ללא גיבוי — נדרשת הורדה מלאה',
      );
    }

    await _restore(backup.path, dbPath);
    _deleteQuietly(marker.path);
    _deleteQuietly(backup.path);
    return const RecoveryResult(
      RecoveryAction.restored,
      'עדכון שנקטע זוהה — ה-DB שוחזר מהגיבוי',
    );
  }

  /// נקרא לפני apply: יוצר גיבוי מאומת וסימון. מנקה שאריות קודמות תחילה.
  /// ה-copy הכבד רץ ב-Isolate כדי לא לחסום את ה-UI.
  Future<void> beginApply({
    required String dbPath,
    required int fromVersion,
    required int toVersion,
    required String timestamp,
  }) async {
    _deleteQuietly(backupPathFor(dbPath));
    _deleteQuietly(markerPathFor(dbPath));
    final tmp = _backupTmpFor(dbPath);
    _deleteQuietly(tmp);

    // בכשל (disk full וכו') מנקים מיד את ה-tmp החלקי — לא משאירים לכלוך דיסק.
    try {
      await Isolate.run(() => cloneOrCopyFile(dbPath, tmp));
      _verifySameSize(tmp, dbPath, 'גיבוי');
      File(tmp).renameSync(backupPathFor(dbPath));
    } catch (_) {
      _deleteQuietly(tmp);
      rethrow;
    }

    File(markerPathFor(dbPath)).writeAsStringSync(
      jsonEncode({
        'fromVersion': fromVersion,
        'toVersion': toVersion,
        'timestamp': timestamp,
      }),
      flush: true,
    );
  }

  /// נקרא אחרי apply מוצלח — ה-DB תקין, מוחקים סימון וגיבוי.
  void finishSuccess(String dbPath) {
    _deleteQuietly(markerPathFor(dbPath));
    _deleteQuietly(backupPathFor(dbPath));
  }

  /// מנקה סימון/גיבוי תקועים אחרי שזוהה מצב לא תקין ודווח (לא מחיקה שקטה).
  void clearStaleArtifacts(String dbPath) {
    _deleteQuietly(markerPathFor(dbPath));
    _deleteQuietly(backupPathFor(dbPath));
  }

  /// נקרא אחרי apply כושל — משחזר את הגיבוי ומנקה.
  Future<void> rollback(String dbPath) async {
    if (File(backupPathFor(dbPath)).existsSync()) {
      await _restore(backupPathFor(dbPath), dbPath);
    }
    _deleteQuietly(markerPathFor(dbPath));
    _deleteQuietly(backupPathFor(dbPath));
  }

  /// משחזר [backupPath] אל [dbPath] דרך עותק זמני מאומת, ואז rename אטומי.
  /// אינו מוחק את [backupPath] — כך האינווריאנט נשמר עד שהקורא מנקה.
  Future<void> _restore(String backupPath, String dbPath) async {
    final tmp = _restoreTmpFor(dbPath);
    _deleteQuietly(tmp);
    await Isolate.run(() => cloneOrCopyFile(backupPath, tmp));
    _verifySameSize(tmp, backupPath, 'שחזור');
    _deleteQuietly('$dbPath-wal');
    _deleteQuietly('$dbPath-shm');
    _deleteQuietly(dbPath);
    File(tmp).renameSync(dbPath);
  }

  void _verifySameSize(String actual, String expected, String label) {
    final a = File(actual).lengthSync();
    final e = File(expected).lengthSync();
    if (a != e) {
      _deleteQuietly(actual);
      throw BackupIntegrityException('$label חלקי: $a בייטים מתוך $e');
    }
  }

  void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}

/// מעתיק קובץ. מנסה reflink/clonefile (מיידי ב-APFS/Btrfs) לפני byte-copy
/// יקר. פונקציה top-level כדי שתוכל לרוץ דרך `Isolate.run`.
void cloneOrCopyFile(String src, String dst) {
  try {
    if (Platform.isMacOS) {
      if (Process.runSync('cp', ['-c', src, dst]).exitCode == 0) return;
    } else if (Platform.isLinux) {
      if (Process.runSync('cp', ['--reflink=auto', src, dst]).exitCode == 0) {
        return;
      }
    }
  } catch (_) {
    // נופלים ל-copy רגיל
  }
  final dstFile = File(dst);
  if (dstFile.existsSync()) dstFile.deleteSync();
  File(src).copySync(dst);
}
