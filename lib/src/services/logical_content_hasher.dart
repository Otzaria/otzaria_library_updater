import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:seforim_library_updater/src/sqlite/sqlite3_api.dart' as sqlite3;

import '../hashing/fast_sha256.dart';
import '../hashing/fast_sha256_sink.dart';

/// מחשב logical content hash על תוכן ה-DB, בדיוק כמו `LogicalContentHasher.kt`
/// בצד הייצור (SeforimLibrary). ה-hash משמש לאימות שה-DB המקומי תואם בדיוק
/// ל-`fromContentHash`/`toContentHash` שב-manifest.
///
/// האלגוריתם (אומת אות-באות מול שרשרת v14/v15 האמיתית):
/// * לכל טבלה בסדר ה-hash הנתון ([compute]‏ `tableOrder`, לפי גרסת הסכמה —
///   ראו `hashTableOrderForSchemaVersion`) נכתב הקידומת `" table:<name> "` —
///   תמיד, גם אם הטבלה אינה קיימת.
/// * אם הטבלה קיימת: `"cols:<c1,c2,...>"` (עמודות ממוינות אלפביתית) ואז בית 0x00.
/// * השורות נקראות לפי `ORDER BY id` (אם יש עמודת id) או לפי כל העמודות.
/// * לכל תא: בית-סוג ואז הנתונים, ואז מפריד יחידה 0x1F.
///   null=0, blob=1+bytes, מספר=2+toString().utf8, טקסט=3+toString().utf8;
///   REAL בפורמט `Double.toString` של Java ([javaDoubleToString]).
/// * אחרי כל שורה: מפריד שורה 0xFF.
///
/// זרם הבתים מוזרם ל-SHA-256 דרך [_BufferedByteSink] שמקבץ ~1MB לפני כל
/// עדכון — חוסך מיליוני קריאות זעירות. SHA-256 אינו תלוי בגודל ה-chunks,
/// אז הקיבוץ אינו משנה את התוצאה.
class LogicalContentHasher {
  const LogicalContentHasher();

  // בתים של תגי-סוג ומפרידים — זהים למימוש ה-Kotlin, אין לשנות.
  static const int _nullTag = 0x00;
  static const int _blobTag = 0x01;
  static const int _numberTag = 0x02;
  static const int _textTag = 0x03;
  static const int _unitSeparator = 0x1F;
  static const int _rowSeparator = 0xFF;

  // בתי-הסוג נקראים כמסכה: 3 ביטים לעמודה, 20 עמודות (60 ביט) למסכה.
  static const int _bitsPerTag = 3;
  static const int _colsPerMask = 20;

  /// מחשב את ה-hash על [db] ומחזיר אותו כ-hex. ניתן להריץ על חיבור read-only
  /// (preflight) או על חיבור כתיב בתוך transaction (אימות אחרי apply).
  ///
  /// [onProgress] מדווח את מספר הבתים המצטבר שהוזרם ל-SHA עד כה (מדוד כל
  /// ~16MB), למד התקדמות במהלך האימות הארוך.
  /// [tableOrder] — סדר הטבלאות לפי גרסת הסכמה של ה-DB. אין ברירת מחדל:
  /// הסדר של הסכמה הנוכחית נותן hash שגוי על DB בסכמה ישנה.
  String compute(sqlite3.Database db,
          {required List<String> tableOrder,
          void Function(int bytesHashed)? onProgress}) =>
      _compute(db,
              tableOrder: tableOrder,
              onProgress: onProgress,
              includeTableHashes: false)
          .wholeHash!;

