import 'dart:io';

import 'package:test/test.dart';
import 'package:seforim_library_updater/src/models/delta_manifest.dart';
import 'package:seforim_library_updater/src/services/logical_content_hasher.dart';
import 'package:seforim_library_updater/src/services/patch_applier.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

const _hasher = LogicalContentHasher();
const _applier = PatchApplier();

String _hashOf(String dbPath) {
  final db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
  try {
    return _hasher.compute(db);
  } finally {
    db.close();
  }
}

/// בונה manifest סינתטי. ה-hashes מחושבים מהקבצים בפועל אחרי בנייתם.
DeltaManifest _manifest({
  required int from,
  required int to,
  required String fromHash,
  required String toHash,
}) =>
    DeltaManifest(
      fromVersion: from,
      toVersion: to,
      fromSchemaVersion: 1,
      toSchemaVersion: 1,
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
        "('db_schema_version','1')");
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
        throwsA(isA<PatchApplyException>()),
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
        throwsA(isA<PatchApplyException>()),
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

    test('apply v1→v2 מצליח ומגיע ל-db_version=2 ול-toContentHash', () {
      final dbPath = cloneDb('$dir/v1/seforim.db');
      final patchPath = '$dir/v2/patch-v1-v2.db';
      if (dbPath == null || !File(patchPath).existsSync()) {
        markTestSkipped('קבצי v1/v2 לא זמינים');
        return;
      }
      final manifest = _manifest(
        from: 1,
        to: 2,
        fromHash:
            '35d499985cc1c37fd02904682d4f67a8c915625ef3768c0e856d3f79a4fc96c1',
        toHash:
            '2be5318d73e4ffa6b32c5d265699e6000cd84f776c304db4a9b192e7d67b3d06',
      );
      final result = _applier.apply(
          dbPath: dbPath, patchPath: patchPath, manifest: manifest);
      expect(result.resultHash, manifest.toContentHash);

      final db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
      final version = db
          .select("SELECT value FROM schema_meta WHERE key='db_version'")
          .first['value'];
      db.close();
      expect(version, '2');
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('apply v2→v3 מצליח ומגיע ל-toContentHash', () {
      final dbPath = cloneDb('$dir/v2/seforim.db');
      final patchPath = '$dir/v3/patch-v2-v3.db';
      if (dbPath == null || !File(patchPath).existsSync()) {
        markTestSkipped('קבצי v2/v3 לא זמינים');
        return;
      }
      final manifest = _manifest(
        from: 2,
        to: 3,
        fromHash:
            '2be5318d73e4ffa6b32c5d265699e6000cd84f776c304db4a9b192e7d67b3d06',
        toHash:
            'adb131e748347b1b1f0d3407ee99cddae6d6d18e0a40078176b17cd68d6ff9cf',
      );
      final result = _applier.apply(
          dbPath: dbPath, patchPath: patchPath, manifest: manifest);
      expect(result.resultHash, manifest.toContentHash);
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('patch על גרסה שגויה (v2→v3 על DB v1) נכשל לפני כתיבה', () {
      final dbPath = cloneDb('$dir/v1/seforim.db');
      final patchPath = '$dir/v3/patch-v2-v3.db';
      if (dbPath == null || !File(patchPath).existsSync()) {
        markTestSkipped('קבצים לא זמינים');
        return;
      }
      final manifest = _manifest(
        from: 2,
        to: 3,
        fromHash:
            '2be5318d73e4ffa6b32c5d265699e6000cd84f776c304db4a9b192e7d67b3d06',
        toHash:
            'adb131e748347b1b1f0d3407ee99cddae6d6d18e0a40078176b17cd68d6ff9cf',
      );
      // נכשל מיד על version mismatch (local=1, manifest.from=2) — לפני hash יקר
      expect(
        () => _applier.apply(
            dbPath: dbPath, patchPath: patchPath, manifest: manifest),
        throwsA(isA<PatchApplyException>()),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
