import 'dart:io';

import 'package:test/test.dart';
import 'package:seforim_library_updater/src/models/delta_manifest.dart';
import 'package:seforim_library_updater/src/models/patch_table_spec.dart';
import 'package:seforim_library_updater/src/services/logical_content_hasher.dart';
import 'package:seforim_library_updater/src/services/patch_applier.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

const _hasher = LogicalContentHasher();
const _applier = PatchApplier();

/// ה-fixtures בונים DB ו-patch של סכמה-2, ולכן ה-hash הצפוי חייב להיחשב
/// בסדר הקפוא של סכמה-2 — לא בברירת המחדל, שמאז סכמה-3 כוללת טבלה נוספת.
String _hashWithOrder(String dbPath, List<String> order) {
  final db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
  try {
    return _hasher.compute(db, tableOrder: order);
  } finally {
    db.close();
  }
}

String _hashOf(String dbPath) {
  final db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
  try {
    return _hasher.compute(db, tableOrder: kHashTableOrderSchema2);
  } finally {
    db.close();
  }
}

/// בונה manifest סינתטי. ה-hashes מחושבים מהקבצים בפועל אחרי בנייתם.
/// [fromSchema]/[toSchema] ברירת מחדל 2 → סדר ה-hash הנוכחי (34), תואם ל-
/// [_hashOf] (שמשתמש בברירת המחדל של ה-hasher). בדיקות v14/v15 מעבירות 1.
DeltaManifest _manifest({
  required int from,
  required int to,
  required String fromHash,
  required String toHash,
  int fromSchema = 2,
  int toSchema = 2,
}) =>
    DeltaManifest(
      fromVersion: from,
      toVersion: to,
      fromSchemaVersion: fromSchema,
      toSchemaVersion: toSchema,
      fromContentHash: fromHash,
      toContentHash: toHash,
      patchFiles: const [
        PatchFileEntry(
          file: 'p.db.zst',
          compression: 'zstd',
          sha256: 'x',
          size: 1,
          uncompressedSha256: 'y',
          uncompressedSize: 1,
        ),
      ],
    );

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('patch_applier_test');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // בונה DB מקומי מינימלי עם schema_meta + source.
  String buildBaseDb({required int version, required List<List> sourceRows}) {
    final path = '${tmp.path}/base_$version.db';
    final db = sqlite3.sqlite3.open(path);
    db.execute('CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT)');
    db.execute("INSERT INTO schema_meta VALUES ('db_version','$version'),"
        "('db_schema_version','2')");
    db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)');
    for (final r in sourceRows) {
      db.execute('INSERT INTO source VALUES (?,?)', [r[0], r[1]]);
    }
    db.close();
    return path;
  }

  // בונה patch DB עם patch_meta, migrations, upsert/delete.
  String buildPatchDb({
    required int from,
    required int to,
    int schemaVersion = 1,
    List<String> migrations = const [],
    List<List>? upsertSource,
    List<int>? deleteSource,
  }) {
    final path = '${tmp.path}/patch_$from-$to.db';
    final db = sqlite3.sqlite3.open(path);
    db.execute('CREATE TABLE patch_meta (key TEXT PRIMARY KEY, value TEXT)');
    db.execute("INSERT INTO patch_meta VALUES "
        "('schema_version','$schemaVersion'),"
        "('from_version','$from'),('to_version','$to')");
    db.execute(
        'CREATE TABLE migrations (version INTEGER PRIMARY KEY, sql TEXT)');
    var v = 0;
    for (final m in migrations) {
      db.execute('INSERT INTO migrations VALUES (?,?)', [++v, m]);
    }
    // schema_meta תמיד מתעדכן (db_version מ-from ל-to)
    db.execute(
        'CREATE TABLE upsert_schema_meta (key TEXT PRIMARY KEY, value TEXT)');
    db.execute("INSERT INTO upsert_schema_meta VALUES ('db_version','$to')");
    if (upsertSource != null) {
      db.execute(
          'CREATE TABLE upsert_source (id INTEGER PRIMARY KEY, name TEXT)');
      for (final r in upsertSource) {
        db.execute('INSERT INTO upsert_source VALUES (?,?)', [r[0], r[1]]);
      }
    }
    if (deleteSource != null) {
      db.execute('CREATE TABLE delete_source (id INTEGER PRIMARY KEY)');
      for (final id in deleteSource) {
        db.execute('INSERT INTO delete_source VALUES (?)', [id]);
      }
    }
    db.close();
    return path;
  }

  group('PatchApplier unit', () {
    test('upsert (חדש+עדכון) ו-delete מצליחים ומאמתים hash', () {
      final base = buildBaseDb(version: 1, sourceRows: [
        [1, 'aleph'],
        [2, 'bet'],
      ]);
      final patch = buildPatchDb(
        from: 1,
        to: 2,
        upsertSource: [
          [1, 'ALEPH'], // עדכון
          [3, 'gimel'], // חדש
        ],
        deleteSource: [2], // מחיקה
      );

      // הצפוי אחרי apply: source(1,ALEPH),(3,gimel); db_version=2
      final expected = buildBaseDb(version: 2, sourceRows: [
        [1, 'ALEPH'],
        [3, 'gimel'],
      ]);

      final manifest = _manifest(
        from: 1,
        to: 2,
        fromHash: _hashOf(base),
        toHash: _hashOf(expected),
      );

      final result = _applier.apply(
        dbPath: base,
        patchPath: patch,
        manifest: manifest,
      );

      expect(result.resultHash, manifest.toContentHash);
      expect(_hashOf(base), manifest.toContentHash);
    });

    test('migration רצה לפני upsert', () {
      final base = buildBaseDb(version: 1, sourceRows: [
        [1, 'a'],
      ]);
      // migration מוסיף עמודה; ה-upsert משתמש בה
      final patch = buildPatchDb(
        from: 1,
        to: 2,
        migrations: ['ALTER TABLE source ADD COLUMN extra TEXT'],
        upsertSource: null,
      );
      // צריך לבנות upsert_source עם העמודה החדשה ידנית
      final pdb = sqlite3.sqlite3.open(patch);
      pdb.execute(
          'CREATE TABLE upsert_source (id INTEGER PRIMARY KEY, name TEXT, extra TEXT)');
      pdb.execute("INSERT INTO upsert_source VALUES (1,'a','X')");
      pdb.close();

      final expected = buildBaseDb(version: 2, sourceRows: []);
      final edb = sqlite3.sqlite3.open(expected);
      edb.execute('ALTER TABLE source ADD COLUMN extra TEXT');
      edb.execute("INSERT INTO source VALUES (1,'a','X')");
      edb.close();

      final manifest = _manifest(
        from: 1,
        to: 2,
        fromHash: _hashOf(base),
        toHash: _hashOf(expected),
      );
      final result =
          _applier.apply(dbPath: base, patchPath: patch, manifest: manifest);
      expect(result.migrations, 1);
      expect(_hashOf(base), manifest.toContentHash);
    });

    test('schema_version חדש מדי → נכשל ולא משנה את ה-DB', () {
      final base = buildBaseDb(version: 1, sourceRows: [
        [1, 'a'],
      ]);
      final beforeHash = _hashOf(base);
      final patch = buildPatchDb(from: 1, to: 2, schemaVersion: 99);
      final manifest =
          _manifest(from: 1, to: 2, fromHash: beforeHash, toHash: 'whatever');

      expect(
        () =>
            _applier.apply(dbPath: base, patchPath: patch, manifest: manifest),
        throwsA(isA<PatchApplyException>()),
      );
      expect(_hashOf(base), beforeHash); // לא השתנה
    });

    test('גרסה מקומית לא תואמת → נכשל לפני כתיבה', () {
      final base = buildBaseDb(version: 5, sourceRows: [
        [1, 'a'],
      ]);
      final beforeHash = _hashOf(base);
      final patch = buildPatchDb(from: 1, to: 2, upsertSource: [
        [2, 'b'],
      ]);
      final manifest = _manifest(
          from: 1, to: 2, fromHash: 'irrelevant', toHash: 'irrelevant');

      expect(
        () =>
            _applier.apply(dbPath: base, patchPath: patch, manifest: manifest),
        throwsA(isA<PatchApplyException>()
            .having((e) => e.isContentMismatch, 'isContentMismatch', isFalse)),
      );
      expect(_hashOf(base), beforeHash);
    });

    test('fromContentHash לא תואם → isContentMismatch וה-DB לא משתנה', () {
      final base = buildBaseDb(version: 1, sourceRows: [
        [1, 'a'],
      ]);
      final beforeHash = _hashOf(base);
      final patch = buildPatchDb(from: 1, to: 2, upsertSource: [
        [2, 'b'],
      ]);
      final manifest =
          _manifest(from: 1, to: 2, fromHash: 'diverged', toHash: 'irrelevant');

      expect(
        () =>
            _applier.apply(dbPath: base, patchPath: patch, manifest: manifest),
        throwsA(isA<PatchApplyException>()
            .having((e) => e.isContentMismatch, 'isContentMismatch', isTrue)
            .having(
              (e) => e.hashMismatchStage,
              'hashMismatchStage',
              PatchHashMismatchStage.fromContentHash,
            )),
      );
      expect(_hashOf(base), beforeHash);
    });

    test('toContentHash שגוי → rollback וה-DB לא משתנה', () {
      final base = buildBaseDb(version: 1, sourceRows: [
        [1, 'a'],
      ]);
      final beforeHash = _hashOf(base);
      final patch = buildPatchDb(from: 1, to: 2, upsertSource: [
        [2, 'b'],
      ]);
      final manifest = _manifest(
        from: 1,
        to: 2,
        fromHash: beforeHash,
        toHash: 'deadbeef', // שגוי בכוונה
      );

      expect(
        () =>
            _applier.apply(dbPath: base, patchPath: patch, manifest: manifest),
        throwsA(isA<PatchApplyException>()
            .having((e) => e.isContentMismatch, 'isContentMismatch', isTrue)
            .having(
              (e) => e.hashMismatchStage,
              'hashMismatchStage',
              PatchHashMismatchStage.toContentHash,
            )),
      );
      expect(_hashOf(base), beforeHash); // rollback שמר על המקור
    });

    test('booksTouched נאסף מ-upserts ומ-deletes של book/line', () {
      final base = buildBaseDb(version: 1, sourceRows: []);
      final bdb = sqlite3.sqlite3.open(base);
      bdb.execute('CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT)');
      bdb.execute(
          'CREATE TABLE line (id INTEGER PRIMARY KEY, bookId INTEGER, content TEXT)');
      bdb.execute("INSERT INTO book VALUES (1,'א'),(2,'ב'),(3,'ג')");
      bdb.execute("INSERT INTO line VALUES (10,1,'x'),(20,2,'y'),(30,3,'z')");
      bdb.close();

      final patch = buildPatchDb(from: 1, to: 2);
      final pdb = sqlite3.sqlite3.open(patch);
      pdb.execute(
          'CREATE TABLE upsert_line (id INTEGER PRIMARY KEY, bookId INTEGER, content TEXT)');
      pdb.execute("INSERT INTO upsert_line VALUES (10,1,'X2')"); // תוכן ספר 1
      pdb.execute('CREATE TABLE delete_line (id INTEGER PRIMARY KEY)');
      pdb.execute('INSERT INTO delete_line VALUES (20)'); // שורה של ספר 2
      pdb.execute(
          'CREATE TABLE upsert_book (id INTEGER PRIMARY KEY, title TEXT)');
      pdb.execute("INSERT INTO upsert_book VALUES (3,'ג-חדש')"); // כותרת ספר 3
      pdb.close();

      final expected = buildBaseDb(version: 2, sourceRows: []);
      final edb = sqlite3.sqlite3.open(expected);
      edb.execute('CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT)');
      edb.execute(
          'CREATE TABLE line (id INTEGER PRIMARY KEY, bookId INTEGER, content TEXT)');
      edb.execute("INSERT INTO book VALUES (1,'א'),(2,'ב'),(3,'ג-חדש')");
      edb.execute("INSERT INTO line VALUES (10,1,'X2'),(30,3,'z')");
      edb.close();

      final manifest = _manifest(
        from: 1,
        to: 2,
        fromHash: _hashOf(base),
        toHash: _hashOf(expected),
      );
      final result =
          _applier.apply(dbPath: base, patchPath: patch, manifest: manifest);
      expect(result.booksTouched, {1, 2, 3});
    });

    test('booksTouched נאסף גם מ-patch חלקי בלי עמודת bookId', () {
      final base = buildBaseDb(version: 1, sourceRows: []);
      final bdb = sqlite3.sqlite3.open(base);
      bdb.execute('CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT)');
      bdb.execute(
          'CREATE TABLE line (id INTEGER PRIMARY KEY, bookId INTEGER, content TEXT)');
      bdb.execute("INSERT INTO book VALUES (1,'א')");
      bdb.execute("INSERT INTO line VALUES (10,1,'x')");
      bdb.close();

      // upsert_line מעדכן רק content — בלי bookId; המיפוי חייב לעבור דרך main
      final patch = buildPatchDb(from: 1, to: 2);
      final pdb = sqlite3.sqlite3.open(patch);
      pdb.execute(
          'CREATE TABLE upsert_line (id INTEGER PRIMARY KEY, content TEXT)');
      pdb.execute("INSERT INTO upsert_line VALUES (10,'X2')");
      pdb.close();

      final expected = buildBaseDb(version: 2, sourceRows: []);
      final edb = sqlite3.sqlite3.open(expected);
      edb.execute('CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT)');
      edb.execute(
          'CREATE TABLE line (id INTEGER PRIMARY KEY, bookId INTEGER, content TEXT)');
      edb.execute("INSERT INTO book VALUES (1,'א')");
      edb.execute("INSERT INTO line VALUES (10,1,'X2')");
      edb.close();

      final manifest = _manifest(
        from: 1,
        to: 2,
        fromHash: _hashOf(base),
        toHash: _hashOf(expected),
      );
      final result =
          _applier.apply(dbPath: base, patchPath: patch, manifest: manifest);
      expect(result.booksTouched, {1});
      // רק line (מכוסה) ו-schema_meta השתנו — אין צורך ברענון מלא
      expect(result.hasChangesOutsideBooksTouched, isFalse);
    });

    test('booksTouched ממפה tocText משותף ו-junction של מטא-דאטה לספרים', () {
      final base = buildBaseDb(version: 1, sourceRows: []);
      final bdb = sqlite3.sqlite3.open(base);
      bdb.execute('CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT)');
      bdb.execute('CREATE TABLE tocText (id INTEGER PRIMARY KEY, text TEXT)');
      bdb.execute('CREATE TABLE tocEntry '
          '(id INTEGER PRIMARY KEY, bookId INTEGER, textId INTEGER)');
      bdb.execute('CREATE TABLE book_author '
          '(bookId INTEGER, authorId INTEGER, PRIMARY KEY (bookId, authorId))');
      bdb.execute("INSERT INTO book VALUES (1,'א'),(2,'ב'),(3,'ג')");
      bdb.execute("INSERT INTO tocText VALUES (100,'פרק')");
      // ספרים 1 ו-2 חולקים את אותו tocText
      bdb.execute('INSERT INTO tocEntry VALUES (7,1,100),(8,2,100)');
      bdb.execute('INSERT INTO book_author VALUES (3,50)');
      bdb.close();

      final patch = buildPatchDb(from: 1, to: 2);
      final pdb = sqlite3.sqlite3.open(patch);
      pdb.execute(
          'CREATE TABLE upsert_tocText (id INTEGER PRIMARY KEY, text TEXT)');
      pdb.execute("INSERT INTO upsert_tocText VALUES (100,'פרק-חדש')");
      pdb.execute('CREATE TABLE delete_book_author '
          '(bookId INTEGER, authorId INTEGER, PRIMARY KEY (bookId, authorId))');
      pdb.execute('INSERT INTO delete_book_author VALUES (3,50)');
      pdb.close();

      final expected = buildBaseDb(version: 2, sourceRows: []);
      final edb = sqlite3.sqlite3.open(expected);
      edb.execute('CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT)');
      edb.execute('CREATE TABLE tocText (id INTEGER PRIMARY KEY, text TEXT)');
      edb.execute('CREATE TABLE tocEntry '
          '(id INTEGER PRIMARY KEY, bookId INTEGER, textId INTEGER)');
      edb.execute('CREATE TABLE book_author '
          '(bookId INTEGER, authorId INTEGER, PRIMARY KEY (bookId, authorId))');
      edb.execute("INSERT INTO book VALUES (1,'א'),(2,'ב'),(3,'ג')");
      edb.execute("INSERT INTO tocText VALUES (100,'פרק-חדש')");
      edb.execute('INSERT INTO tocEntry VALUES (7,1,100),(8,2,100)');
      edb.close();

      final manifest = _manifest(
        from: 1,
        to: 2,
        fromHash: _hashOf(base),
        toHash: _hashOf(expected),
      );
      final result =
          _applier.apply(dbPath: base, patchPath: patch, manifest: manifest);
      // 1+2 דרך ה-tocText המשותף, 3 דרך מחיקת book_author
      expect(result.booksTouched, {1, 2, 3});
    });

    test('booksTouched ריק כשה-patch לא נוגע בטבלאות ספרים', () {
      final base = buildBaseDb(version: 1, sourceRows: [
        [1, 'a'],
      ]);
      final patch = buildPatchDb(from: 1, to: 2, upsertSource: [
        [2, 'b'],
      ]);
      final expected = buildBaseDb(version: 2, sourceRows: [
        [1, 'a'],
        [2, 'b'],
      ]);
      final manifest = _manifest(
        from: 1,
        to: 2,
        fromHash: _hashOf(base),
        toHash: _hashOf(expected),
      );
      final result =
          _applier.apply(dbPath: base, patchPath: patch, manifest: manifest);
      expect(result.booksTouched, isEmpty);
      // source אינה מכוסה ב-booksTouched — הצרכן צריך trigger לרענון מלא
      expect(result.hasChangesOutsideBooksTouched, isTrue);
    });

    test('verifyFromHash מזהה DB מקומי ששונה', () {
      final base = buildBaseDb(version: 1, sourceRows: [
        [1, 'a'],
      ]);
      final patch = buildPatchDb(from: 1, to: 2, upsertSource: [
        [2, 'b'],
      ]);
      final manifest = _manifest(
        from: 1,
        to: 2,
        fromHash: 'not-the-real-hash',
        toHash: 'whatever',
      );
      expect(
        () =>
            _applier.apply(dbPath: base, patchPath: patch, manifest: manifest),
        throwsA(isA<PatchApplyException>()),
      );
    });

    test('toSchemaVersion לא מוכר + verifyFromHash=false → זריקה לפני כל כתיבה',
        () {
      final base = buildBaseDb(version: 1, sourceRows: [
        [1, 'a'],
      ]);
      final patch = buildPatchDb(from: 1, to: 2, upsertSource: [
        [2, 'b'],
      ]);
      final bytesBefore = File(base).readAsBytesSync();
      final manifest = _manifest(
        from: 1,
        to: 2,
        fromHash: 'irrelevant',
        toHash: 'irrelevant',
        toSchema: 99,
      );
      expect(
        () => _applier.apply(
          dbPath: base,
          patchPath: patch,
          manifest: manifest,
          verifyFromHash: false,
        ),
        throwsA(isA<PatchApplyException>()),
      );
      // ה-preflight רץ לפני פתיחת ה-DB — הקובץ זהה בתים למצב ההתחלתי
      expect(File(base).readAsBytesSync(), bytesBefore);
    });

    test(
        'fromSchemaVersion לא מוכר + verifyFromHash=false → זריקה לפני כל כתיבה',
        () {
      final base = buildBaseDb(version: 1, sourceRows: [
        [1, 'a'],
      ]);
      final patch = buildPatchDb(from: 1, to: 2, upsertSource: [
        [2, 'b'],
      ]);
      final bytesBefore = File(base).readAsBytesSync();
      final manifest = _manifest(
        from: 1,
        to: 2,
        fromHash: 'irrelevant',
        toHash: 'irrelevant',
        fromSchema: 0,
      );
      expect(
        () => _applier.apply(
          dbPath: base,
          patchPath: patch,
          manifest: manifest,
          verifyFromHash: false,
        ),
        throwsA(isA<PatchApplyException>()),
      );
      expect(File(base).readAsBytesSync(), bytesBefore);
    });
  });

  group('שדרוג סכמה 2→3 (link_suppressed_side)', () {
    // המסלול האמיתי של שלב 2: ה-DB המקומי בסכמה 2, ה-patch מביא CREATE TABLE
    // כמיגרציה ומאכלס אותה. ה-from-hash חייב להיחשב בסדר סכמה-2 וה-to-hash
    // בסדר סכמה-3, אחרת ה-apply נדחה על DB תקין לחלוטין.
    String buildSchema3Db({
      required int version,
      required List<List> rows,
      int reasonMask = 4,
      String name = 'expected',
    }) {
      final path = '${tmp.path}/${name}_s3_$version.db';
      final db = sqlite3.sqlite3.open(path);
      db.execute('CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT)');
      db.execute("INSERT INTO schema_meta VALUES ('db_version','$version'),"
          "('db_schema_version','3')");
      db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)');
      for (final r in rows) {
        db.execute('INSERT INTO source VALUES (?,?)', [r[0], r[1]]);
      }
      db.execute('CREATE TABLE link_suppressed_side (linkId INTEGER NOT NULL, '
          'side INTEGER NOT NULL, reasonMask INTEGER NOT NULL, '
          'PRIMARY KEY (linkId, side))');
      db.execute(
        'INSERT INTO link_suppressed_side VALUES (7,0,?)',
        [reasonMask],
      );
      db.close();
      return path;
    }

    test('CREATE TABLE + אכלוס, ושתי גרסאות ה-hash נבחרות נכון', () {
      final base = buildBaseDb(version: 1, sourceRows: [
        [1, 'aleph'],
      ]);
      final patch = buildPatchDb(
        from: 1,
        to: 2,
        migrations: [
          'CREATE TABLE link_suppressed_side (linkId INTEGER NOT NULL, '
              'side INTEGER NOT NULL, reasonMask INTEGER NOT NULL, '
              'PRIMARY KEY (linkId, side))',
        ],
      );
      final pdb = sqlite3.sqlite3.open(patch);
      pdb.execute('CREATE TABLE upsert_link_suppressed_side (linkId INTEGER, '
          'side INTEGER, reasonMask INTEGER, PRIMARY KEY (linkId, side))');
      pdb.execute('INSERT INTO upsert_link_suppressed_side VALUES (7,0,4)');
      pdb.execute(
        "UPDATE upsert_schema_meta SET value='2' WHERE key='db_version'",
      );
      pdb.execute(
        "INSERT INTO upsert_schema_meta VALUES ('db_schema_version','3')",
      );
      pdb.close();

      final expected = buildSchema3Db(version: 2, rows: [
        [1, 'aleph'],
      ]);

      final manifest = _manifest(
        from: 1,
        to: 2,
        fromSchema: 2,
        toSchema: 3,
        // ה-from נמדד בסדר סכמה-2, ה-to בסדר סכמה-3 — כמו שהאפליר עושה.
        fromHash: _hashOf(base),
        toHash: _hashWithOrder(expected, kHashTableOrderSchema3),
      );

      final result = _applier.apply(
        dbPath: base,
        patchPath: patch,
        manifest: manifest,
      );

      expect(result.resultHash, manifest.toContentHash);
      final db = sqlite3.sqlite3.open(base, mode: sqlite3.OpenMode.readOnly);
      expect(
        db
            .select('SELECT linkId, side, reasonMask FROM link_suppressed_side')
            .map((r) => r.values.toList()),
        [
          [7, 0, 4]
        ],
      );
      expect(
        db
            .select(
                "SELECT value FROM schema_meta WHERE key='db_schema_version'")
            .first
            .values
            .first,
        '3',
      );
      db.close();
    });

    test('סכמה 3→3 מעדכנת reasonMask על מפתח קיים', () {
      final base = buildSchema3Db(
        version: 2,
        rows: [
          [1, 'aleph'],
        ],
        name: 'base',
      );
      final patch = buildPatchDb(from: 2, to: 3, schemaVersion: 3);
      final pdb = sqlite3.sqlite3.open(patch);
      pdb.execute(
        'CREATE TABLE upsert_link_suppressed_side (linkId INTEGER, '
        'side INTEGER, reasonMask INTEGER, PRIMARY KEY (linkId, side))',
      );
      pdb.execute('INSERT INTO upsert_link_suppressed_side VALUES (7,0,5)');
      pdb.close();

      final expected = buildSchema3Db(
        version: 3,
        rows: [
          [1, 'aleph'],
        ],
        reasonMask: 5,
      );
      final manifest = _manifest(
        from: 2,
        to: 3,
        fromSchema: 3,
        toSchema: 3,
        fromHash: _hashWithOrder(base, kHashTableOrderSchema3),
        toHash: _hashWithOrder(expected, kHashTableOrderSchema3),
      );

      final result = _applier.apply(
        dbPath: base,
        patchPath: patch,
        manifest: manifest,
      );

      expect(result.resultHash, manifest.toContentHash);
      final db = sqlite3.sqlite3.open(base, mode: sqlite3.OpenMode.readOnly);
      expect(
        db
            .select(
              'SELECT reasonMask FROM link_suppressed_side '
              'WHERE linkId=7 AND side=0',
            )
            .single
            .values
            .single,
        5,
      );
      db.close();
    });

    test('לקוח ישן דוחה patch של סכמה 3 לפני שהוא נוגע ב-DB', () {
      // supportedSchemaVersion=2 מדמה גרסת אפליקציה שלא עודכנה.
      const oldClient = PatchApplier(supportedSchemaVersion: 2);
      final base = buildBaseDb(version: 1, sourceRows: [
        [1, 'aleph'],
      ]);
      final before = _hashOf(base);
      final patch = buildPatchDb(from: 1, to: 2, schemaVersion: 3);
      final manifest = _manifest(
        from: 1,
        to: 2,
        fromHash: before,
        toHash: before,
      );

      expect(
        () =>
            oldClient.apply(dbPath: base, patchPath: patch, manifest: manifest),
        throwsA(isA<PatchApplyException>()),
      );
      // fail-closed: ה-DB לא נגוע.
      expect(_hashOf(base), before);
    });
  });

  group('שדרוג סכמה 3→4 (line_ref + line_dh)', () {
    // המסלול האמיתי של שדרוג הסכמה: ה-DB המקומי בסכמה 3, ה-patch מביא
    // CREATE TABLE כמיגרציה ומאכלס אותה. ה-from-hash נחשב בסדר סכמה-3
    // וה-to-hash בסדר סכמה-4, אחרת ה-apply נדחה על DB תקין לחלוטין.
    String buildSchema3Db({
      required int version,
      required List<List> rows,
      String name = 'expected',
    }) {
      final path = '${tmp.path}/${name}_s3_$version.db';
      final db = sqlite3.sqlite3.open(path);
      db.execute('CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT)');
      db.execute("INSERT INTO schema_meta VALUES ('db_version','$version'),"
          "('db_schema_version','3')");
      db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)');
      for (final r in rows) {
        db.execute('INSERT INTO source VALUES (?,?)', [r[0], r[1]]);
      }
      db.close();
      return path;
    }

    String buildSchema4Db({
      required int version,
      required List<List> rows,
      required List<List> lineRefRows,
      String name = 'expected',
    }) {
      final path = '${tmp.path}/${name}_s4_$version.db';
      final db = sqlite3.sqlite3.open(path);
      db.execute('CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT)');
      db.execute("INSERT INTO schema_meta VALUES ('db_version','$version'),"
          "('db_schema_version','4')");
      db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)');
      for (final r in rows) {
        db.execute('INSERT INTO source VALUES (?,?)', [r[0], r[1]]);
      }
      db.execute('CREATE TABLE line_ref (bookId INTEGER NOT NULL, '
          'refKeyHash INTEGER NOT NULL, lineIndex INTEGER NOT NULL, '
          'PRIMARY KEY (bookId, refKeyHash, lineIndex)) WITHOUT ROWID');
      for (final r in lineRefRows) {
        db.execute('INSERT INTO line_ref VALUES (?,?,?)', [r[0], r[1], r[2]]);
      }
      db.execute('CREATE TABLE line_dh (bookId INTEGER NOT NULL, '
          'dhText TEXT NOT NULL, lineIndex INTEGER NOT NULL, '
          'PRIMARY KEY (bookId, dhText, lineIndex)) WITHOUT ROWID');
      db.execute("INSERT INTO line_dh VALUES (12,'מאימתי קורין',3),"
          "(12,'עד סוף האשמורה',4)");
      db.close();
      return path;
    }

    test('CREATE TABLE + אכלוס, ושתי גרסאות ה-hash נבחרות נכון', () {
      final base = buildSchema3Db(version: 3, rows: [
        [1, 'aleph'],
      ], name: 'base');
      final patch = buildPatchDb(
        from: 3,
        to: 4,
        schemaVersion: 4,
        migrations: [
          'CREATE TABLE line_ref (bookId INTEGER NOT NULL, '
              'refKeyHash INTEGER NOT NULL, lineIndex INTEGER NOT NULL, '
              'PRIMARY KEY (bookId, refKeyHash, lineIndex)) WITHOUT ROWID',
          'CREATE TABLE line_dh (bookId INTEGER NOT NULL, '
              'dhText TEXT NOT NULL, lineIndex INTEGER NOT NULL, '
              'PRIMARY KEY (bookId, dhText, lineIndex)) WITHOUT ROWID',
        ],
      );
      final pdb = sqlite3.sqlite3.open(patch);
      pdb.execute('CREATE TABLE upsert_line_ref (bookId INTEGER, '
          'refKeyHash INTEGER, lineIndex INTEGER, '
          'PRIMARY KEY (bookId, refKeyHash, lineIndex))');
      pdb.execute('INSERT INTO upsert_line_ref VALUES (12,777,3),(12,778,4)');
      pdb.execute('CREATE TABLE upsert_line_dh (bookId INTEGER, '
          'dhText TEXT, lineIndex INTEGER, '
          'PRIMARY KEY (bookId, dhText, lineIndex))');
      pdb.execute("INSERT INTO upsert_line_dh VALUES (12,'מאימתי קורין',3),"
          "(12,'עד סוף האשמורה',4)");
      pdb.execute(
        "UPDATE upsert_schema_meta SET value='4' WHERE key='db_version'",
      );
      pdb.execute(
        "INSERT INTO upsert_schema_meta VALUES ('db_schema_version','4')",
      );
      pdb.close();

      final expected = buildSchema4Db(version: 4, rows: [
        [1, 'aleph'],
      ], lineRefRows: [
        [12, 777, 3],
        [12, 778, 4],
      ]);

      final manifest = _manifest(
        from: 3,
        to: 4,
        fromSchema: 3,
        toSchema: 4,
        fromHash: _hashWithOrder(base, kHashTableOrderSchema3),
        toHash: _hashWithOrder(expected, kHashTableOrder),
      );

      final result = _applier.apply(
        dbPath: base,
        patchPath: patch,
        manifest: manifest,
      );

      expect(result.resultHash, manifest.toContentHash);
      // line_ref/line_dh הם אינדקסים נגזרים — לא שינוי שדורש רענון אינדקס חיפוש.
      expect(result.booksTouched, isEmpty);
      expect(result.hasChangesOutsideBooksTouched, isFalse);
      final db = sqlite3.sqlite3.open(base, mode: sqlite3.OpenMode.readOnly);
      expect(
        db
            .select('SELECT bookId, refKeyHash, lineIndex FROM line_ref '
                'ORDER BY refKeyHash')
            .map((r) => r.values.toList()),
        [
          [12, 777, 3],
          [12, 778, 4],
        ],
      );
      expect(
        db
            .select('SELECT dhText FROM line_dh ORDER BY lineIndex')
            .map((r) => r.values.first),
        ['מאימתי קורין', 'עד סוף האשמורה'],
      );
      expect(
        db
            .select(
                "SELECT value FROM schema_meta WHERE key='db_schema_version'")
            .first
            .values
            .first,
        '4',
      );
      db.close();
    });

    test('לקוח בסכמה-3 דוחה patch של סכמה 4 לפני שהוא נוגע ב-DB', () {
      // supportedSchemaVersion=3 מדמה גרסת אפליקציה שלא עודכנה.
      const oldClient = PatchApplier(supportedSchemaVersion: 3);
      final base = buildSchema3Db(version: 3, rows: [
        [1, 'aleph'],
      ], name: 'base');
      final before = _hashWithOrder(base, kHashTableOrderSchema3);
      final patch = buildPatchDb(from: 3, to: 4, schemaVersion: 4);
      final manifest = _manifest(
        from: 3,
        to: 4,
        fromSchema: 3,
        toSchema: 3,
        fromHash: before,
        toHash: before,
      );

      expect(
        () =>
            oldClient.apply(dbPath: base, patchPath: patch, manifest: manifest),
        throwsA(isA<PatchApplyException>()),
      );
      // fail-closed: ה-DB לא נגוע.
      expect(_hashWithOrder(base, kHashTableOrderSchema3), before);
    });
  });

  group('hashTableOrderForSchemaVersion', () {
    test('סכמה-1 → סדר 33 הישן (ללא book_base_text)', () {
      expect(hashTableOrderForSchemaVersion(1), same(kHashTableOrderSchema1));
      expect(kHashTableOrderSchema1.length, 33);
      expect(kHashTableOrderSchema1, isNot(contains('book_base_text')));
    });
    test('סכמה-2 → סדר 34 הקפוא (כולל book_base_text)', () {
      expect(hashTableOrderForSchemaVersion(2), same(kHashTableOrderSchema2));
      expect(kHashTableOrderSchema2.length, 34);
      expect(kHashTableOrderSchema2, contains('book_base_text'));
      expect(kHashTableOrderSchema2, isNot(contains('link_suppressed_side')));
    });
    test('סכמה-3 → סדר 35 הקפוא (כולל link_suppressed_side, ללא line_ref)', () {
      expect(hashTableOrderForSchemaVersion(3), same(kHashTableOrderSchema3));
      expect(kHashTableOrderSchema3.length, 35);
      expect(kHashTableOrderSchema3, contains('link_suppressed_side'));
      expect(kHashTableOrderSchema3, isNot(contains('line_ref')));
      expect(kHashTableOrderSchema3, isNot(contains('line_dh')));
      // מיד אחרי link_coverage — אותו מיקום כמו בצד הקוטליני.
      expect(kHashTableOrderSchema3.indexOf('link_suppressed_side'),
          kHashTableOrderSchema3.indexOf('link_coverage') + 1);
    });
    test('סכמה-4 → סדר 37 הנוכחי (כולל line_ref + line_dh)', () {
      expect(hashTableOrderForSchemaVersion(4), same(kHashTableOrder));
      expect(kHashTableOrder.length, 37);
      // מיד אחרי line_toc — אותו מיקום כמו בצד הקוטליני.
      expect(kHashTableOrder.indexOf('line_ref'),
          kHashTableOrder.indexOf('line_toc') + 1);
      expect(kHashTableOrder.indexOf('line_dh'),
          kHashTableOrder.indexOf('line_ref') + 1);
    });
    test('גרסת סכמה לא מוכרת → זורק PatchApplyException', () {
      expect(() => hashTableOrderForSchemaVersion(0),
          throwsA(isA<PatchApplyException>()));
      expect(() => hashTableOrderForSchemaVersion(5),
          throwsA(isA<PatchApplyException>()));
    });
  });

  // אימות מול הקבצים האמיתיים — ה-acceptance criteria 1+2.
  group('PatchApplier against real DBs', () {
    final dir =
        Platform.environment['SEFORIM_LIBRARY_RELEASES_DIR'] ?? '/nonexistent';

    String? cloneDb(String src) {
      if (!File(src).existsSync()) return null;
      final dst = '${tmp.path}/seforim.db';
      // cp -c = clonefile על APFS (מיידי, ללא מקום נוסף)
      final r = Process.runSync('cp', ['-c', src, dst]);
      if (r.exitCode != 0) {
        Process.runSync('cp', [src, dst]); // fallback ל-copy רגיל
      }
      return dst;
    }

    // manifest של סכמה-1 (from/to schema=1) → סדר ה-hash הישן (33) →
    // ה-hashes ההיסטוריים תואמים שוב, ודלתאות סכמה-1 נשארות קבילות.
    test('apply v14→v15 (סכמה-1) מצליח ומגיע ל-db_version=15 ול-toContentHash',
        () {
      final dbPath = cloneDb('$dir/v14/seforim.db');
      final patchPath = '$dir/v15/patch-v14-v15.db';
      if (dbPath == null || !File(patchPath).existsSync()) {
        markTestSkipped('קבצי v14/v15 לא זמינים');
        return;
      }
      final manifest = _manifest(
        from: 14,
        to: 15,
        fromSchema: 1,
        toSchema: 1,
        fromHash:
            '153ba2e803e5334e8e0bcaaf681d7853f14085f482ca87e70dcdd9f861f01319',
        toHash:
            '5ed1d2a7b01606c77996ec26fcccaf9d173f346b1c0ec64280b915185fbfc81d',
      );
      final result = _applier.apply(
          dbPath: dbPath, patchPath: patchPath, manifest: manifest);
      expect(result.resultHash, manifest.toContentHash);

      final db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
      final version = db
          .select("SELECT value FROM schema_meta WHERE key='db_version'")
          .first['value'];
      db.close();
      expect(version, '15');
    }, timeout: const Timeout(Duration(minutes: 10)));

    // דרישת הסוקר: verifyFromHash=false גם הוא מגיע ל-toContentHash.
    test('apply v14→v15 (סכמה-1) עם verifyFromHash=false מצליח', () {
      final dbPath = cloneDb('$dir/v14/seforim.db');
      final patchPath = '$dir/v15/patch-v14-v15.db';
      if (dbPath == null || !File(patchPath).existsSync()) {
        markTestSkipped('קבצי v14/v15 לא זמינים');
        return;
      }
      final manifest = _manifest(
        from: 14,
        to: 15,
        fromSchema: 1,
        toSchema: 1,
        fromHash:
            '153ba2e803e5334e8e0bcaaf681d7853f14085f482ca87e70dcdd9f861f01319',
        toHash:
            '5ed1d2a7b01606c77996ec26fcccaf9d173f346b1c0ec64280b915185fbfc81d',
      );
      final result = _applier.apply(
        dbPath: dbPath,
        patchPath: patchPath,
        manifest: manifest,
        verifyFromHash: false,
      );
      expect(result.resultHash, manifest.toContentHash);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('apply v14→v15r (patch חלופי, סכמה-1) מצליח ומגיע ל-toContentHash',
        () {
      final dbPath = cloneDb('$dir/v14/seforim.db');
      final patchPath = '$dir/v15/patch-v14-v15r.db';
      if (dbPath == null || !File(patchPath).existsSync()) {
        markTestSkipped('קבצי v14/v15r לא זמינים');
        return;
      }
      final manifest = _manifest(
        from: 14,
        to: 15,
        fromSchema: 1,
        toSchema: 1,
        fromHash:
            '153ba2e803e5334e8e0bcaaf681d7853f14085f482ca87e70dcdd9f861f01319',
        toHash:
            '623302b075bceb4dc823131e0e37c2ebba781f1c0215c1dddcc8b1825727ea7f',
      );
      final result = _applier.apply(
          dbPath: dbPath, patchPath: patchPath, manifest: manifest);
      expect(result.resultHash, manifest.toContentHash);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('patch על גרסה שגויה (v14→v15 על DB v15) נכשל לפני כתיבה', () {
      final dbPath = cloneDb('$dir/v15/seforim.db');
      final patchPath = '$dir/v15/patch-v14-v15.db';
      if (dbPath == null || !File(patchPath).existsSync()) {
        markTestSkipped('קבצים לא זמינים');
        return;
      }
      final manifest = _manifest(
        from: 14,
        to: 15,
        fromHash:
            '153ba2e803e5334e8e0bcaaf681d7853f14085f482ca87e70dcdd9f861f01319',
        toHash:
            '5ed1d2a7b01606c77996ec26fcccaf9d173f346b1c0ec64280b915185fbfc81d',
      );
      // נכשל מיד על version mismatch (local=15, manifest.from=14) — לפני hash יקר
      expect(
        () => _applier.apply(
            dbPath: dbPath, patchPath: patchPath, manifest: manifest),
        throwsA(isA<PatchApplyException>()),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