  /// מחשב במעבר יחיד את ה-hash הכולל ואת ה-hash של כל טבלה בנפרד
  /// (`tableHash(t) = sha256` של בדיוק הבתים שהטבלה תורמת לזרם הכולל).
  ///
  /// [only] — כשניתן, מחושבות רק הטבלאות שבו (בסדר [tableOrder]),
  /// ו-[LogicalContentHashReport.wholeHash] יהיה null.
  LogicalContentHashReport computeReport(sqlite3.Database db,
          {required List<String> tableOrder,
          Set<String>? only,
          void Function(int bytesHashed)? onProgress}) =>
      _compute(db,
          tableOrder: tableOrder,
          only: only,
          onProgress: onProgress,
          includeTableHashes: true);

  /// המימוש המשותף שומר על [compute] זול: המסלול הוותיק מחשב SHA יחיד בלבד.
  /// hash לכל טבלה מחושב רק דרך [computeReport], שבו הוא נדרש בפועל.
  LogicalContentHashReport _compute(sqlite3.Database db,
      {required List<String> tableOrder,
      required bool includeTableHashes,
      Set<String>? only,
      void Function(int bytesHashed)? onProgress}) {
    assert(includeTableHashes || only == null);
    final wholeDigest = only == null ? Sha256DigestCollector() : null;
    final wholeSink =
        wholeDigest == null ? null : FastSha256.start(wholeDigest);
    FastSha256Sink? tableSink;
    // החוצץ הנייטיבי מחוץ לאיסוף האשפה: כל כשל SQLite באמצע חייב לשחרר אותו.
    try {
      final out = _BufferedByteSink(wholeSink, onProgress: onProgress);
      final tableHashes = <String, String>{};
      final tableBytes = <String, int>{};

      for (final table in tableOrder) {
        if (only != null && !only.contains(table)) continue;
        final tableDigest = includeTableHashes ? Sha256DigestCollector() : null;
        tableSink = tableDigest == null ? null : FastSha256.start(tableDigest);
        if (tableSink != null) out.beginTable(tableSink);

        out.addBytes(utf8.encode(' table:$table '));
        final cols = _readColumnsCanonical(db, table);
        if (cols != null) {
          out.addBytes(utf8.encode('cols:${cols.join(',')}'));
          out.addByte(_nullTag);

          final masks = _maskExpressions(cols);
          final selectCols =
              [...masks, ...cols.map(_valueExpression)].join(',');
          final orderBy =
              cols.contains('id') ? 'id' : cols.map((c) => '"$c"').join(',');
          final stmt =
              db.prepare('SELECT $selectCols FROM "$table" ORDER BY $orderBy');
          try {
            final maskCount = masks.length;
            final colCount = cols.length;
            final cursor = stmt.selectCursor(const []);
            while (cursor.moveNext()) {
              final values = cursor.current.values;
              for (var i = 0; i < colCount; i++) {
                final mask = values[i ~/ _colsPerMask] as int;
                final tag = (mask >> ((i % _colsPerMask) * _bitsPerTag)) & 0x07;
                _encodeCell(out, tag, values[maskCount + i]);
              }
              out.addByte(_rowSeparator);
            }
          } finally {
            stmt.close();
          }
        }

        if (tableSink != null) {
          tableBytes[table] = out.endTable();
          tableSink.close();
          tableSink = null;
          tableHashes[table] = tableDigest!.value.toString();
        }
      }

      out.flush();
      // דיווח סופי מדויק — מאפשר ל-caller לשמור את סך-הבתים לריצה הבאה.
      onProgress?.call(out.totalHashed);
      wholeSink?.close();
      return LogicalContentHashReport(
        wholeHash: wholeDigest?.value.toString(),
        tableHashes: tableHashes,
        tableBytes: tableBytes,
      );
    } finally {
      tableSink?.dispose();
      wholeSink?.dispose();
    }
  }

  /// ל-text קוראים את ה-bytes הגולמיים (CAST AS BLOB): ה-decoder של Dart מסיר
  /// U+FEFF מוביל, ו-String רגיל היה משנה את ה-hash.
  String _valueExpression(String c) =>
      'CASE WHEN typeof("$c")=\'text\' THEN CAST("$c" AS BLOB) ELSE "$c" END';

