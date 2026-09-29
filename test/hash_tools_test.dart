import 'dart:io';

import 'package:seforim_library_updater/src/models/patch_table_spec.dart';
import 'package:seforim_library_updater/src/services/logical_content_hasher.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';

import '../tool/src/db_hash_order.dart';

/// כלי ה-hash שב-tool/ בוחרים את הסדר לפי סכמת ה-DB, לא לפי הסכמה הנוכחית.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('hash_tools_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String writeDb({String? schemaVersion}) {
    final path = '${tmp.path}${Platform.pathSeparator}seforim.db';
    final db = sqlite3.sqlite3.open(path);
    try {
      db.execute('CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT)');
      db.execute("INSERT INTO schema_meta VALUES ('db_version','7')");
      if (schemaVersion != null) {
        db.execute("INSERT INTO schema_meta VALUES ('db_schema_version',?)",
            [schemaVersion]);
      }
      db.execute('CREATE TABLE line (id INTEGER PRIMARY KEY, content TEXT)');
      db.execute("INSERT INTO line VALUES (1,'בראשית ברא')");
    } finally {
      db.close();
    }
    return path;
  }

  test('DB בסכמה 5 מקבל את סדר סכמה 5 ואת ה-hash שלה', () {
    final path = writeDb(schemaVersion: '5');
    final order = hashTableOrderForDbFile(path);
    expect(order, same(kHashTableOrderSchema5));

    final db = sqlite3.sqlite3.open(path, mode: sqlite3.OpenMode.readOnly);
    try {
      const hasher = LogicalContentHasher();
      final hash = hasher.compute(db, tableOrder: order);
      expect(hash, hasher.compute(db, tableOrder: kHashTableOrderSchema5));
      expect(hash, isNot(hasher.compute(db, tableOrder: kHashTableOrder)));
    } finally {
      db.close();
    }
  });

  test('DB בסכמה 6 מקבל את סדר סכמה 6', () {
    expect(hashTableOrderForDbFile(writeDb(schemaVersion: '6')),
        same(kHashTableOrderSchema6));
  });

  test('DB בלי db_schema_version נכשל במקום לנחש סדר', () {
    expect(() => hashTableOrderForDbFile(writeDb()), throwsStateError);
  });
}
