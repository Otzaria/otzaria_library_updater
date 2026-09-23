import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';
import 'package:seforim_library_updater/src/services/library_db_recovery_service.dart';

void main() {
  const service = LibraryDbRecoveryService();
  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('recovery_test');
    dbPath = '${tmp.path}/seforim.db';
    File(dbPath).writeAsStringSync('ORIGINAL');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('beginApply יוצר גיבוי וסימון', () async {
    await service.beginApply(
      dbPath: dbPath,
      fromVersion: 1,
      toVersion: 2,
      timestamp: '2026-06-28T00:00:00Z',
    );
    expect(File(service.backupPathFor(dbPath)).existsSync(), isTrue);
    expect(File(service.markerPathFor(dbPath)).existsSync(), isTrue);
    expect(File(service.backupPathFor(dbPath)).readAsStringSync(), 'ORIGINAL');
    // אין שאריות temp
    expect(File('$dbPath.backup.tmp').existsSync(), isFalse);
  });

  test('beginApply מגבה ב-rename — בלי לכתוב בייט נוסף לדיסק', () async {
    final big = List<int>.generate(1 << 20, (i) => i & 0xff);
    File(dbPath).writeAsBytesSync(big);
    final dbInode = _inode(dbPath);

    await service.beginApply(
        dbPath: dbPath, fromVersion: 1, toVersion: 2, timestamp: 't');

    final backup = service.backupPathFor(dbPath);
    // ה-DB הוזז: אינו במקומו, והגיבוי הוא אותו קובץ (inode) ולא עותק.
    expect(File(dbPath).existsSync(), isFalse);
    expect(File(backup).readAsBytesSync(), big);
    expect(_inode(backup), dbInode);
    // סך הבייטים בתיקייה (מלבד הסימון הזעיר) = גודל ה-DB בלבד — לא 2S.
    expect(_bytesExcept(tmp, service.markerPathFor(dbPath)), big.length);
  });

  test('beginApply שנכשל בכתיבת הסימון משאיר את ה-DB במקומו', () async {
    // תיקייה בנתיב הסימון מכשילה את כתיבתו. הסימון חייב להיכתב לפני ה-rename:
    // גיבוי בלי סימון נחשב שאריות ונמחק בעלייה — אסור שיהיה העותק היחיד.
    Directory(service.markerPathFor(dbPath)).createSync();
    await expectLater(
      service.beginApply(
          dbPath: dbPath, fromVersion: 1, toVersion: 2, timestamp: 't'),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(dbPath).readAsStringSync(), 'ORIGINAL');
    expect(File(service.backupPathFor(dbPath)).existsSync(), isFalse);
  });

  test('rename שנכשל לפני שה-DB זז — הסימון לא נשאר יתום', () async {
    // תיקייה בנתיב הגיבוי מכשילה את ה-rename בעוד ה-DB במקומו.
    final backupDir = Directory(service.backupPathFor(dbPath))..createSync();
    File('${backupDir.path}/blocker').writeAsStringSync('x');
    await expectLater(
      service.beginApply(
          dbPath: dbPath, fromVersion: 1, toVersion: 2, timestamp: 't'),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(dbPath).readAsStringSync(), 'ORIGINAL');
    // סימון יתום היה מכריח quick_check מלא (דקה+) בעלייה הבאה.
    expect(File(service.markerPathFor(dbPath)).existsSync(), isFalse);
  });

  test('rename שנכשל אחרי שה-DB זז — הסימון נשאר ושומר על הגיבוי', () async {
    File('$dbPath-wal').writeAsStringSync('W');
    // תיקייה בנתיב ה-wal של הגיבוי: ה-DB עובר, הזזת ה-sidecar נכשלת.
    final walDir = Directory('${service.backupPathFor(dbPath)}-wal')
      ..createSync();
    File('${walDir.path}/blocker').writeAsStringSync('x');
    await expectLater(
      service.beginApply(
          dbPath: dbPath, fromVersion: 1, toVersion: 2, timestamp: 't'),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(dbPath).existsSync(), isFalse);
    expect(File(service.backupPathFor(dbPath)).readAsStringSync(), 'ORIGINAL');
    expect(File(service.markerPathFor(dbPath)).existsSync(), isTrue);

    // ה-WAL שלא הספיק לזוז הוא של ה-DB שבגיבוי; מחיקתו = אובדן עסקה מאושרת.
    expect(File('$dbPath-wal').readAsStringSync(), 'W');

    walDir.deleteSync(recursive: true);
    final result = await service.recoverIfNeeded(dbPath);
    expect(result.action, RecoveryAction.restored);
    expect(File(dbPath).readAsStringSync(), 'ORIGINAL');
    expect(File('$dbPath-wal').readAsStringSync(), 'W');
  });

  test('beginApply לא מוחק גיבוי שהוא העותק היחיד (ה-DB חסר)', () async {
    File(service.backupPathFor(dbPath)).writeAsStringSync('ONLY-COPY');
    File(dbPath).deleteSync();
    await expectLater(
      service.beginApply(
          dbPath: dbPath, fromVersion: 1, toVersion: 2, timestamp: 't'),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(service.backupPathFor(dbPath)).readAsStringSync(), 'ONLY-COPY');
    final result = await service.recoverIfNeeded(dbPath);
    expect(result.action, RecoveryAction.restored);
    expect(File(dbPath).readAsStringSync(), 'ONLY-COPY');
  });

  test('beginApply מזיז את ה-sidecars עם ה-DB, ו-rollback מחזיר אותם',
      () async {
    File('$dbPath-journal').writeAsStringSync('J');
    File('$dbPath-wal').writeAsStringSync('W');
    await service.beginApply(
        dbPath: dbPath, fromVersion: 1, toVersion: 2, timestamp: 't');
    final backup = service.backupPathFor(dbPath);
    expect(File('$dbPath-journal').existsSync(), isFalse);
    expect(File('$dbPath-wal').existsSync(), isFalse);
    expect(File('$backup-journal').readAsStringSync(), 'J');
    expect(File('$backup-wal').readAsStringSync(), 'W');

    await service.rollback(dbPath);
    expect(File('$dbPath-journal').readAsStringSync(), 'J');
    expect(File('$dbPath-wal').readAsStringSync(), 'W');
    expect(File('$backup-journal').existsSync(), isFalse);
    expect(File('$backup-wal').existsSync(), isFalse);
  });

  test('hot journal של ה-DB המגובה מגולגל עליו אחרי שחזור, לא על DB אחר',
      () async {
    final crashed = _makeHotJournalDb(tmp.path);
    await service.beginApply(
        dbPath: crashed, fromVersion: 1, toVersion: 2, timestamp: 't');
    // ה-DB החדש נכנס למקום; אסור שה-journal הישן יישאר לצדו.
    File(crashed).writeAsStringSync('NEW-DB');
    expect(File('$crashed-journal').existsSync(), isFalse);

    final result = await service.recoverIfNeeded(crashed);
    expect(result.action, RecoveryAction.restored);
    expect(File('$crashed-journal').existsSync(), isTrue);
    expect(service.checkDbHealthAfterCrash(crashed), isTrue);
    final db = sqlite3.sqlite3.open(crashed, mode: sqlite3.OpenMode.readOnly);
    expect(db.select("SELECT count(*) c FROM t WHERE v='A'").first['c'], 20000);
    db.close();
  });

  test('beginApply(createBackup: false) כותב סימון בלבד — בלי העתקת ה-DB',
      () async {
    await service.beginApply(
      dbPath: dbPath,
      fromVersion: 1,
      toVersion: 2,
      timestamp: 't',
      createBackup: false,
    );
    expect(File(service.markerPathFor(dbPath)).existsSync(), isTrue);
    expect(File(service.backupPathFor(dbPath)).existsSync(), isFalse);
    expect(File('$dbPath.backup.tmp').existsSync(), isFalse);
    expect(File(dbPath).readAsStringSync(), 'ORIGINAL'); // ה-DB נשאר במקומו
  });

  test('rollback ללא גיבוי (מסלול דלתא) מנקה סימון בלי לגעת ב-DB', () async {
    await service.beginApply(
      dbPath: dbPath,
      fromVersion: 1,
      toVersion: 2,
      timestamp: 't',
      createBackup: false,
    );
    await service.rollback(dbPath);
    expect(File(dbPath).readAsStringSync(), 'ORIGINAL');
    expect(File(service.markerPathFor(dbPath)).existsSync(), isFalse);
  });

  test('finishSuccess מנקה גיבוי וסימון', () async {
    await service.beginApply(
        dbPath: dbPath, fromVersion: 1, toVersion: 2, timestamp: 't');
    service.finishSuccess(dbPath);
    expect(File(service.backupPathFor(dbPath)).existsSync(), isFalse);
    expect(File(service.markerPathFor(dbPath)).existsSync(), isFalse);
  });

  test('rollback משחזר את ה-DB מהגיבוי', () async {
    await service.beginApply(
        dbPath: dbPath, fromVersion: 1, toVersion: 2, timestamp: 't');
    File(dbPath).writeAsStringSync('CORRUPTED-HALF-WRITE');
    await service.rollback(dbPath);
    expect(File(dbPath).readAsStringSync(), 'ORIGINAL');
    expect(File(service.backupPathFor(dbPath)).existsSync(), isFalse);
    expect(File(service.markerPathFor(dbPath)).existsSync(), isFalse);
  });

  group('checkDbHealthAfterCrash', () {
    test('מגלגל hot journal (קריסה באמצע apply) ומחזיר true', () {
      final crashed = _makeHotJournalDb(tmp.path);
      // רגרסיה: פתיחת readOnly על hot journal נכשלת ב-"readonly database".
      expect(
        () => sqlite3.sqlite3
            .open(crashed, mode: sqlite3.OpenMode.readOnly)
            .select('PRAGMA quick_check'),
        throwsA(isA<sqlite3.SqliteException>()),
      );
      // ה-RW של השירות מגלגל את ה-journal ומאמת תקינות.
      expect(service.checkDbHealthAfterCrash(crashed), isTrue);
      expect(File('$crashed-journal').existsSync(), isFalse);
    });

    test('DB פגום → false', () {
      final broken = '${tmp.path}/broken.db';
      File(broken).writeAsBytesSync(List.filled(4096, 0x7a));
      expect(service.checkDbHealthAfterCrash(broken), isFalse);
    });
  });

  group('recoverIfNeeded', () {
    test('marker+backup → שחזור (סימולציית קריסה)', () async {
      await service.beginApply(
          dbPath: dbPath, fromVersion: 1, toVersion: 2, timestamp: 't');
      File(dbPath).writeAsStringSync('HALF-APPLIED'); // קריסה באמצע
      final result = await service.recoverIfNeeded(dbPath);
      expect(result.action, RecoveryAction.restored);
      expect(File(dbPath).readAsStringSync(), 'ORIGINAL');
      expect(File(service.markerPathFor(dbPath)).existsSync(), isFalse);
      expect(File(service.backupPathFor(dbPath)).existsSync(), isFalse);
    });

    test('שחזור ב-rename — הגיבוי חוזר כאותו קובץ, בלי עותק ביניים', () async {
      final big = List<int>.generate(1 << 20, (i) => i & 0xff);
      File(dbPath).writeAsBytesSync(big);
      await service.beginApply(
          dbPath: dbPath, fromVersion: 1, toVersion: 2, timestamp: 't');
      final backupInode = _inode(service.backupPathFor(dbPath));
      // קריסה אחרי מחיקת ה-DB הישן ולפני הכנסת החדש: ה-DB חסר לגמרי.
      expect(File(dbPath).existsSync(), isFalse);

      final result = await service.recoverIfNeeded(dbPath);
      expect(result.action, RecoveryAction.restored);
      expect(File(dbPath).readAsBytesSync(), big);
      expect(_inode(dbPath), backupInode);
      expect(File('$dbPath.restore.tmp').existsSync(), isFalse);
      expect(_bytesExcept(tmp, ''), big.length);
    });

    test('אין marker → none', () async {
      final result = await service.recoverIfNeeded(dbPath);
      expect(result.action, RecoveryAction.none);
      expect(File(dbPath).readAsStringSync(), 'ORIGINAL');
    });

    test('marker ללא backup → blockedMissingBackup (לא מחיקה שקטה)', () async {
      File(service.markerPathFor(dbPath)).writeAsStringSync('{}');
      final result = await service.recoverIfNeeded(dbPath);
      expect(result.action, RecoveryAction.blockedMissingBackup);
      expect(result.detail, isNotNull);
      expect(File(service.markerPathFor(dbPath)).existsSync(), isTrue);
    });

    test('backup יתום ללא marker → נמחק, none', () async {
      File(service.backupPathFor(dbPath)).writeAsStringSync('STALE');
      final result = await service.recoverIfNeeded(dbPath);
      expect(result.action, RecoveryAction.none);
      expect(File(service.backupPathFor(dbPath)).existsSync(), isFalse);
    });

    test('שארית backup.tmp (קריסה לפני rename) נמחקת ולא משוחזרת ממנה',
        () async {
      // backup.tmp יתום מדמה קריסה באמצע יצירת גיבוי — אסור לשחזר ממנו.
      File('$dbPath.backup.tmp').writeAsStringSync('PARTIAL');
      final result = await service.recoverIfNeeded(dbPath);
      expect(result.action, RecoveryAction.none);
      expect(File('$dbPath.backup.tmp').existsSync(), isFalse);
      expect(File(dbPath).readAsStringSync(), 'ORIGINAL'); // ה-DB לא נגוע
    });
  });
}