  /// בתי-הסוג של כל העמודות ארוזים למספרים שלמים — קריאת FFI אחת לשורה במקום
  /// מחרוזת `typeof()` לכל תא. הערכים 0–3 הם בדיוק תגי הסוג של הזרם.
  List<String> _maskExpressions(List<String> cols) {
    final masks = <String>[];
    for (var start = 0; start < cols.length; start += _colsPerMask) {
      final end = math.min(start + _colsPerMask, cols.length);
      final parts = <String>[];
      for (var i = start; i < end; i++) {
        parts.add(
            '((${_tagExpression(cols[i])})<<${(i - start) * _bitsPerTag})');
      }
      masks.add(parts.join('|'));
    }
    return masks;
  }

  /// ה-ELSE מכסה 'integer' ו-'real'; ההבחנה ביניהם לפי סוג הערך בדארט.
  String _tagExpression(String c) => 'CASE typeof("$c") '
      'WHEN \'null\' THEN $_nullTag '
      'WHEN \'blob\' THEN $_blobTag '
      'WHEN \'text\' THEN $_textTag '
      'ELSE $_numberTag END';

  /// קורא את שמות העמודות ממוינים אלפביתית, או null אם הטבלה אינה קיימת.
  List<String>? _readColumnsCanonical(sqlite3.Database db, String table) {
    final result = db.select('PRAGMA table_info("$table")');
    if (result.isEmpty) return null;
    final names = result.map((r) => r['name'] as String).toList();
    names.sort();
    return names;
  }

  /// [tag] הוא בית-הסוג מהמסכה. עבור [_textTag] ו-[_blobTag], [value] הוא
  /// ה-bytes הגולמיים (Uint8List).
  void _encodeCell(_BufferedByteSink out, int tag, Object? value) {
    switch (tag) {
      case _nullTag:
        out.addByte(_nullTag);
      case _textTag:
        out.addByte(_textTag);
        out.addBytes(value as Uint8List);
      case _blobTag:
        out.addByte(_blobTag);
        out.addBytes(value as Uint8List);
      default:
        out.addByte(_numberTag);
        out.addBytes(utf8.encode(
            value is double ? javaDoubleToString(value) : value.toString()));
    }
    out.addByte(_unitSeparator);
  }
}

/// `Double.toString` של Java — מה ש-`LogicalContentHasher.kt` כותב ל-REAL.
/// Dart כותב `0.0001` ו-`10000000.0` היכן ש-Java כותבת `1.0E-4` ו-`1.0E7`.
String javaDoubleToString(double value) {
  if (!value.isFinite || value == 0) return value.toString();
  final x = value.abs();
  var sci = x.toStringAsExponential();
  var digits = sci.substring(0, sci.indexOf('e')).replaceFirst('.', '');
  if (digits.length == 1) {
    final twoDigits = x.toStringAsExponential(1);
    if (double.parse(twoDigits) == x) sci = twoDigits;
  }
  final e = sci.indexOf('e');
  digits = sci.substring(0, e).replaceFirst('.', '');
  while (digits.length > 1 && digits.endsWith('0')) {
    digits = digits.substring(0, digits.length - 1);
  }
  final exp = int.parse(sci.substring(e + 1));
  final String body;
  if (exp >= 0 && exp < 7) {
    final intLen = exp + 1;
    body = digits.length > intLen
        ? '${digits.substring(0, intLen)}.${digits.substring(intLen)}'
        : '${digits.padRight(intLen, '0')}.0';
  } else if (exp < 0 && exp >= -3) {
    body = '0.${'0' * (-exp - 1)}$digits';
  } else {
    final frac = digits.length > 1 ? digits.substring(1) : '0';
    body = '${digits[0]}.${frac}E$exp';
  }
  return value < 0 ? '-$body' : body;
}

