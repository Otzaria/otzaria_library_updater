// מחולל את test/logical_hash_contract.json (סכמה 6, קפוא) ואת
// test/logical_hash_contract_schema_7.json — ה-oracle המשותף ל-Dart ול-Kotlin
// עבור hash-לפי-טבלה. הריצו מחדש רק כששינוי בחוזה ה-hash מכוון.
import 'dart:convert';
import 'dart:io';

import 'package:seforim_library_updater/src/services/patch_applier.dart';
import 'package:seforim_library_updater/src/services/logical_content_hasher.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

const setupSql = <String>[
  'CREATE TABLE schema_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)',
  "INSERT INTO schema_meta VALUES ('db_version','7'),('db_schema_version','6')",
  'CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)',
  "INSERT INTO source VALUES (2,'ספריא'),(1,'אוצריא')",
  'CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT NOT NULL, sourceId INTEGER, order_idx REAL, notes TEXT)',
  "INSERT INTO book VALUES (10,'בְּרֵאשִׁית',1,1.5,NULL),(3,'﻿שמות',2,2.0,''),(7,'ויקרא — פירוש \"רש\"\"י\"',1,-3.25,'multi\nline\ttext')",
  'CREATE TABLE line (id INTEGER PRIMARY KEY, bookId INTEGER NOT NULL, lineIndex INTEGER NOT NULL, heRef TEXT, charCount INTEGER NOT NULL DEFAULT 0)',
  "INSERT INTO line VALUES (1,10,0,'בראשית א:א',9),(2,10,1,NULL,5),(3,3,0,'שמות א:א',9),(9007199254740993,7,0,NULL,6)",
  'CREATE TABLE line_content (id INTEGER PRIMARY KEY, content TEXT NOT NULL)',
  "INSERT INTO line_content VALUES (9007199254740993,'big id'),(3,'ואלה שמות'),(1,'<b>בראשית</b> ברא'),(2,'אלקים')",
  'CREATE TABLE version_line (versionId INTEGER NOT NULL, lineId INTEGER NOT NULL, content TEXT, charCount INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (versionId, lineId))',
  "INSERT INTO version_line VALUES (1,2,NULL,5),(1,1,'בראשית ברא',9)",
  'CREATE TABLE book_author (bookId INTEGER NOT NULL, authorId INTEGER NOT NULL, PRIMARY KEY (bookId, authorId))',
  'INSERT INTO book_author VALUES (10,2),(3,1),(10,1)',
  'CREATE TABLE link (id INTEGER PRIMARY KEY, sourceLineId INTEGER, targetLineId INTEGER, payload BLOB)',
  "INSERT INTO link VALUES (1,1,3,X'00FF1F02'),(2,2,NULL,X''),(3,3,1,NULL)",
  'CREATE TABLE generation (id INTEGER PRIMARY KEY, name TEXT)',
];

