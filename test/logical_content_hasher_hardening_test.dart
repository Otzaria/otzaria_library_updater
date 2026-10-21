import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:seforim_library_updater/src/models/patch_table_spec.dart';
import 'package:seforim_library_updater/src/hashing/fast_sha256.dart';
import 'package:seforim_library_updater/src/services/logical_content_hasher.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';

const _hasher = LogicalContentHasher();

/// מימוש-עד עצמאי של פורמט הבתים המתועד, בלי חוצץ ובלי הזרמה. משמש לאימות
/// שה-[LogicalContentHasher] המקובץ מייצר בדיוק את אותו זרם — כולל סביב גבול
/// החוצץ (1MB), שם באג היה משנה סדר בתים בלי לשנות אף hash קטן.
List<int> referenceStream(sqlite3.Database db, List<String> tableOrder) {
  final out = <int>[];
  for (final table in tableOrder) {
    out.addAll(utf8.encode(' table:$table '));
    final info = db.select('PRAGMA table_info("$table")');
    if (info.isEmpty) continue;
    final cols = info.map((r) => r['name'] as String).toList()..sort();
    out.addAll(utf8.encode('cols:${cols.join(',')}'));
    out.add(0x00);

    final selectCols = cols
        .map((c) => 'typeof("$c"),CASE WHEN typeof("$c")=\'text\' '
            'THEN CAST("$c" AS BLOB) ELSE "$c" END')
        .join(',');
    final orderBy =
        cols.contains('id') ? 'id' : cols.map((c) => '"$c"').join(',');
    for (final row
        in db.select('SELECT $selectCols FROM "$table" ORDER BY $orderBy')) {
      final values = row.values;
      for (var i = 0; i < values.length; i += 2) {
        final value = values[i + 1];
        switch (values[i] as String) {
          case 'null':
            out.add(0x00);
          case 'text':
            out.add(0x03);
            out.addAll(value as Uint8List);
          case 'blob':
            out.add(0x01);
            out.addAll(value as Uint8List);
          default:
            out.add(0x02);
            out.addAll(utf8.encode(value is double
                ? javaDoubleToString(value)
                : value.toString()));
        }
        out.add(0x1F);
      }
      out.add(0xFF);
    }
  }
  return out;
}

