/// נקודת הכניסה היחידה של החבילה ל-SQLite.
///
/// ייבוא ישיר של `package:sqlite3/sqlite3.dart` גורר את בינדינגי ה-FFI ומפיל
/// את הקומפילציה ל-web אצל כל צרכן של החבילה; דרך קובץ זה נבחר מימוש לפי
/// הפלטפורמה.
library;

export 'sqlite3_api_stub.dart'
    if (dart.library.io) 'package:sqlite3/sqlite3.dart';