/// סכמה 7: אותן טבלאות בסכמה 7, ועוד טבלאות שבהן סדר המפתח הראשי שונה מסדר
/// כל העמודות לפי האלף-בית — השורות מוכנסות שלא לפי אף אחד מהם.
final setupSqlSchema7 = <String>[
  for (final sql in setupSql)
    sql.replaceFirst("('db_schema_version','6')", "('db_schema_version','7')"),
  'CREATE TABLE line_dh (bookId INTEGER NOT NULL, dhText TEXT NOT NULL, lineIndex INTEGER NOT NULL, dhDisplay TEXT NOT NULL, PRIMARY KEY (bookId, dhText, lineIndex)) WITHOUT ROWID',
  "INSERT INTO line_dh VALUES (10,'בראשית',1,'א'),(10,'אלה',0,'ב'),(3,'ואלה',0,'ג')",
  'CREATE TABLE link_anchor (linkId INTEGER NOT NULL, side INTEGER NOT NULL DEFAULT 0, charStart INTEGER NOT NULL, charEnd INTEGER, label TEXT, PRIMARY KEY (linkId, side, charStart))',
  "INSERT INTO link_anchor VALUES (2,0,4,5,NULL),(1,1,0,9,'ב'),(1,0,7,1,'א')",
  'CREATE TABLE book_banner (bookId INTEGER PRIMARY KEY NOT NULL, text TEXT NOT NULL)',
  "INSERT INTO book_banner VALUES (10,'באדיבות'),(3,'שורה\nשנייה')",
  'CREATE TABLE line_divine_name (lineId INTEGER NOT NULL, charStart INTEGER NOT NULL, charEnd INTEGER NOT NULL, kind INTEGER NOT NULL, source INTEGER NOT NULL, PRIMARY KEY (lineId, charStart)) WITHOUT ROWID',
  'INSERT INTO line_divine_name VALUES (2,20,24,3,4),(1,0,4,1,1),(2,3,6,7,3),(1,12,17,5,2)',
  'CREATE TABLE line_note (lineId INTEGER NOT NULL, noteIndex INTEGER NOT NULL, charPos INTEGER NOT NULL, marker TEXT, body TEXT NOT NULL, PRIMARY KEY (lineId, noteIndex)) WITHOUT ROWID',
  "INSERT INTO line_note VALUES (2,0,5,'1','הערה <i>פנימית</i> א'),(1,1,12,NULL,'נספח בסוף השורה'),(1,0,3,'*','גוף \"ב\"\nשורה שנייה'),(2,1,9,'<b>2</b>','<b>ב</b> &amp; ג')",
  'CREATE TABLE line_note_divine_name (lineId INTEGER NOT NULL, noteIndex INTEGER NOT NULL, charStart INTEGER NOT NULL, charEnd INTEGER NOT NULL, kind INTEGER NOT NULL, source INTEGER NOT NULL, PRIMARY KEY (lineId, noteIndex, charStart)) WITHOUT ROWID',
  'INSERT INTO line_note_divine_name VALUES (2,0,0,4,1,1),(1,1,6,11,5,2),(1,0,3,6,7,3),(2,0,10,14,3,4)',
];

void main() {
  _write('test/logical_hash_contract.json', 6, setupSql);
  _write('test/logical_hash_contract_schema_7.json', 7, setupSqlSchema7);
}

void _write(String path, int schemaVersion, List<String> setupSql) {
  final db = sqlite3.sqlite3.openInMemory();
  for (final sql in setupSql) {
    db.execute(sql);
  }
  final tableOrder = hashTableOrderForSchemaVersion(schemaVersion);
  final rowOrder = hashRowOrderForSchemaVersion(schemaVersion);
  const hasher = LogicalContentHasher();
  final tableHashes = <String, String>{
    for (final t in tableOrder)
      t: hasher.compute(db, tableOrder: [t], rowOrder: rowOrder),
  };
  final whole = hasher.compute(db, tableOrder: tableOrder, rowOrder: rowOrder);
  final fixture = {
    'contractVersion': 1,
    'description':
        'Shared oracle for the per-table logical content hash. tableHashes[t] = '
            'sha256 of exactly the bytes the whole-DB hasher emits for table t '
            '(" table:<t> " prefix, then cols + rows when the table exists). '
            'wholeHash = sha256 of the concatenation of those per-table streams '
            'in hashTableOrder. Generated by tool/gen_logical_hash_fixture.dart '
            '(Dart hasher, byte-verified against the real v14/v15 chain).',
    'schemaVersion': schemaVersion,
    'hashTableOrder': tableOrder,
    // סכמה 6 קפואה בלי השדה: אין בה סדר שורות מוצהר.
    if (rowOrder != null)
      'hashRowOrder': {for (final t in tableOrder) t: rowOrder[t]},
    'setupSql': setupSql,
    'wholeHash': whole,
    'tableHashes': tableHashes,
  };
  final json = const JsonEncoder.withIndent('  ').convert(fixture);
  File(path).writeAsStringSync('$json\n');
  db.close();
  stdout.writeln('$path whole=$whole tables=${tableHashes.length}');
}
