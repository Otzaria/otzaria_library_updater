import 'dart:io';

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

  test('beginApply יוצר גיבוי מאומת וסימון', () async {
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