void main() {
  // fixtures — שכבת רגרסיה קבועה ב-CI, ללא תלות ב-DB אמיתי.
  group('LogicalContentHasher fixtures', () {
    // ה-hash חייב להיות עצמאי מהמימוש של SHA-256: המסלול הנייטיבי
    // (`FastSha256`) והמסלול של package:crypto מייצרים אותו golden. בלי זה
    // רגרסיה במסלול אחד הייתה נראית "עוברת" בפלטפורמה שמשתמשת בשני.
    test('שני מסלולי ה-SHA נותנים אותו golden', () {
      final db = sqlite3.sqlite3.openInMemory();
      db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)');
      db.execute('INSERT INTO source VALUES (1, ?)', ['﻿שלום']);
      db.execute("INSERT INTO source VALUES (2,'bet'),(3,NULL)");
      db.execute('CREATE TABLE line (id INTEGER PRIMARY KEY, text TEXT)');
      db.execute('INSERT INTO line VALUES (1, ?)', ['x' * 3000]);

      addTearDown(() => FastSha256.useFallbackOnly = false);
      FastSha256.useFallbackOnly = false;
      final native = _hasher.compute(db, tableOrder: kHashTableOrder);
      FastSha256.useFallbackOnly = true;
      final fallback = _hasher.compute(db, tableOrder: kHashTableOrder);
      expect(native, fallback);
      db.close();
    });

    // goldens נוספים — נועלים את זרם הבתים גם למקרי הקצה, לא רק ל-DB "רגיל".
    // כולם על סדר סכמה-2 הקפוא: מה שהם שומרים הוא הקידוד, לא רשימת הטבלאות,
    // ולכן אין סיבה שיתחלפו בכל הוספת טבלה.
    test('golden: DB ללא אף טבלה — רק ה-markers של 34 הטבלאות', () {
      final db = sqlite3.sqlite3.openInMemory();
      expect(
        _hasher.compute(db, tableOrder: kHashTableOrderSchema2),
        'a90dcaf32e725f36c18bc4bfaa503768777cea28267328ec65d4cf2b00c1b20f',
      );
      db.close();
    });

    test('golden: טבלה קיימת אך ריקה (cols נכתב, אין שורות)', () {
      final db = sqlite3.sqlite3.openInMemory();
      db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)');
      expect(
        _hasher.compute(db, tableOrder: kHashTableOrderSchema2),
        'b2ff6c3838f06cff468875141e36898b788ac42a66c9ff4273e7ce59635bd675',
      );
      db.close();
    });

    // ה-golden הזה נשבר ברגע שה-BOM יילקח מ-String מפוענח במקום מ-CAST AS BLOB.
    test('golden: BOM לצד אותו טקסט בלי BOM', () {
      final db = sqlite3.sqlite3.openInMemory();
      db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)');
      db.execute('INSERT INTO source VALUES (1,?),(2,?)', ['﻿aleph', 'aleph']);
      expect(
        _hasher.compute(db, tableOrder: kHashTableOrderSchema2),
        'f23214051daa700264659215f40bf88ca2b4c0905426034ff2d83e8b265b25fa',
      );
      db.close();
    });

    test('golden: עברית, NULL, blob, REAL ומחרוזת ריקה בשורה אחת', () {
      final db = sqlite3.sqlite3.openInMemory();
      db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT, '
          'weight REAL, payload BLOB, note TEXT)');
      db.execute('INSERT INTO source VALUES (1,?,?,?,?)', [
        'בראשית',
        1.5,
        [0, 1, 255],
        null
      ]);
      db.execute('INSERT INTO source VALUES (2,?,?,?,?)',
          ['﻿רש״י', -0.0, <int>[], '']);
      expect(
        _hasher.compute(db, tableOrder: kHashTableOrderSchema2),
        '70723509e74ff527af77abb47c28c68b1f18d14375ff3d598882921fa4b4336b',
      );
      db.close();
    });
  });

  group('LogicalContentHasher byte stream', () {
    test('זהה למימוש-העד על תוכן מעורב (עברית/BOM/NULL/blob/REAL)', () {
      final db = sqlite3.sqlite3.openInMemory();
      db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT, '
          'weight REAL, payload BLOB, note TEXT)');
      db.execute('INSERT INTO source VALUES (1,?,?,?,?)', [
        'בראשית',
        1.5,
        [0, 1, 255],
        null
      ]);
      db.execute(
          'INSERT INTO source VALUES (2,?,?,?,?)', ['﻿רש״י', 0, <int>[], '']);
      db.execute('CREATE TABLE category_closure '
          '(ancestorId INTEGER, descendantId INTEGER)');
      db.execute('INSERT INTO category_closure VALUES (2,3),(1,2),(1,3)');
      expect(
        _hasher.compute(db, tableOrder: kHashTableOrder),
        sha256.convert(referenceStream(db, kHashTableOrder)).toString(),
      );
      db.close();
    });

    // ערך שגדול מהחוצץ (1MB) מוזרם ישירות אחרי flush — הנתיב שבו באג היה
    // משבש את סדר הבתים בלי להישבר על ערכים קטנים.
    test('ערך ענק (>1MB) ושכנים קטנים — זהה למימוש-העד', () {
      final db = sqlite3.sqlite3.openInMemory();
      db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)');
      db.execute('INSERT INTO source VALUES (1,?)', ['לפני']);
      db.execute('INSERT INTO source VALUES (2,?)', ['א' * 1200000]);
      db.execute('INSERT INTO source VALUES (3,?)', ['אחרי']);
      expect(
        _hasher.compute(db, tableOrder: kHashTableOrder),
        sha256.convert(referenceStream(db, kHashTableOrder)).toString(),
      );
      db.close();
    });

    test('ערכים סביב גבול החוצץ בדיוק — זהה למימוש-העד', () {
      final db = sqlite3.sqlite3.openInMemory();
      db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)');
      const capacity = 1 << 20;
      for (final (i, len) in [
        (1, capacity - 1),
        (2, capacity),
        (3, capacity + 1),
      ]) {
        db.execute('INSERT INTO source VALUES (?,?)', [i, 'x' * len]);
      }
      expect(
        _hasher.compute(db, tableOrder: kHashTableOrder),
        sha256.convert(referenceStream(db, kHashTableOrder)).toString(),
      );
      db.close();
    });

    test('INTEGER בקצוות הטווח — זהה למימוש-העד', () {
      final db = sqlite3.sqlite3.openInMemory();
      db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, v INTEGER)');
      const values = [0, 7, 9, 10, 99, 100, 123456789, -1, -10, -905, 1 << 53];
      const extremes = [9223372036854775807, -9223372036854775808];
      for (final (i, v) in [...values, ...extremes].indexed) {
        db.execute('INSERT INTO source VALUES (?,?)', [i + 1, v]);
      }
      final reports = <int>[];
      final reference = referenceStream(db, const ['source']);
      expect(
        _hasher.compute(db,
            tableOrder: const ['source'], onProgress: reports.add),
        sha256.convert(reference).toString(),
      );
      expect(reports.last, reference.length);
      db.close();
    });

    // מספר ארוך שנכתב בדיוק סביב סוף החוצץ (1MB) לא נחתך ולא מוזז.
    test('INTEGER סביב גבול החוצץ — זהה למימוש-העד', () {
      const capacity = 1 << 20;
      for (var pad = capacity - 50; pad < capacity - 20; pad++) {
        final db = sqlite3.sqlite3.openInMemory();
        db.execute('CREATE TABLE source (a TEXT, b INTEGER)');
        db.execute('INSERT INTO source VALUES (?,?)',
            ['x' * pad, 9223372036854775807]);
        expect(
          _hasher.compute(db, tableOrder: const ['source']),
          sha256.convert(referenceStream(db, const ['source'])).toString(),
          reason: 'pad=$pad',
        );
        db.close();
      }
    });

    test('onProgress: הדיווח האחרון הוא סך הבתים המדויק ומונוטוני', () {
      final db = sqlite3.sqlite3.openInMemory();
      db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)');
      for (var i = 0; i < 40; i++) {
        db.execute('INSERT INTO source VALUES (?,?)', [i, 'y' * 900000]);
      }
      final reports = <int>[];
      _hasher.compute(db, tableOrder: kHashTableOrder, onProgress: reports.add);
      expect(reports, isNotEmpty);
      expect(reports.last, referenceStream(db, kHashTableOrder).length);
      expect(reports, orderedEquals(reports.toList()..sort()));
      db.close();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // בתי-הסוג נקראים כמסכות של 20 עמודות. הגבול הזה הוא מסלול קוד שלם שאינו
  // מופעל באף טבלה צרה, ובאג בו היה מזיז בתי-סוג בין עמודות — hash שונה בלי
  // שום שינוי בתוכן. מימוש-העד קורא `typeof()` כמחרוזת ולכן הוא עד עצמאי.
  group('LogicalContentHasher מסכות בתי-הסוג', () {
    /// בונה את `book` עם [n] עמודות `c0..c(n-1)`, ובשורה אחת מחזורי הסוגים
    /// כולם: NULL, מספר שלם, טקסט, blob ו-REAL — כדי שכל תג ייפול על כל
    /// מקום אפשרי בתוך המסכה.
    sqlite3.Database wide(int n) {
      final db = sqlite3.sqlite3.openInMemory();
      final cols = [for (var i = 0; i < n; i++) 'c$i'];
      db.execute('CREATE TABLE book (${cols.join(',')})');
      final row = <Object?>[];
      for (var i = 0; i < n; i++) {
        row.add(switch (i % 5) {
          0 => null,
          1 => i * 1000,
          2 => 'טקסט $i',
          3 => Uint8List.fromList([0, i % 256, 255]),
          _ => i + 0.5,
        });
      }
      db.execute(
        'INSERT INTO book VALUES (${List.filled(n, '?').join(',')})',
        row,
      );
      return db;
    }

    // 19/20 = מסכה אחת (20 היא הקיבולת המדויקת), 21/41 = גלישה למסכה שנייה
    // ושלישית. 41 גם מוודא שהעמודה הראשונה של מסכה חדשה מתחילה מהיסט 0.
    for (final n in [1, 19, 20, 21, 40, 41]) {
      test('טבלה בת-$n עמודות — זהה למימוש-העד', () {
        final db = wide(n);
        expect(
          _hasher.compute(db, tableOrder: kHashTableOrder),
          sha256.convert(referenceStream(db, kHashTableOrder)).toString(),
        );
        db.close();
      });
    }

    // עמודות ממוינות אלפביתית, ולכן c10 בא לפני c2 — הסדר שבו התגים נארזים
    // חייב להיות זה של העמודות הממוינות, לא זה של הצהרת ה-CREATE TABLE.
    test('מיון אלפביתי של שמות העמודות נשמר בתוך המסכה', () {
      final db = wide(25);
      final cols = (db.select('PRAGMA table_info("book")'))
          .map((r) => r['name'] as String)
          .toList()
        ..sort();
      expect(cols.take(3), ['c0', 'c1', 'c10']);
      expect(
        _hasher.compute(db, tableOrder: kHashTableOrder),
        sha256.convert(referenceStream(db, kHashTableOrder)).toString(),
      );
      db.close();
    });

    // טקסט ו-blob מגיעים שניהם כ-Uint8List, ורק המסכה מבדילה ביניהם — גם
    // כשהם ריקים או זהים בבתים, ובקצות המסכה (19/20).
    test('טקסט מול blob ריקים וזהים בקצות המסכה — זהה למימוש-העד', () {
      final db = sqlite3.sqlite3.openInMemory();
      final cols = [for (var i = 0; i < 25; i++) 'c${'$i'.padLeft(2, '0')}'];
      db.execute('CREATE TABLE book (${cols.join(',')})');
      final ph = List.filled(25, '?').join(',');
      for (final pair in [
        ['', Uint8List(0)],
        ['﻿ab', Uint8List.fromList(utf8.encode('﻿ab'))],
      ]) {
        for (final shift in [0, 1]) {
          db.execute('INSERT INTO book VALUES ($ph)',
              [for (var i = 0; i < 25; i++) pair[(i + shift) % 2]]);
        }
      }
      expect(
        _hasher.compute(db, tableOrder: kHashTableOrder),
        sha256.convert(referenceStream(db, kHashTableOrder)).toString(),
      );
      db.close();
    });

    // כל חמשת הסוגים בשורה אחת, בטבלה צרה — נועל את מיפוי ה-CASE בעצמו.
    test('כל חמשת סוגי SQLite בשורה אחת — זהה למימוש-העד', () {
      final db = sqlite3.sqlite3.openInMemory();
      db.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, a, b, c, d)');
      db.execute('INSERT INTO source VALUES (1,?,?,?,?)', [
        null,
        42,
        'שלום',
        Uint8List.fromList([0, 1, 255])
      ]);
      db.execute('INSERT INTO source VALUES (2,?,?,?,?)',
          [1.5, -0.0, double.infinity, double.nan]);
      expect(
        _hasher.compute(db, tableOrder: kHashTableOrder),
        sha256.convert(referenceStream(db, kHashTableOrder)).toString(),
      );
      db.close();
    });
  });

  group('LogicalContentHasher canonicalisation', () {
    sqlite3.Database build(String create, List<String> inserts) {
      final db = sqlite3.sqlite3.openInMemory();
      db.execute(create);
      for (final sql in inserts) {
        db.execute(sql);
      }
      return db;
    }

    // העמודות ממוינות אלפביתית לפני הקריאה, ולכן סדר ההצהרה אינו משפיע.
    test('סדר הצהרת העמודות אינו משנה את ה-hash', () {
      final a = build(
        'CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)',
        ["INSERT INTO source VALUES (1,'aleph')"],
      );
      final b = build(
        'CREATE TABLE source (name TEXT, id INTEGER PRIMARY KEY)',
        ["INSERT INTO source (id,name) VALUES (1,'aleph')"],
      );
      expect(_hasher.compute(a, tableOrder: kHashTableOrder),
          _hasher.compute(b, tableOrder: kHashTableOrder));
      a.close();
      b.close();
    });

    test('שינוי שם עמודה משנה את ה-hash (הקידומת cols:)', () {
      final a = build(
        'CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)',
        ["INSERT INTO source VALUES (1,'aleph')"],
      );
      final b = build(
        'CREATE TABLE source (id INTEGER PRIMARY KEY, title TEXT)',
        ["INSERT INTO source VALUES (1,'aleph')"],
      );
      expect(_hasher.compute(a, tableOrder: kHashTableOrder),
          isNot(_hasher.compute(b, tableOrder: kHashTableOrder)));
      a.close();
      b.close();
    });

    // טבלה בלי עמודת id ממוינת לפי כל העמודות — junction אינה תלויה בסדר rowid.
    test('טבלה בלי id: סדר הכנסה אינו משנה', () {
      final a = build(
        'CREATE TABLE category_closure (ancestorId INTEGER, descendantId INTEGER)',
        ['INSERT INTO category_closure VALUES (1,2),(1,3),(2,3)'],
      );
      final b = build(
        'CREATE TABLE category_closure (ancestorId INTEGER, descendantId INTEGER)',
        ['INSERT INTO category_closure VALUES (2,3),(1,3),(1,2)'],
      );
      expect(_hasher.compute(a, tableOrder: kHashTableOrder),
          _hasher.compute(b, tableOrder: kHashTableOrder));
      a.close();
      b.close();
    });

    test('NULL אינו זהה למחרוזת ריקה', () {
      final a = build('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)',
          ['INSERT INTO source VALUES (1,NULL)']);
      final b = build('CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)',
          ["INSERT INTO source VALUES (1,'')"]);
      expect(_hasher.compute(a, tableOrder: kHashTableOrder),
          isNot(_hasher.compute(b, tableOrder: kHashTableOrder)));
      a.close();
      b.close();
    });

    // המספר מקודד דרך toString(): 1 ≠ 1.0, בדיוק כמו בצד ה-Kotlin.
    test('INTEGER 1 אינו זהה ל-REAL 1.0', () {
      final a = build('CREATE TABLE source (id INTEGER PRIMARY KEY, v)',
          ['INSERT INTO source VALUES (1,1)']);
      final b = build('CREATE TABLE source (id INTEGER PRIMARY KEY, v)',
          ['INSERT INTO source VALUES (1,1.0)']);
      expect(_hasher.compute(a, tableOrder: kHashTableOrder),
          isNot(_hasher.compute(b, tableOrder: kHashTableOrder)));
      a.close();
      b.close();
    });

    test('blob וטקסט בעלי אותם בייטים אינם מתנגשים (בית-סוג שונה)', () {
      final a = build('CREATE TABLE source (id INTEGER PRIMARY KEY, v)',
          ["INSERT INTO source VALUES (1,'AB')"]);
      final b = sqlite3.sqlite3.openInMemory();
      b.execute('CREATE TABLE source (id INTEGER PRIMARY KEY, v)');
      b.execute('INSERT INTO source VALUES (1,?)', [
        [0x41, 0x42]
      ]);
      expect(_hasher.compute(a, tableOrder: kHashTableOrder),
          isNot(_hasher.compute(b, tableOrder: kHashTableOrder)));
      a.close();
      b.close();
    });

    // marker נכתב לכל טבלה בסדר, גם כשאינה קיימת — הוספת שם לרשימה משנה hash.
    test('טבלה חסרה עדיין תורמת marker לזרם', () {
      final db = build('CREATE TABLE source (id INTEGER PRIMARY KEY)',
          ['INSERT INTO source VALUES (1)']);
      expect(
        _hasher.compute(db, tableOrder: const ['source']),
        isNot(_hasher.compute(db, tableOrder: const ['source', 'author'])),
      );
      db.close();
    });

    test('שינוי סדר הטבלאות משנה את ה-hash', () {
      final db = build(
        'CREATE TABLE source (id INTEGER PRIMARY KEY, name TEXT)',
        ["INSERT INTO source VALUES (1,'a')"],
      );
      db.execute('CREATE TABLE author (id INTEGER PRIMARY KEY, name TEXT)');
      db.execute("INSERT INTO author VALUES (1,'b')");
      expect(
        _hasher.compute(db, tableOrder: const ['source', 'author']),
        isNot(_hasher.compute(db, tableOrder: const ['author', 'source'])),
      );
      db.close();
    });

    test('סדר-33 וסדר-34 נותנים hash שונה על אותו DB', () {
      final db = build(
        'CREATE TABLE book_base_text (bookId INTEGER, baseBookId INTEGER)',
        ['INSERT INTO book_base_text VALUES (1,2)'],
      );
      expect(
        _hasher.compute(db, tableOrder: kHashTableOrderSchema2),
        isNot(_hasher.compute(db, tableOrder: kHashTableOrderSchema1)),
      );
      db.close();
    });
  });

  group('REAL כמו Double.toString של Java', () {
    const golden = <(double, String)>[
      (0.0005, '5.0E-4'),
      (1e-4, '1.0E-4'),
      (1e7, '1.0E7'),
      (9999999.999999998, '9999999.999999998'),
      (0.001, '0.001'),
      (0.0009999999999999998, '9.999999999999998E-4'),
      (0.002, '0.002'),
      (1e-5, '1.0E-5'),
      (1e-7, '1.0E-7'),
      (-3.0e-5, '-3.0E-5'),
      (1.2345678e7, '1.2345678E7'),
      (123456789012345680.0, '1.2345678901234568E17'),
      (1e16, '1.0E16'),
      (1e21, '1.0E21'),
      (8.41e21, '8.41E21'),
      (1e23, '1.0E23'),
      (2e23, '2.0E23'),
      (1.5e300, '1.5E300'),
      (1e-300, '1.0E-300'),
      (5e-310, '5.0E-310'),
      (1.1e-322, '1.1E-322'),
      (4.9e-324, '4.9E-324'),
      (1.5e-323, '1.5E-323'),
      (2.2250738585072014e-308, '2.2250738585072014E-308'),
      (1.7976931348623157e308, '1.7976931348623157E308'),
      (0.30000000000000004, '0.30000000000000004'),
      (0.5, '0.5'),
      (1.0, '1.0'),
      (-1.0, '-1.0'),
      (100.0, '100.0'),
      (1234567.0, '1234567.0'),
      (0.0, '0.0'),
      (-0.0, '-0.0'),
      (double.infinity, 'Infinity'),
      (double.negativeInfinity, '-Infinity'),
      (double.nan, 'NaN'),
      (-2.5, '-2.5'),
    ];

    for (final (value, java) in golden) {
      test('$value → $java', () {
        expect(javaDoubleToString(value), java);
      });
    }

    test('ערך REAL מחוץ לטווח מקודד בזרם בפורמט של Java', () {
      final db = sqlite3.sqlite3.openInMemory();
      db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v REAL)');
      db.execute('INSERT INTO t VALUES (1, 1e7), (2, 0.0005)');
      final expected = <int>[
        ...utf8.encode(' table:t cols:id,v'),
        0x00,
        0x02,
        ...utf8.encode('1'),
        0x1F,
        0x02,
        ...utf8.encode('1.0E7'),
        0x1F,
        0xFF,
        0x02,
        ...utf8.encode('2'),
        0x1F,
        0x02,
        ...utf8.encode('5.0E-4'),
        0x1F,
        0xFF,
      ];
      expect(
        _hasher.compute(db, tableOrder: const ['t']),
        sha256.convert(expected).toString(),
      );
      db.close();
    });
  });

  // אימות מול ה-DBs האמיתיים — ה-ground truth מול מימוש ה-Kotlin.
  // מדלג אם הקבצים אינם זמינים (CI). ריצה מקומית מאמתת התאמה מלאה.
}
