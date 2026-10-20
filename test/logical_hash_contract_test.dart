import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:seforim_library_updater/src/services/logical_content_hasher.dart';
import 'package:seforim_library_updater/src/services/patch_applier.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

const _hasher = LogicalContentHasher();

/// ה-oracle המשותף ל-Dart ול-Kotlin, לסכמה 6 (קפוא) ולסכמה 7. עותק זהה אות-באות
/// נמצא בצד הקוטליני (`generator/common/src/jvmTest/resources/`) ומושווה ב-CI.
void main() {
  _oracle('test/logical_hash_contract.json');
  _oracle('test/logical_hash_contract_schema_7.json');
}

void _oracle(String path) {
  final fixture =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final schemaVersion = fixture['schemaVersion'] as int;
  final order = (fixture['hashTableOrder'] as List).cast<String>();
  final rowOrder = (fixture['hashRowOrder'] as Map<String, dynamic>?)
      ?.map((t, pk) => MapEntry(t, (pk as List).cast<String>()));
  final expectedTables =
      (fixture['tableHashes'] as Map).cast<String, dynamic>();

  sqlite3.Database buildDb() {
    final db = sqlite3.sqlite3.openInMemory();
    for (final sql in (fixture['setupSql'] as List).cast<String>()) {
      db.execute(sql);
    }
    return db;
  }

  group('logical hash contract (oracle, סכמה $schemaVersion)', () {
    test('סדר הטבלאות והשורות של הסכמה תואם ל-fixture', () {
      expect(hashTableOrderForSchemaVersion(schemaVersion), order);
      expect(hashRowOrderForSchemaVersion(schemaVersion), rowOrder);
    });

    test('wholeHash ו-hash לכל טבלה תואמים ל-fixture', () {
      final db = buildDb();
      final report =
          _hasher.computeReport(db, tableOrder: order, rowOrder: rowOrder);
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
        _hasher.compute(db, tableOrder: order, rowOrder: rowOrder),
        _hasher
            .computeReport(db, tableOrder: order, rowOrder: rowOrder)
            .wholeHash,
      );
      db.close();
    });

    test('זרם הטבלה הבודדת זהה ל-hash שבדוח (שרשור = הכולל)', () {
      final db = buildDb();
      final report =
          _hasher.computeReport(db, tableOrder: order, rowOrder: rowOrder);
      for (final t in order) {
        expect(_hasher.compute(db, tableOrder: [t], rowOrder: rowOrder),
            report.tableHashes[t],
            reason: 'טבלה $t');
      }
      db.close();
    });

    test('תת-קבוצה: wholeHash ריק, רק הטבלאות שבוקשו', () {
      final db = buildDb();
      final full =
          _hasher.computeReport(db, tableOrder: order, rowOrder: rowOrder);
      final subset = _hasher.computeReport(db,
          tableOrder: order, rowOrder: rowOrder, only: {'book', 'line'});
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
          tableOrder: order,
          rowOrder: rowOrder,
          onProgress: (bytes) => streamed = bytes);
      final sum = report.tableBytes.values.fold<int>(0, (a, b) => a + b);
      expect(sum, streamed);
      db.close();
    });
  });
}
