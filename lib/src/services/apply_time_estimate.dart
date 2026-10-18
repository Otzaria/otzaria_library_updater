/// אומדן זמן העדכון במחשב שמתעדכן, לכל אחד משני המסלולים — פונקציה טהורה של
/// גודל הנכסים. הקבועים כוילו על מדידות אמיתיות; הפיזור בין מכונות פי 3–5.
///
/// | מסלול | נכס | נמדד | האומדן |
/// | --- | --- | --- | --- |
/// | מלא | 1.31GB דחוס | 129s / 581s | 262s |
/// | דלתא | patch 6.8MB | 133s / 734s | 337s |
/// | דלתא | patch 8.5MB | 214s / 790s / 1039s | 347s |
/// | דלתא | patch 585MB | 3,864s | 3,517s |
class ApplyTimeEstimate {
  const ApplyTimeEstimate({
    this.fullSecondsPerMb = 0.2,
    this.stepFixedSeconds = 300,
    this.stepIntermediateSeconds = 60,
    this.stepSecondsPerMb = 5.5,
    this.slowRouteRatio = 2.0,
    this.slowRouteMarginSeconds = 600,
    this.downloadSecondsPerMb = 0.5,
  });

  /// חילוץ ה-zstd וכתיבת המסד, לכל MB דחוס של ה-DB המלא.
  final double fullSecondsPerMb;

  /// סריקת ה-hash הלוגי על כל המסד — נגבה פעם אחת לשרשרת.
  final double stepFixedSeconds;

  /// מחיר קבוע לכל צעד ביניים בשרשרת. אומדן, לא נמדד.
  final double stepIntermediateSeconds;

  /// חילוץ ה-patch והחלתו, לכל MB דחוס.
  final double stepSecondsPerMb;

  /// פי כמה מסלול הדלתא רשאי להיות איטי מהמלא לפני שהוא מפסיד.
  final double slowRouteRatio;

  /// ההפרש המוחלט שמתחתיו מסלול הדלתא אינו מפסיד.
  final double slowRouteMarginSeconds;

  /// שווי שנייה-הורדה לכל MB שנחסך (~2MB/s אגרגטי של GitHub).
  final double downloadSecondsPerMb;

  static const int _mb = 1 << 20;

  double fullRouteSeconds(int compressedBytes) =>
      (compressedBytes / _mb) * fullSecondsPerMb;

  /// מחיר קבוע מלא פעם אחת, מחיר ביניים לכל צעד נוסף, וחלק לפי הגודל.
  double deltaRouteSeconds(Iterable<int> stepCompressedBytes) {
    var seconds = 0.0;
    var first = true;
    for (final bytes in stepCompressedBytes) {
      seconds += (first ? stepFixedSeconds : stepIntermediateSeconds) +
          (bytes / _mb) * stepSecondsPerMb;
      first = false;
    }
    return seconds;
  }

  /// עלות צעד בשרשרת שנבנית בהדרגה; ההפרש עד המחיר הקבוע המלא נוסף פעם אחת
  /// דרך [chainStartExtraSeconds].
  double intermediateStepSeconds(int compressedBytes) =>
      stepIntermediateSeconds + (compressedBytes / _mb) * stepSecondsPerMb;

  double get chainStartExtraSeconds =>
      stepFixedSeconds - stepIntermediateSeconds;

  /// האם מסלול הדלתא איטי מהמלא גם ביחס וגם בהפרש מוחלט. [savedDownloadBytes]
  /// — הבייטים שהדלתא חוסכת בהורדה — מרחיבים את ההפרש הנדרש.
  bool isOutOfRange(
    double deltaSeconds,
    double fullSeconds, {
    int savedDownloadBytes = 0,
  }) {
    final saved = savedDownloadBytes < 0 ? 0 : savedDownloadBytes;
    final margin =
        slowRouteMarginSeconds + (saved / _mb) * downloadSecondsPerMb;
    return deltaSeconds > fullSeconds * slowRouteRatio &&
        deltaSeconds - fullSeconds >= margin;
  }

  /// דקות מעוגלות כלפי מעלה, להצגה — 0 דקות אינו זמן.
  static int minutesOf(double seconds) {
    final minutes = (seconds / 60).ceil();
    return minutes < 1 ? 1 : minutes;
  }
}