/// מזהה הקובץ במערכת הקבצים: rename משמר אותו, copy יוצר חדש.
int _inode(String path) {
  final args = Platform.isMacOS ? ['-f', '%i', path] : ['-c', '%i', path];
  final result = Process.runSync('stat', args);
  return int.parse((result.stdout as String).trim());
}

/// סך הבייטים של כל הקבצים בתיקייה, מלבד [except].
int _bytesExcept(Directory dir, String except) => dir
    .listSync()
    .whereType<File>()
    .where((f) => f.path != except)
    .fold(0, (sum, f) => sum + f.lengthSync());

/// בונה DB עם hot journal אמיתי (מדמה קריסה באמצע transaction) ומחזיר את נתיבו.
/// cache_size זעיר מכריח דפים מלוכלכים להישפך ל-DB תוך כדי ה-transaction, כך
/// שהעתקת הזוג (db+journal) לפני ה-COMMIT לוכדת מצב שדורש גלגול.
String _makeHotJournalDb(String dir) {
  final src = '$dir/live.db';
  var c = sqlite3.sqlite3.open(src);
  c.execute('PRAGMA journal_mode=DELETE');
  c.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)');
  c.execute('BEGIN');
  final ins = c.prepare('INSERT INTO t VALUES (?,?)');
  for (var i = 0; i < 20000; i++) {
    ins.execute([i, 'A']);
  }
  ins.close();
  c.execute('COMMIT');
  c.close();

  c = sqlite3.sqlite3.open(src);
  c.execute('PRAGMA journal_mode=DELETE');
  c.execute('PRAGMA cache_size=10');
  c.execute('BEGIN IMMEDIATE');
  c.execute("UPDATE t SET v='B'");

  final crashed = '$dir/crashed.db';
  File(src).copySync(crashed);
  File('$src-journal').copySync('$crashed-journal');

  c.execute('ROLLBACK');
  c.close();
  return crashed;
}
