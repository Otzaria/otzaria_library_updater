import 'dart:async';

/// מריץ הורדות של **קבצים שונים** במקביל, עד [maxConcurrent] בכל רגע.
///
/// החנק של ה-CDN הוא לכל חיבור, ולכן גם ריבוי קבצים מאיץ (קובץ גדול גם
/// מתפצל לטווחים ב-`PatchDownloader`). המופע הוא סמפור משותף לכמה קוראים.
class DownloadScheduler {
  DownloadScheduler({int maxConcurrent = defaultMaxConcurrent})
      : maxConcurrent = maxConcurrent < 1 ? 1 : maxConcurrent;

  /// כל הורדה מחזיקה חוצץ כתיבה של 4MB, וכונן נייד איטי הוא היעד.
  static const int defaultMaxConcurrent = 4;

  final int maxConcurrent;

  int _active = 0;
  final List<Completer<void>> _waiting = <Completer<void>>[];

  /// כמה הורדות רצות ברגע זה — לבדיקות ולניפוי.
  int get activeCount => _active;

  /// מריץ את [tasks] ומחזיר את התוצאות בסדר שבו נמסרו. כישלון עוצר את התחלת
  /// המשימות הבאות, ממתין לאלה שכבר רצות, וזורק את השגיאה הראשונה.
  Future<List<T>> run<T>(List<Future<T> Function()> tasks) async {
    if (tasks.isEmpty) return const [];

    final results = List<T?>.filled(tasks.length, null);
    Object? firstError;
    StackTrace? firstStack;

    Future<void> runOne(int index) async {
      await _acquire();
      try {
        if (firstError != null) return;
        results[index] = await tasks[index]();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      } finally {
        _release();
      }
    }

    await Future.wait([for (var i = 0; i < tasks.length; i++) runOne(i)]);

    final error = firstError;
    if (error != null) Error.throwWithStackTrace(error, firstStack!);
    return [for (final value in results) value as T];
  }

  Future<void> _acquire() async {
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    final gate = Completer<void>();
    _waiting.add(gate);
    // מי שמשחרר מעביר את המשבצת ישירות, ולכן אין כאן `_active++`.
    await gate.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
      return;
    }
    _active--;
  }
}

/// מאחד את דיווחי הבייטים של כמה הורדות מקבילות למונה אחד. בייטים שכבר על
/// הדיסק אינם נספרים — לא במונה ולא ביעד ([ByteProgressSlot.markExisting]).
class ByteProgressAggregator {
  ByteProgressAggregator({this.totalBytes, this.onProgress});

  /// סכום הגדלים הידוע מראש, לפני ניכוי מה שכבר על הדיסק; null = לא ידוע.
  final int? totalBytes;

  final void Function(int downloaded, int? total)? onProgress;

  final List<int> _received = <int>[];
  final List<int?> _totals = <int?>[];
  final List<int> _existing = <int>[];
  int _sum = 0;

  /// הבייטים שנצברו עד כה בכל המשבצות.
  int get receivedBytes => _sum;

  /// מוסר את היעד המתוכנן לפני הבייט הראשון.
  void announce() => _emit();

  /// סינק התקדמות להורדה בודדת; [existingBytes] — מה שכבר על הדיסק לפניה.
  ByteProgressSlot slot({int existingBytes = 0}) {
    _received.add(0);
    _totals.add(null);
    _existing.add(existingBytes < 0 ? 0 : existingBytes);
    return ByteProgressSlot._(this, _received.length - 1);
  }

  void _report(int index, int downloaded, int? total) {
    // שיא ולא ערך אחרון: קובץ שלם מדווח את גודלו ואז מאמת מאפס.
    if (downloaded > _received[index]) {
      _received[index] = downloaded;
      _resum();
    }
    if (total != null) _totals[index] = total;
    _emit();
  }

  void _markExisting(int index, int bytes) {
    final value = bytes < 0 ? 0 : bytes;
    final received = _received[index] > value ? value : _received[index];
    if (_existing[index] == value && _received[index] == received) return;
    _existing[index] = value;
    _received[index] = received;
    _resum();
    _emit();
  }

  void _resum() {
    var sum = 0;
    for (var i = 0; i < _received.length; i++) {
      final net = _received[i] - _existing[i];
      if (net > 0) sum += net;
    }
    _sum = sum;
  }

  void _emit() => onProgress?.call(_sum, knownTotal());

  /// הסכום הכולל שידוע כרגע, או null כשעדיין אי אפשר לדעת אותו.
  int? knownTotal() {
    final planned = totalBytes;
    var total = 0;
    if (planned == null) {
      for (var i = 0; i < _totals.length; i++) {
        final value = _totals[i];
        if (value == null) return null;
        final net = value - _existing[i];
        if (net > 0) total += net;
      }
    } else {
      total = planned;
      for (final existing in _existing) {
        total -= existing;
      }
      if (total < 0) total = 0;
    }
    // נכס שגודלו לא היה ידוע יכול לחרוג מהאומדן; עדיף אומדן שגדל על 120%.
    return total < _sum ? _sum : total;
  }
}

/// המשבצת של הורדה בודדת בתוך [ByteProgressAggregator].
class ByteProgressSlot {
  ByteProgressSlot._(this._owner, this._index);

  final ByteProgressAggregator _owner;
  final int _index;

  void report(int downloaded, int? total) =>
      _owner._report(_index, downloaded, total);

  /// כמה מהבייטים המדווחים כבר היו על הדיסק. מחליף ולא מצטבר: תחילית שנזרקה
  /// חוזרת ל-0.
  void markExisting(int bytes) => _owner._markExisting(_index, bytes);
}
