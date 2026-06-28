import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import '../models/patch_table_spec.dart';

/// מחשב logical content hash על תוכן ה-DB, בדיוק כמו `LogicalContentHasher.kt`
/// בצד הייצור (SeforimLibrary). ה-hash משמש לאימות שה-DB המקומי תואם בדיוק
/// ל-`fromContentHash`/`toContentHash` שב-manifest.
///
/// האלגוריתם (אומת אות-באות מול v1/v2/v3 האמיתיים):
/// * לכל טבלה ב-[kHashTableOrder] נכתב הקידומת `" table:<name> "` — תמיד,
///   גם אם הטבלה אינה קיימת.
/// * אם הטבלה קיימת: `"cols:<c1,c2,...>"` (עמודות ממוינות אלפביתית) ואז בית 0x00.
/// * השורות נקראות לפי `ORDER BY id` (אם יש עמודת id) או לפי כל העמודות.
/// * לכל תא: בית-סוג ואז הנתונים, ואז מפריד יחידה 0x1F.
///   null=0, blob=1+bytes, מספר=2+toString().utf8, טקסט=3+toString().utf8.
/// * אחרי כל שורה: מפריד שורה 0xFF.
class LogicalContentHasher {
  const LogicalContentHasher();

  static const List<int> _nullTag = [0x00];
  static const List<int> _blobTag = [0x01];
  static const List<int> _numberTag = [0x02];
  static const List<int> _textTag = [0x03];
  static const List<int> _unitSeparator = [0x1F];
  static const List<int> _rowSeparator = [0xFF];

  /// מחשב את ה-hash על [db] ומחזיר אותו כ-hex. ניתן להריץ על חיבור read-only
  /// (preflight) או על חיבור כתיב בתוך transaction (אימות אחרי apply).
  String compute(sqlite3.Database db) {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);

    for (final table in kHashTableOrder) {
      input.add(utf8.encode(' table:$table '));
      final cols = _readColumnsCanonical(db, table);
      if (cols == null) continue;
      input.add(utf8.encode('cols:${cols.join(',')}'));
      input.add(_nullTag);

      // ל-text קוראים את ה-bytes הגולמיים (CAST AS BLOB) כדי לא לאבד BOM
      // מוביל — ה-decoder של Dart מסיר U+FEFF, ולכן String רגיל היה משנה את
      // ה-hash. typeof קובע את בית-הסוג; ה-CASE מחזיר blob רק ל-text.
      final selectCols = cols
          .map((c) => 'typeof("$c"),CASE WHEN typeof("$c")=\'text\' '
              'THEN CAST("$c" AS BLOB) ELSE "$c" END')
          .join(',');
      final orderBy =
          cols.contains('id') ? 'id' : cols.map((c) => '"$c"').join(',');
      final stmt =
          db.prepare('SELECT $selectCols FROM "$table" ORDER BY $orderBy');
      try {
        final cursor = stmt.selectCursor(const []);
        while (cursor.moveNext()) {
          final values = cursor.current.values;
          for (var i = 0; i < values.length; i += 2) {
            _encodeCell(input, values[i] as String, values[i + 1]);
          }
          input.add(_rowSeparator);
        }
      } finally {
        stmt.close();
      }
    }

    input.close();
    return sink.digest.toString();
  }

  /// קורא את שמות העמודות ממוינים אלפביתית, או null אם הטבלה אינה קיימת.
  List<String>? _readColumnsCanonical(sqlite3.Database db, String table) {
    final result = db.select('PRAGMA table_info("$table")');
    if (result.isEmpty) return null;
    final names = result.map((r) => r['name'] as String).toList();
    names.sort();
    return names;
  }

  /// [type] הוא תוצאת `typeof()` ('null'/'integer'/'real'/'text'/'blob').
  /// עבור 'text' ו-'blob', [value] הוא ה-bytes הגולמיים (Uint8List).
  void _encodeCell(ByteConversionSink input, String type, Object? value) {
    switch (type) {
      case 'null':
        input.add(_nullTag);
      case 'text':
        input.add(_textTag);
        input.add(value as Uint8List);
      case 'blob':
        input.add(_blobTag);
        input.add(value as Uint8List);
      default: // 'integer' / 'real'
        input.add(_numberTag);
        input.add(utf8.encode(value.toString()));
    }
    input.add(_unitSeparator);
  }
}

/// אוסף את ה-Digest הסופי מ-`startChunkedConversion`.
class _DigestSink implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
