import 'dart:io';

import 'package:seforim_library_updater/src/messages/library_updater_messages.dart';
import 'package:seforim_library_updater/src/models/delta_manifest.dart';
import 'package:seforim_library_updater/src/models/patch_table_spec.dart';
import 'package:seforim_library_updater/src/services/logical_content_hasher.dart';
import 'package:seforim_library_updater/src/services/patch_applier.dart';
import 'package:seforim_library_updater/src/sqlite/sqlite3_api.dart' as sqlite3;
import 'package:test/test.dart';

const _hasher = LogicalContentHasher();
const _applier = PatchApplier();

/// ברירת המחדל היא סדר סכמה-2, ולא ברירת המחדל של ה-hasher (סכמה 4/5):
/// רוב ה-manifests כאן מצהירים סכמה 2, וה-applier בוחר את הסדר לפיה.
String _hashOf(
  String dbPath, {
  List<String> tableOrder = kHashTableOrderSchema2,
}) {
  final db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
  try {
    return _hasher.compute(db, tableOrder: tableOrder);
  } finally {
    db.close();
  }
}

/// בונה manifest סינתטי. ה-hashes מחושבים מהקבצים בפועל אחרי בנייתם.
/// [fromSchema]/[toSchema] ברירת מחדל 2 → סדר ה-hash של סכמה-2 (34), תואם
/// לברירת המחדל של [_hashOf]. בדיקות v14/v15 מעבירות 1.
DeltaManifest _manifest({
  required int from,
  required int to,
  required String fromHash,
  required String toHash,
  int fromSchema = 2,
  int toSchema = 2,
  int? patchFormat,
}) =>
    DeltaManifest(
      fromVersion: from,
      toVersion: to,
      fromSchemaVersion: fromSchema,
      toSchemaVersion: toSchema,
      patchFormatVersion: patchFormat,
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

/// הודעת ההתנגשות בלי פרטי ה-SQLite שבסוגריים — הם אינם קבועים.
String _uniqueConflictPrefix(String table) => LibraryUpdaterMessages.current
    .patchUniqueConflictNeedsFullDownload(table, '')
    .replaceFirst('()', '')
    .trimRight();

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
    db.execute('INSERT INTO patch_meta VALUES '
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
    // issue #19: `tocText.text` (וגם author.name, source.name...) נושאת UNIQUE
    // מעל ה-PK, ו-ON CONFLICT מכוון ל-PK בלבד — ערך שעבר בין id-ים מתפוצץ
    // כי ה-upserts רצים לפני ה-deletes. המשתמש קיבל SqliteException גולמי.
    test('התנגשות UNIQUE משני → הודעה מובנת, rollback, וה-DB לא משתנה', () {
      final base = '${tmp.path}/unique_base.db';
      final bdb = sqlite3.sqlite3.open(base);
      bdb.execute(
          'CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT)');
      bdb.execute("INSERT INTO schema_meta VALUES ('db_version','1'),"
          "('db_schema_version','2')");
      // כמו בסכימה האמיתית: UNIQUE על עמודת התוכן, לא רק על ה-PK.
      bdb.execute(
          'CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)');
      bdb.execute("INSERT INTO source VALUES (1,'א'),(2,'ב')");
      bdb.close();
      final beforeHash = _hashOf(base);

      // 'א' עובר מ-id 1 ל-id 2 — השורה הישנה תימחק, אבל רק בשלב ה-deletes.
      final patch = buildPatchDb(
        from: 1,
        to: 2,
        upsertSource: [
          [2, 'א'],
        ],
        deleteSource: [1],
      );
      final manifest =
          _manifest(from: 1, to: 2, fromHash: beforeHash, toHash: 'irrelevant');

      expect(
        () => _applier.apply(
          dbPath: base,
          patchPath: patch,
          manifest: manifest,
          // בדיוק כמו בייצור (`_applyPatchInIsolate`).
          verifyFromHash: false,
          checkForeignKeys: false,
        ),
        throwsA(
          isA<PatchApplyException>().having(
            (e) => e.message,
            'message',
            allOf(
              // ההודעה שלנו, עם שם הטבלה...
              startsWith(_uniqueConflictPrefix('source')),
              // ...ופרטי ה-SQLite המקוריים נשמרים בסוף, לדיאגנוסטיקה.
              contains('UNIQUE constraint failed'),
            ),
          ),
        ),
      );
      expect(_hashOf(base), beforeHash); // rollback שמר על המקור
    });

    test('patch_meta ללא schema_version → זריקה בהודעת ה-l10n', () {
      final base = buildBaseDb(version: 1, sourceRows: []);
      final beforeHash = _hashOf(base);
      final patch = buildPatchDb(from: 1, to: 2);
      final pdb = sqlite3.sqlite3.open(patch);
      pdb.execute("DELETE FROM patch_meta WHERE key='schema_version'");
      pdb.close();

      expect(
        () => _applier.apply(
          dbPath: base,
          patchPath: patch,
          manifest:
              _manifest(from: 1, to: 2, fromHash: beforeHash, toHash: 'x'),
        ),
        throwsA(isA<PatchApplyException>().having(
          (e) => e.message,
          'message',
          LibraryUpdaterMessages.current.patchMetaSchemaVersionMissing,
        )),
      );
      expect(_hashOf(base), beforeHash);
    });

    // ה-patch שהורד חייב להיות בדיוק זה שה-manifest מתאר — קובץ שהוחלף
    // (אותו שם, טווח אחר) נעצר כאן ולא מגיע לכתיבה.
    test('טווח הגרסאות ב-patch_meta שונה מה-manifest → זריקה', () {
      final base = buildBaseDb(version: 1, sourceRows: []);
      final beforeHash = _hashOf(base);
      final patch = buildPatchDb(from: 1, to: 3); // ה-manifest אומר 1→2
      expect(
        () => _applier.apply(
          dbPath: base,
          patchPath: patch,
          manifest:
              _manifest(from: 1, to: 2, fromHash: beforeHash, toHash: 'x'),
        ),
        throwsA(isA<PatchApplyException>().having(
          (e) => e.message,
          'message',
          LibraryUpdaterMessages.current.patchVersionRangeMismatch(1, 3, 1, 2),
        )),
      );
      expect(_hashOf(base), beforeHash);
    });

    test('db_schema_version מקומי שונה מ-fromSchemaVersion → זריקה', () {
      final base = buildBaseDb(version: 1, sourceRows: []);
      final bdb = sqlite3.sqlite3.open(base);
      bdb.execute("UPDATE schema_meta SET value='1' "
          "WHERE key='db_schema_version'");
      bdb.close();
      final patch = buildPatchDb(from: 1, to: 2);
      expect(
        () => _applier.apply(
          dbPath: base,
          patchPath: patch,
          manifest: _manifest(from: 1, to: 2, fromHash: 'x', toHash: 'y'),
          verifyFromHash: false,
        ),
        throwsA(isA<PatchApplyException>().having(
          (e) => e.message,
          'message',
          LibraryUpdaterMessages.current.localSchemaMismatch(1, 2),
        )),
      );
    });

    test('שלבי ה-onStage מדווחים בסדר המתועד', () {
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
      final stages = <String>[];
      _applier.apply(
        dbPath: base,
        patchPath: patch,
        manifest: manifest,
        onStage: stages.add,
      );
      expect(stages, [
        'preflight',
        'verifyFromHash',
        'attach',
        'migrations',
        'upserts',
        'deletes',
        'foreignKeyCheck',
        'verifyToHash',
        'commit',
      ]);
    });

    // ה-hint הוא סך-הבתים מריצה קודמת; בלעדיו ה-total הוא גודל הקובץ (הערכת
    // יתר). בשני המסלולים זה רק מד התקדמות, אך חייב להיות עקבי.
    test('verifyTotalBytesHint נכנס כ-total ל-onVerifyProgress', () {
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
      final reports = <(int, int)>[];
      _applier.apply(
        dbPath: base,
        patchPath: patch,
        manifest: manifest,
        verifyTotalBytesHint: 4242,
        onVerifyProgress: (hashed, total) => reports.add((hashed, total)),
      );
      expect(reports, isNotEmpty);
      expect(reports.every((r) => r.$2 == 4242), isTrue);
      expect(reports.every((r) => r.$1 > 0), isTrue);
    });

    test('מחיקה לפי מפתח מורכב (book_author) מוחקת רק את השורה שצוינה', () {
      final base = buildBaseDb(version: 1, sourceRows: []);
      final bdb = sqlite3.sqlite3.open(base);
      bdb.execute('CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT)');
      bdb.execute('CREATE TABLE book_author (bookId INTEGER, authorId INTEGER, '
          'PRIMARY KEY (bookId, authorId))');
      bdb.execute("INSERT INTO book VALUES (1,'א')");
      bdb.execute('INSERT INTO book_author VALUES (1,5),(1,6)');
      bdb.close();

      final patch = buildPatchDb(from: 1, to: 2);
      final pdb = sqlite3.sqlite3.open(patch);
      pdb.execute('CREATE TABLE delete_book_author (bookId INTEGER, '
          'authorId INTEGER, PRIMARY KEY (bookId, authorId))');
      pdb.execute('INSERT INTO delete_book_author VALUES (1,5)');
      pdb.close();

      final expected = buildBaseDb(version: 2, sourceRows: []);
      final edb = sqlite3.sqlite3.open(expected);
      edb.execute('CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT)');
      edb.execute('CREATE TABLE book_author (bookId INTEGER, authorId INTEGER, '
          'PRIMARY KEY (bookId, authorId))');
      edb.execute("INSERT INTO book VALUES (1,'א')");
      edb.execute('INSERT INTO book_author VALUES (1,6)');
      edb.close();

      final result = _applier.apply(
        dbPath: base,
        patchPath: patch,
        manifest: _manifest(
          from: 1,
          to: 2,
          fromHash: _hashOf(base),
          toHash: _hashOf(expected),
        ),
      );
      expect(result.deletes['book_author'], 1);
      expect(result.booksTouched, {1});
    });

    test('הפרת FK שנוצרה ב-patch → זריקה ו-rollback', () {
      final base = buildBaseDb(version: 1, sourceRows: []);
      final bdb = sqlite3.sqlite3.open(base);
      bdb.execute('CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT)');
      bdb.execute(
          'CREATE TABLE book_author (bookId INTEGER REFERENCES book(id),'
          ' authorId INTEGER, PRIMARY KEY (bookId, authorId))');
      bdb.execute("INSERT INTO book VALUES (1,'א')");
      bdb.close();
      final beforeHash = _hashOf(base);

      final patch = buildPatchDb(from: 1, to: 2);
      final pdb = sqlite3.sqlite3.open(patch);
      pdb.execute('CREATE TABLE upsert_book_author (bookId INTEGER, '
          'authorId INTEGER, PRIMARY KEY (bookId, authorId))');
      // ספר 99 אינו קיים — ההפרה מתגלה רק ב-foreign_key_check שאחרי ה-upserts.
      pdb.execute('INSERT INTO upsert_book_author VALUES (99,5)');
      pdb.close();

      expect(
        () => _applier.apply(
          dbPath: base,
          patchPath: patch,
          manifest: _manifest(
            from: 1,
            to: 2,
            fromHash: beforeHash,
            toHash: 'irrelevant',
          ),
        ),
        throwsA(isA<PatchApplyException>().having(
          (e) => e.message,
          'message',
          LibraryUpdaterMessages.current.foreignKeyViolationsGrew(0, 1),
        )),
      );
      expect(_hashOf(base), beforeHash);
    });

    test('checkForeignKeys=false מדלג על הבדיקה (ונכשל רק על ה-hash)', () {
      final base = buildBaseDb(version: 1, sourceRows: []);
      final bdb = sqlite3.sqlite3.open(base);
      bdb.execute('CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT)');
      bdb.execute(
          'CREATE TABLE book_author (bookId INTEGER REFERENCES book(id),'
          ' authorId INTEGER, PRIMARY KEY (bookId, authorId))');
      bdb.close();

      final patch = buildPatchDb(from: 1, to: 2);
      final pdb = sqlite3.sqlite3.open(patch);
      pdb.execute('CREATE TABLE upsert_book_author (bookId INTEGER, '
          'authorId INTEGER, PRIMARY KEY (bookId, authorId))');
      pdb.execute('INSERT INTO upsert_book_author VALUES (99,5)');
      pdb.close();

      final stages = <String>[];
      expect(
        () => _applier.apply(
          dbPath: base,
          patchPath: patch,
          manifest: _manifest(
            from: 1,
            to: 2,
            fromHash: _hashOf(base),
            toHash: 'deadbeef',
          ),
          checkForeignKeys: false,
          onStage: stages.add,
        ),
        throwsA(isA<PatchApplyException>().having(
          (e) => e.message,
          'message',
          // התחילית הקבועה של המחרוזת מ-otzaria_l10n; ה-hash בפועל משתנה.
          startsWith(LibraryUpdaterMessages.current
              .resultHashMismatch('<A>', '<B>')
              .split('<A>')
              .first),
        )),
      );
      expect(stages, isNot(contains('foreignKeyCheck')));
    });

    // `verifyToHash: false` — הדגל שמאפשר לשרשרת patches לאמת פעם אחת בסוף
    // במקום בכל צעד. ראו `LibraryUpdateApplier.applyDelta`.
    group('verifyToHash כבוי', () {
      test('מקומיט בלי לחשב hash, ומחזיר resultHash null', () {
        final base = buildBaseDb(version: 1, sourceRows: [
          [1, 'aleph'],
        ]);
        final patch = buildPatchDb(from: 1, to: 2, upsertSource: [
          [2, 'bet'],
        ]);
        final stages = <String>[];
        final result = _applier.apply(
          dbPath: base,
          patchPath: patch,
          // ה-hash הזה שגוי בכוונה: כשהאימות כבוי הוא לא נבדק בכלל.
          manifest: _manifest(
            from: 1,
            to: 2,
            fromHash: _hashOf(base),
            toHash: 'deadbeef',
          ),
          verifyToHash: false,
          onStage: stages.add,
        );

        expect(result.resultHash, isNull);
        expect(stages, isNot(contains('verifyToHash')));
        expect(stages, contains('commit'));

        // ההחלה עצמה בוצעה במלואה.
        final db = sqlite3.sqlite3.open(base, mode: sqlite3.OpenMode.readOnly);
        try {
          expect(db.select('SELECT name FROM source ORDER BY id').length, 2);
          expect(
            db
                .select("SELECT value FROM schema_meta WHERE key='db_version'")
                .first['value'],
            '2',
          );
        } finally {
          db.close();
        }
      });

      test('אינו מבטל את preflight הגרסה — patch לא מתאים עוד נדחה', () {
        final base = buildBaseDb(version: 5, sourceRows: [
          [1, 'a'],
        ]);
        final patch = buildPatchDb(from: 1, to: 2);
        expect(
          () => _applier.apply(
            dbPath: base,
            patchPath: patch,
            manifest: _manifest(
              from: 1,
              to: 2,
              fromHash: 'x',
              toHash: 'y',
            ),
            verifyToHash: false,
          ),
          throwsA(isA<PatchApplyException>()),
        );
      });

      test('ברירת המחדל נשארה אימות — מסד שגוי נדחה בלי הדגל', () {
        final base = buildBaseDb(version: 1, sourceRows: [
          [1, 'a'],
        ]);
        final patch = buildPatchDb(from: 1, to: 2);
        expect(
          () => _applier.apply(
            dbPath: base,
            patchPath: patch,
            manifest: _manifest(
              from: 1,
              to: 2,
              fromHash: _hashOf(base),
              toHash: 'deadbeef',
            ),
          ),
          throwsA(isA<PatchApplyException>()),
        );
      });
    });

    test('טבלאות patch שאינן קיימות מדולגות — הספירות מכילות רק את שהופיע', () {
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
      final result = _applier.apply(
        dbPath: base,
        patchPath: patch,
        manifest: _manifest(
          from: 1,
          to: 2,
          fromHash: _hashOf(base),
          toHash: _hashOf(expected),
        ),
      );
      expect(
          result.upserts.keys, containsAll(<String>['source', 'schema_meta']));
      expect(result.deletes, isEmpty);
      expect(result.migrations, 0);
    });
  });

  // הציר השני של החוזה: `patch_meta.schema_version` הוא פורמט ה-patch, לא
  // סכמת ה-DB. ערבוב השניים היה שולח את ה-applier להחיל פורמט שאינו מכיר.
  group('פורמט ה-patch', () {
    test('פורמט שהמניפסט הצהיר עליו חייב להתאים לקובץ', () {
      final base = buildBaseDb(version: 1, sourceRows: [
        [1, 'a'],
      ]);
      final beforeHash = _hashOf(base);
      final patch = buildPatchDb(from: 1, to: 2, schemaVersion: 3);
      final manifest = _manifest(
        from: 1,
        to: 2,
        fromHash: beforeHash,
        toHash: 'whatever',
        patchFormat: 4,
      );

      expect(
        () =>
            _applier.apply(dbPath: base, patchPath: patch, manifest: manifest),
        throwsA(isA<PatchApplyException>()),
      );
      expect(_hashOf(base), beforeHash);
    });

    // סכמת DB 5 פורסמה בפורמט 4 — לקוח שמערבב את הצירים היה פוסל אותה.
    test('פורמט 4 מתקבל גם כשסכמת ה-DB היא 5', () {
      expect(
        const PatchApplier().supportedPatchFormatVersion,
        greaterThanOrEqualTo(4),
      );
    });
  });

  // שדרוג סכמה 4→5: `line_dh` מקבלת את `dhDisplay`, ולכן ה-upsert עליה חייב
  // להיות DO UPDATE — שורה שה-PK שלה לא השתנה עדיין מקבלת ערך חדש.
  group('שדרוג סכמה 4→5 (line_dh.dhDisplay)', () {
    String buildDhDb({
      required int version,
      required int schema,
      required bool withDisplay,
      required List<List> rows,
    }) {
      final path = '${tmp.path}/dh_$version.db';
      final db = sqlite3.sqlite3.open(path);
      db.execute('CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT)');
      db.execute("INSERT INTO schema_meta VALUES ('db_version','$version'),"
          "('db_schema_version','$schema')");
      db.execute('CREATE TABLE line_dh ('
          'bookId INTEGER NOT NULL, dhText TEXT NOT NULL, '
          'lineIndex INTEGER NOT NULL'
          '${withDisplay ? ", dhDisplay TEXT NOT NULL DEFAULT ''" : ''}, '
          'PRIMARY KEY (bookId, dhText, lineIndex)) WITHOUT ROWID');
      final placeholders = withDisplay ? '?,?,?,?' : '?,?,?';
      for (final r in rows) {
        db.execute('INSERT INTO line_dh VALUES ($placeholders)', r);
      }
      db.close();
      return path;
    }

    test('המיגרציה רצה לפני ה-upsert ומעדכנת שורות עם PK קיים', () {
      final base = buildDhDb(version: 26, schema: 4, withDisplay: false, rows: [
        [1, 'מאימתי קורין', 0],
        [1, 'משעה', 1],
      ]);
      final expected =
          buildDhDb(version: 27, schema: 5, withDisplay: true, rows: [
        [1, 'מאימתי קורין', 0, 'מאימתי קורין'],
        [1, 'משעה', 1, 'משעה שהכהנים'],
      ]);

      final patch = '${tmp.path}/patch-26-27.db';
      final patchDb = sqlite3.sqlite3.open(patch);
      patchDb.execute('CREATE TABLE patch_meta (key TEXT PRIMARY KEY, '
          'value TEXT)');
      patchDb.execute("INSERT INTO patch_meta VALUES ('schema_version','4'),"
          "('from_version','26'),('to_version','27')");
      patchDb.execute(
          'CREATE TABLE migrations (version INTEGER PRIMARY KEY, sql TEXT)');
      patchDb.execute('INSERT INTO migrations VALUES (1,?)', [
        "ALTER TABLE line_dh ADD COLUMN dhDisplay TEXT NOT NULL DEFAULT ''",
      ]);
      patchDb.execute('CREATE TABLE upsert_schema_meta '
          '(key TEXT PRIMARY KEY, value TEXT)');
      patchDb.execute('INSERT INTO upsert_schema_meta VALUES '
          "('db_version','27'),('db_schema_version','5')");
      patchDb.execute('CREATE TABLE upsert_line_dh (bookId INTEGER, '
          'dhText TEXT, lineIndex INTEGER, dhDisplay TEXT)');
      patchDb.execute('INSERT INTO upsert_line_dh VALUES (?,?,?,?)',
          [1, 'מאימתי קורין', 0, 'מאימתי קורין']);
      patchDb.execute('INSERT INTO upsert_line_dh VALUES (?,?,?,?)',
          [1, 'משעה', 1, 'משעה שהכהנים']);
      patchDb.close();

      final result = _applier.apply(
        dbPath: base,
        patchPath: patch,
        manifest: _manifest(
          from: 26,
          to: 27,
          fromSchema: 4,
          toSchema: 5,
          patchFormat: 4,
          fromHash: _hashOf(base, tableOrder: kHashTableOrderSchema4),
          toHash: _hashOf(expected, tableOrder: kHashTableOrderSchema4),
        ),
      );

      expect(result.migrations, 1);
      expect(result.upserts['line_dh'], 2);
      // אינדקס נגזר — אינו גורר רענון אינדקס חיפוש.
      expect(result.booksTouched, isEmpty);
      expect(result.hasChangesOutsideBooksTouched, isFalse);
    });
  });

  group('hashTableOrderForSchemaVersion', () {
    test('סכמה-2 → סדר 34 (כולל book_base_text)', () {
      expect(hashTableOrderForSchemaVersion(2), same(kHashTableOrderSchema2));
      expect(kHashTableOrderSchema2.length, 34);
      expect(kHashTableOrderSchema2, contains('book_base_text'));
    });
    test('סכמה-3 → סדר 35 (כולל link_suppressed_side)', () {
      expect(hashTableOrderForSchemaVersion(3), same(kHashTableOrderSchema3));
      expect(kHashTableOrderSchema3.length, 35);
      expect(kHashTableOrderSchema3, contains('link_suppressed_side'));
    });
    // סכמה 5 שינתה עמודה ב-`line_dh` ולא את סדר הטבלאות — שתיהן על אותה
    // רשימה, וה-hasher קורא את העמודות מה-DB עצמו.
    test('סכמות 4 ו-5 → אותו סדר 37 (כולל line_ref ו-line_dh)', () {
      expect(hashTableOrderForSchemaVersion(4), same(kHashTableOrderSchema4));
      expect(hashTableOrderForSchemaVersion(5), same(kHashTableOrderSchema4));
      expect(kHashTableOrderSchema4.length, 37);
      expect(kHashTableOrderSchema4, containsAll(['line_ref', 'line_dh']));
    });
  });

  // אימות מול הקבצים האמיתיים — ה-acceptance criteria 1+2.

  group('סטטיסטיקות מתכנן (stat1_snapshot)', () {
    String buildIndexedDb(String name, int version, {bool withStats = false}) {
      final path = buildBaseDb(version: version, sourceRows: [
        for (var i = 1; i <= 20; i++) [i, 'n${i % 3}']
      ]);
      final target = '${tmp.path}/$name.db';
      File(path).renameSync(target);
      final db = sqlite3.sqlite3.open(target);
      db.execute('CREATE INDEX idx_source_name ON source(name)');
      if (withStats) {
        db.execute('ANALYZE');
        db.execute("UPDATE sqlite_stat1 SET stat = '999 1'");
      }
      db.close();
      return target;
    }

    String buildStatPatch(String name, {List<List>? stats}) {
      final path = buildPatchDb(from: 1, to: 2, upsertSource: [
        [1, 'x'],
      ]);
      final target = '${tmp.path}/$name.db';
      File(path).renameSync(target);
      if (stats != null) {
        final db = sqlite3.sqlite3.open(target);
        db.execute('CREATE TABLE $kPatchStat1SnapshotTable '
            '(tbl TEXT NOT NULL, idx TEXT, stat TEXT NOT NULL)');
        for (final s in stats) {
          db.execute('INSERT INTO $kPatchStat1SnapshotTable VALUES (?,?,?)', s);
        }
        db.close();
      }
      return target;
    }

    List<List<Object?>> statsOf(String dbPath) {
      final db = sqlite3.sqlite3.open(dbPath, mode: sqlite3.OpenMode.readOnly);
      try {
        final exists = db.select('SELECT 1 FROM sqlite_master '
            "WHERE name = 'sqlite_stat1'");
        if (exists.isEmpty) return const [];
        return db
            .select('SELECT tbl, idx, stat FROM sqlite_stat1 ORDER BY tbl, idx')
            .map((r) => r.values)
            .toList();
      } finally {
        db.close();
      }
    }

    const snapshot = [
      ['source', 'idx_source_name', '20 7'],
      ['schema_meta', 'sqlite_autoindex_schema_meta_1', '2 1'],
    ];

    DeltaManifest manifestFor(String base, String expected) => _manifest(
          from: 1,
          to: 2,
          fromHash: _hashOf(base),
          toHash: _hashOf(expected),
        );

    String expectedDb() {
      final e = buildIndexedDb('stat_expected', 2);
      final db = sqlite3.sqlite3.open(e);
      db.execute("UPDATE source SET name = 'x' WHERE id = 1");
      db.close();
      return e;
    }

    test('snapshot מוחל גם כש-verifyToHash כבוי (צעד ביניים בשרשרת)', () {
      final base = buildIndexedDb('stat_base_mid', 1);
      final patch = buildStatPatch('stat_patch_mid', stats: snapshot);

      _applier.apply(
          dbPath: base,
          patchPath: patch,
          verifyToHash: false,
          manifest: _manifest(
              from: 1, to: 2, fromHash: _hashOf(base), toHash: 'unused'));

      expect(statsOf(base), hasLength(2));
    });

    test('snapshot מנקה היסטוגרמות sqlite_stat4 ישנות', () {
      final base = buildIndexedDb('stat_base_s4', 1, withStats: true);
      final db = sqlite3.sqlite3.open(base);
      db.execute('PRAGMA writable_schema = ON');
      db.execute('CREATE TABLE sqlite_stat4(tbl,idx,neq,nlt,ndlt,sample)');
      db.execute('PRAGMA writable_schema = OFF');
      db.execute('INSERT INTO sqlite_stat4 VALUES '
          "('source','idx_source_name','1','1','1',x'00')");
      db.close();
      final expected = expectedDb();
      final patch = buildStatPatch('stat_patch_s4', stats: snapshot);

      _applier.apply(
          dbPath: base,
          patchPath: patch,
          manifest: manifestFor(base, expected));

      final after = sqlite3.sqlite3.open(base, mode: sqlite3.OpenMode.readOnly);
      try {
        expect(after.select('SELECT * FROM sqlite_stat4'), isEmpty);
      } finally {
        after.close();
      }
    });
  });
}
