import 'dart:convert';

import 'package:crypto/crypto.dart';

/// sink של SHA-256 שניתן לשחרר גם בלי להשלים את החישוב.
abstract class FastSha256Sink extends ByteConversionSink {
  /// משחרר את המשאבים בלי להפיק digest; חובה לקרוא לו ב-`finally` של הקורא,
  /// כי במסלול הנייטיבי החוצץ ואובייקט ה-hash אינם מוכרים לאיסוף האשפה.
  void dispose();
}

/// אוסף את ה-[Digest] מ-sink מוזרם.
class Sha256DigestCollector implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