/// תוצאת [LogicalContentHasher.computeReport] — hash כולל, hash לכל טבלה
/// ומספר הבתים שהוזרמו לכל טבלה (רמז התקדמות לריצה הבאה).
class LogicalContentHashReport {
  /// ה-hash של כל זרם הטבלאות ברצף. null כשבוקשה תת-קבוצה (`only`), כי אז
  /// לא הוזרמו כל הטבלאות.
  final String? wholeHash;

  /// hash לכל טבלה שחושבה, לפי סדר ה-hash.
  final Map<String, String> tableHashes;

  /// מספר הבתים שהוזרמו ל-SHA עבור כל טבלה שחושבה.
  final Map<String, int> tableBytes;

  const LogicalContentHashReport({
    required this.wholeHash,
    required this.tableHashes,
    required this.tableBytes,
  });
}

/// חוצץ בינארי שמצטבר ומוזרם ל-SHA-256 מדי ~1MB. מחליף מיליוני `add` זעירים
/// (בית/תא) בעדכונים גדולים בודדים, בלי לשנות את זרם הבתים.
class _BufferedByteSink {
  _BufferedByteSink(this._sink, {this.onProgress});

  /// ה-digest הכולל. null כשבוקשה תת-קבוצה של טבלאות ואין hash כולל.
  final ByteConversionSink? _sink;

  /// ה-digest של הטבלה הנוכחית — מקבל בדיוק את אותם טווחי בתים.
  ByteConversionSink? _tableSink;
  int _tableStart = 0;
  final void Function(int bytesHashed)? onProgress;
  static const int _capacity = 1 << 20; // 1MB
  static const int _progressInterval = 16 << 20; // 16MB
  final Uint8List _buffer = Uint8List(_capacity);
  int _length = 0;
  int _totalHashed = 0;
  int _lastReported = 0;

  int get totalHashed => _totalHashed;

  /// פותח טבלה חדשה: מרוקן את החוצץ כדי שה-digest של הטבלה יקבל בדיוק את
  /// הבתים שלה — SHA-256 אינו תלוי בגבולות ה-chunks, אז ה-hash הכולל לא משתנה.
  void beginTable(ByteConversionSink sink) {
    flush();
    _tableSink = sink;
    _tableStart = _totalHashed;
  }

  /// סוגר את הטבלה הנוכחית ומחזיר את מספר הבתים שהוזרמו עבורה.
  int endTable() {
    flush();
    _tableSink = null;
    return _totalHashed - _tableStart;
  }

  void addByte(int byte) {
    if (_length == _capacity) flush();
    _buffer[_length++] = byte;
    _totalHashed++;
  }

  void addBytes(List<int> bytes) {
    final len = bytes.length;
    // ערך גדול מהחוצץ מוזרם ישירות אחרי flush — בלי העתקה מיותרת. ה-flush
    // חובה לפני, אחרת סדר הבתים ישתבש.
    if (len >= _capacity) {
      flush();
      _sink?.add(bytes);
      _tableSink?.add(bytes);
      _totalHashed += len;
      _reportIfDue();
      return;
    }
    if (_length + len > _capacity) flush();
    _buffer.setRange(_length, _length + len, bytes);
    _length += len;
    _totalHashed += len;
  }

  /// מזרים את מה שהצטבר. הזרם הסינכרוני של SHA-256 לא מחזיק את ה-view, אז
  /// ניתן לעשות שימוש חוזר ב-[_buffer] מיד אחרי.
  void flush() {
    if (_length == 0) return;
    final view = Uint8List.sublistView(_buffer, 0, _length);
    _sink?.add(view);
    _tableSink?.add(view);
    _length = 0;
    _reportIfDue();
  }

  void _reportIfDue() {
    if (onProgress == null) return;
    if (_totalHashed - _lastReported < _progressInterval) return;
    _lastReported = _totalHashed;
    onProgress!(_totalHashed);
  }
}
