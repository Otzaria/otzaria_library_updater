import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:seforim_library_updater/src/services/logical_content_hasher.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

const _hasher = LogicalContentHasher();

/// ה-oracle המשותף ל-Dart ול-Kotlin. עותק זהה אות-באות נמצא בצד הקוטליני
/// (`generator/common/src/jvmTest/resources/`) ומושווה ב-CI.
void main() {
  final fixture = jsonDecode(
    File('test/logical_hash_contract.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final order = (fixture['hashTableOrder'] as List).cast<String>();
  final expectedTables =
      (fixture['tableHashes'] as Map).cast<String, dynamic>();

  sqlite3.Database buildDb() {
    final db = sqlite3.sqlite3.openInMemory();
    for (final sql in (fixture['setupSql'] as List).cast<String>()) {
      db.execute(sql);
    }
    return db;
  }

  group('logical hash contract (oracle)', () {
    test('wholeHash ו-hash לכל טבלה תואמים ל-fixture', () {
      final db = buildDb();
      final report = _hasher.computeReport(db, tableOrder: order);
      expect(report.wholeHash, fixture['wholeHash']);
      expect(report.tableHashes.keys, order);
      for (final t in order) {
        expect(report.tableHashes[t], expectedTables[t], reason: 'טבלה $t');
      }
      db.close();
    });

    test('compute() זהה ל-computeReport().wholeHash', () {
      final db = buildDb();
      expect(
        _hasher.compute(db, tableOrder: order),
        _hasher.computeReport(db, tableOrder: order).wholeHash,
      );
      db.close();
    });

    test('זרם הטבלה הבודדת זהה ל-hash שבדוח (שרשור = הכולל)', () {
      final db = buildDb();
      final report = _hasher.computeReport(db, tableOrder: order);
      for (final t in order) {
        expect(_hasher.compute(db, tableOrder: [t]), report.tableHashes[t],
            reason: 'טבלה $t');
      }
      db.close();
    });

    test('תת-קבוצה: wholeHash ריק, רק הטבלאות שבוקשו', () {
      final db = buildDb();
      final full = _hasher.computeReport(db, tableOrder: order);
      final subset =
          _hasher.computeReport(db, tableOrder: order, only: {'book', 'line'});
      expect(subset.wholeHash, isNull);
      expect(subset.tableHashes.keys, ['book', 'line']);
      expect(subset.tableHashes['book'], full.tableHashes['book']);
      expect(subset.tableHashes['line'], full.tableHashes['line']);
      expect(subset.tableBytes['book'], full.tableBytes['book']);
      db.close();
    });

    test('סך הבתים לכל הטבלאות שווה לסך הבתים של המעבר הכולל', () {
      final db = buildDb();
      var streamed = 0;
      final report = _hasher.computeReport(db,
          tableOrder: order, onProgress: (bytes) => streamed = bytes);
      final sum = report.tableBytes.values.fold<int>(0, (a, b) => a + b);
      expect(sum, streamed);
      db.close();
    });
  });
}
