import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import 'fast_sha256_native_stub.dart'
    if (dart.library.ffi) 'fast_sha256_native.dart';
import 'fast_sha256_sink.dart';

export 'fast_sha256_sink.dart' show FastSha256Sink;

/// SHA-256 מוזרם דרך ספריית ההצפנה של המערכת (CNG ב-Windows, CommonCrypto
/// ב-macOS וב-iOS), ובנפילה חזרה `package:crypto`. התוצאה זהה בית-בבית.
abstract final class FastSha256 {
  /// מכריח את מסלול `package:crypto` — לבדיקות בלבד.
  @visibleForTesting
  static bool useFallbackOnly = false;

  /// כמו `sha256.startChunkedConversion`; הקורא חייב לקרוא ל-
  /// [FastSha256Sink.dispose] ב-`finally`.
  static FastSha256Sink start(Sink<Digest> output) {
    final native = useFallbackOnly ? null : startNativeSha256(output);
    return native ?? _FallbackSha256Sink(sha256.startChunkedConversion(output));
  }

  /// חישוב חד-פעמי על מטען שכבר בזיכרון, כמו `sha256.convert`.
  static Digest convert(List<int> bytes) {
    final collector = Sha256DigestCollector();
    final sink = start(collector);
    try {
      sink
        ..add(bytes)
        ..close();
    } finally {
      sink.dispose();
    }
    return collector.value;
  }

  /// האם המסלול הנייטיבי זמין בסביבה הזו (לבדיקות ולאבחון).
  static bool get isNativeAvailable => isNativeSha256Available;
}

/// [dispose] הוא ביטול גם כאן, כדי שמסלול שגיאה יתנהג זהה בכל פלטפורמה.
class _FallbackSha256Sink extends FastSha256Sink {
  _FallbackSha256Sink(this._inner);

  final ByteConversionSink _inner;
  bool _closed = false;
  bool _released = false;

  @override
  void add(List<int> chunk) => addSlice(chunk, 0, chunk.length, false);

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {
    if (_released || _closed) {
      throw StateError('FastSha256 sink: add after close');
    }
    _inner.addSlice(chunk, start, end, isLast);
    if (isLast) _closed = true;
  }

  @override
  void close() {
    if (_closed) return;
    if (_released) throw StateError('FastSha256 sink: close after dispose');
    _closed = true;
    _inner.close();
  }

  @override
  void dispose() => _released = true;
}

/// SHA-256 מוזרם שמחזיר hex, מעל [FastSha256]. [dispose] חובה ב-`finally`.
class Sha256Stream {
  Sha256Stream() {
    _sink = FastSha256.start(_collector);
  }

  final Sha256DigestCollector _collector = Sha256DigestCollector();
  late final FastSha256Sink _sink;
  String? _hex;

  void add(List<int> chunk) => _sink.add(chunk);

  /// מזרים רק את `[start, end)` — לחוצץ שנעשה בו שימוש חוזר.
  void addSlice(List<int> chunk, int start, int end) =>
      _sink.addSlice(chunk, start, end, false);

  /// ה-hex הסופי; קריאות נוספות מחזירות אותו ערך.
  String close() {
    if (_hex case final done?) return done;
    _sink.close();
    return _hex = _collector.value.toString();
  }

  void dispose() => _sink.dispose();

  static String ofBytes(List<int> bytes) =>
      FastSha256.convert(bytes).toString();
}
