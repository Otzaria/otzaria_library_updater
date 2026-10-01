import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models/delta_manifest.dart';
import '../models/library_release.dart';
import '../models/split_asset.dart';

/// נזרק כשהורדה או אימות נכשלים. הקבצים הפגומים נמחקים לפני הזריקה.
class PatchDownloadException implements Exception {
  final String message;
  const PatchDownloadException(this.message);
  @override
  String toString() => 'PatchDownloadException: $message';
}

/// נזרק כשהמשתמש ביטל את ההורדה.
class PatchDownloadCancelled implements Exception {
  const PatchDownloadCancelled();
}

/// נזרק כשהחיבור לרשת נקטע וגם הניסיונות החוזרים האוטומטיים לא הצליחו.
/// קובץ חלקי ניתן-לחידוש נשמר, כך שקריאה חוזרת ממשיכה מהנקודה שנעצרה.
///
/// אינו יורש מ-[PatchDownloadException]: צרכנים ותיקים משתמשים בטיפוס ההוא
/// לזיהוי נכס פגום ומוחקים בעקבותיו את הקובץ, בעוד שכשל רשת חייב לשמור partial.
class PatchNetworkException implements Exception {
  final Object cause;
  final String message;
  const PatchNetworkException(this.cause)
      : message = 'החיבור לרשת נקטע במהלך ההורדה';
  @override
  String toString() => 'PatchNetworkException: $message ($cause)';
}

/// מוריד קובץ patch דחוס, מאמת sha256 וגודל (דחוס ומחולץ), ומחלץ ל-`.db`.
///
/// ה-patches קטנים (עד עשרות MB מחולצים), לכן ההורדה והחילוץ בזיכרון. אם
/// אימות נכשל — הקבצים נמחקים ונזרק [PatchDownloadException].
class PatchDownloader {
  /// חסם עליון על סבבי-המשך (206 קצר) בניסיון בודד. שרת ששולח מעט בייטים בכל
  /// סבב היה גורם לאלפי בקשות על קובץ 1.1GB; מעבר לחסם = כשל הניסיון.
  static const int _maxContinuationRounds = 32;

  final http.Client _httpClient;
  final bool _ownsClient;

  /// פונקציית חילוץ zstd — מוזרקת על-ידי הצרכן (החבילה אגנוסטית לפלטפורמה).
  final Future<Uint8List?> Function(Uint8List compressed) _decompress;
  final Duration connectTimeout;
  final Duration stallTimeout;

  /// ההשהיות בין ניסיונות חוזרים אוטומטיים אחרי קטיעת רשת (חיבור שנסגר,
  /// timeout). אורך הרשימה = מספר הניסיונות החוזרים; רשימה ריקה מבטלת אותם.
  final List<Duration> networkRetryDelays;

  static const List<Duration> defaultNetworkRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
  ];

  PatchDownloader({
    required Future<Uint8List?> Function(Uint8List compressed) decompress,
    http.Client? httpClient,
    this.connectTimeout = const Duration(seconds: 20),
    this.stallTimeout = const Duration(seconds: 30),
    this.networkRetryDelays = defaultNetworkRetryDelays,
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _decompress = decompress;

  /// כשל רשת חולף: החיבור נסגר/אופס, או שהזרם נעצר מעבר ל-timeout. שגיאות
  /// פרוטוקול/אימות (קוד HTTP, sha256, גודל) אינן חולפות ואינן מנוסות שוב.
  static bool isTransientNetworkError(Object error) =>
      error is PatchNetworkException ||
      error is SocketException ||
      error is HttpException ||
      error is HandshakeException ||
      error is TimeoutException ||
      error is http.ClientException;

  /// מוריד ומחלץ את [patchFile] מ-[downloadUrl] לתיקייה [destDir].
  /// מחזיר את הנתיב לקובץ ה-`.db` המחולץ והמאומת.
  ///
  /// [onVerifyProgress] מדווח על קידום אימות ה-sha256 של הקובץ המחולץ
  /// (בייטים שנקראו מתוך גודלו). במימוש הבסיסי האימות רץ בלי דיווח ביניים.
  Future<String> downloadAndExtract({
    required PatchFileEntry patchFile,
    required String downloadUrl,
    required Directory destDir,
    void Function(int downloaded, int? total)? onProgress,
    void Function(int bytesDone, int bytesTotal)? onVerifyProgress,
    bool Function()? isCancelled,
  }) async {
    if (!destDir.existsSync()) {
      destDir.createSync(recursive: true);
    }
    // שם הקובץ המחולץ: הסרת סיומת .zst
    final extractedName = patchFile.file.endsWith('.zst')
        ? patchFile.file.substring(0, patchFile.file.length - 4)
        : '${patchFile.file}.db';
    final extractedPath = p.join(destDir.path, extractedName);

    try {
      final download = await _download(
        downloadUrl,
        maxBytes: patchFile.size,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      final compressed = download.bytes;

      _verify(
        actual: compressed.length,
        expected: patchFile.size,
        label: 'גודל הקובץ הדחוס',
      );
      _verifyDigest(
        actual: download.digest,
        expected: patchFile.sha256,
        label: 'sha256 של הקובץ הדחוס',
      );

      _throwIfCancelled(isCancelled);

      final extracted = await _decompress(compressed);
      if (extracted == null || extracted.isEmpty) {
        throw const PatchDownloadException('חילוץ ה-patch נכשל או החזיר ריק');
      }

      _verify(
        actual: extracted.length,
        expected: patchFile.uncompressedSize,
        label: 'גודל הקובץ המחולץ',
      );

      // כתיבה לפני אימות ה-hash: ה-hash מחושב מהדיסק ב-isolate, בלי להעביר את
      // הבייטים דרך SendPort (העתקה שהייתה מכפילה את שיא הזיכרון).
      await File(extractedPath).writeAsBytes(extracted, flush: true);
      await _verifyFileHash(
        path: extractedPath,
        expected: patchFile.uncompressedSha256,
        label: 'sha256 של הקובץ המחולץ',
      );
      return extractedPath;
    } catch (_) {
      _deleteQuietly(extractedPath);
      rethrow;
    }
  }

  /// מוריד קובץ גדול ישירות לדיסק בזרימה (ללא טעינה ל-RAM) — ל-DB המלא
  /// (~1.1GB), עם תמיכה בחידוש הורדה (resume): קובץ חלקי קיים משמש כנקודת
  /// המשך דרך כותרת `Range`. מאמת sha256 אם [expectedSha256] סופק.
  ///
  /// קטיעת רשת (חיבור שנסגר, timeout) מנוסה שוב אוטומטית לפי
  /// [networkRetryDelays], בהמשך מהחלקי כשהוא ניתן-לחידוש ואחרת מאפס; כשגם
  /// הניסיונות נכשלו נזרק [PatchNetworkException].
  ///
  /// בהפרעה (ביטול/timeout/רשת) קובץ חלקי נשמר רק אם הוא באמת ניתן-לחידוש:
  /// יש טוקן **וגם** validator חזק בקובץ הצד (או שהקובץ כבר שלם). חלקי בלי
  /// validator אינו נאמן ואינו ניתן להמשך — הוא נמחק מיד (יחד עם קובץ הצד) כדי
  /// לא להשאיר עד 1.5GB תלויים על הדיסק שכלל ה-entry ימחק ממילא בריצה הבאה.
  /// קובץ נמחק גם כאשר אימות סופי נכשל (אורך שגוי או sha256 שגוי) — קובץ
  /// שלם-אך-פגום אסור שיישאר, אחרת הריצה הבאה "תמשיך" זבל.
  ///
  /// [resumeToken] הוא תנאי להמשך (resume): רק כשהוא אינו null נעשה שימוש בקובץ
  /// חלקי קיים כנקודת המשך. הטוקן נשמר בקובץ צד `<destPath>.resume` בתחילת הורדה,
  /// ונבדק בכניסה: אם קיים קובץ חלקי אך קובץ הצד חסר או תוכנו שונה מ-[resumeToken]
  /// — החלקי נמחק וההורדה מתחילה מאפס. כך נמנעים מ"פרנקנשטיין" (חלקי מגרסה N
  /// שממשיך עם בייטים מ-N+1) ומקובץ שלם ישן שעובר את בדיקת ה-alreadyComplete.
  /// כש-null אין זהות יציבה לנכס — כל קובץ קיים ב-[destPath] נמחק בכניסה וההורדה
  /// מתחילה מאפס (אין המשך על URL שתוכנו עלול להשתנות).
  ///
  /// הגנת ה"פרנקנשטיין" נשענת על שתי שכבות: הטוקן (מטא-דאטה בצד הלקוח) **וגם**
  /// If-Range/ETag (הייצוג בצד השרת). ה-ETag החזק שהגיע עם הבייטים נשמר בקובץ
  /// הצד; בכל בקשת המשך נשלח `If-Range: <etag>` יחד עם `Range`, כך שנכס שהוחלף
  /// באותו URL (גם בגודל זהה) מחזיר 200 וההורדה מתחילה מאפס — ולא תופרת בייטים
  /// מגרסאות שונות. כשלשרת אין ETag חזק אין validator: חלקי כזה אינו נאמן ונמחק
  /// (בכניסה וגם בהפרעה) כדי להתחיל מאפס בפעם הבאה.
  ///
  /// קובץ הצד חי ומת יחד עם הנתונים: הוא נמחק רק היכן ש-[destPath] עצמו נמחק
  /// (אי-התאמת טוקן, כשלי אימות, חריגת גודל). הורדה מוצלחת **אינה** מוחקת אותו —
  /// אחרת ביטול בזמן החילוץ אצל הצרכן היה משאיר קובץ שלם בלי קובץ צד, ובריצה
  /// הבאה כלל אי-ההתאמה מוחק 1.1GB לחינם. הצרכן שמוחק את הקובץ לאחר חילוץ מוצלח
  /// (או בכשל חילוץ) מנקה גם את קובץ הצד דרך [resumeSidecarPath].
  Future<void> downloadToFile({
    required String url,
    required String destPath,
    int? expectedSize,
    String? expectedSha256,
    String? resumeToken,
    void Function(int downloaded, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    // ביטול בכניסה חייב לקדום לכל שינוי (מחיקת קובץ קיים, כתיבת קובץ צד) ולכל
    // בקשת רשת — נזרק לפני ה-try כדי שניקוי ה-catch לא ימחק קובץ קיים.
    _throwIfCancelled(isCancelled);

    final file = File(destPath);
    final sidecarPath = resumeSidecarPath(destPath);

    try {
      // resume מותנה בטוקן: בלי טוקן אין זהות יציבה, ולכן כל קובץ קיים נמחק
      // וההורדה מאפס — אחרת חלקי ישן היה נתפר לנכס חדש על אותו URL (frankenfile).
      String? storedValidator;
      if (resumeToken == null) {
        _deleteRequired(
          destPath,
          'מחיקת קובץ קיים ללא זהות resume נכשלה — לא ניתן להמשיך בהורדה',
        );
        _deleteQuietly(sidecarPath);
      } else if (file.existsSync()) {
        // כבילת החלקי לגרסת הנכס — חלקי בלי טוקן תואם נזרק כדי למנוע frankenfile.
        final sidecar = _readSidecar(sidecarPath);
        if (sidecar?.token != resumeToken) {
          // מחיקה היא תנאי תקינות: כשל שקט היה כובל תוכן ישן לטוקן החדש.
          _deleteRequired(
            destPath,
            'מחיקת קובץ חלקי מגרסה קודמת נכשלה — לא ניתן להמשיך בהורדה',
          );
          _deleteQuietly(sidecarPath);
        } else {
          storedValidator = _strongEtag(sidecar?.etag);
        }
      }

      var offset = file.existsSync() ? file.lengthSync() : 0;

      // הקובץ החלקי כבר בגודל המלא (או גדול) — דילוג על ההורדה, ישר לאימות.
      final alreadyComplete = expectedSize != null && offset >= expectedSize;

      // חלקי (לא שלם) בלי validator שמור אינו נאמן: אי אפשר לשלוח If-Range שיכבול
      // את הבייטים לגרסת השרת, ולכן מוחקים ומתחילים מאפס (אינו שגיאה).
      if (!alreadyComplete && offset > 0 && storedValidator == null) {
        _deleteRequired(
          destPath,
          'מחיקת קובץ חלקי ללא validator נכשלה — לא ניתן להמשיך בהורדה',
        );
        offset = 0;
      }

      var downloaded = offset;
      Digest? streamDigest;
      // אחרי קטיעה אין טעם לקרוא ולגבות ב-hash את כל ה-partial לפני כל ניסיון
      // נוסף. במסלול retry מאמתים את הקובץ השלם פעם אחת בלבד לאחר ההצלחה.
      var retrying = false;
      if (!alreadyComplete) {
        final outcome = await _withNetworkRetry(
          () async {
            // ניסיון חוזר עשוי למצוא שהקטיעה הגיעה אחרי הבייט האחרון.
            if (expectedSize != null && offset >= expectedSize) {
              return (downloaded: offset, digest: null);
            }
            if (resumeToken != null) {
              _writeSidecar(sidecarPath, resumeToken, storedValidator);
            }
            return _streamToFile(
              url: url,
              file: file,
              offset: offset,
              expectedSize: expectedSize,
              computeHash: expectedSha256 != null && !retrying,
              validator: storedValidator,
              sidecarPath: resumeToken != null ? sidecarPath : null,
              resumeToken: resumeToken,
              onProgress: onProgress,
              isCancelled: isCancelled,
            );
          },
          isCancelled: isCancelled,
          // אחרי קטיעה ממשיכים מהחלקי רק כשהוא כבול ל-validator; אחרת מאפס.
          onRetry: () {
            retrying = true;
            if (_partialIsResumable(
                destPath, sidecarPath, expectedSize, resumeToken)) {
              storedValidator = _strongEtag(_readSidecar(sidecarPath)?.etag);
              offset = file.lengthSync();
              return;
            }
            if (file.existsSync()) {
              _deleteRequired(
                destPath,
                'מחיקת קובץ חלקי לפני ניסיון חוזר נכשלה — לא ניתן להמשיך בהורדה',
              );
            }
            storedValidator = null;
            offset = 0;
          },
        );
        downloaded = outcome.downloaded;
        streamDigest = outcome.digest;
      } else {
        // _streamToFile לא רץ ולא דיווח — מקדמים ל-100% כדי שהמד לא ייתקע בזמן
        // אימות ה-hash הארוך (>1GB) על מסלול הקובץ-שכבר-שלם.
        onProgress?.call(downloaded, downloaded);
      }

      if (expectedSize != null && downloaded != expectedSize) {
        _deleteQuietly(destPath);
        _deleteQuietly(sidecarPath);
        throw PatchDownloadException(
            'גודל ה-DB שהורד ($downloaded) אינו תואם לצפוי ($expectedSize)');
      }
      if (expectedSha256 != null) {
        // בלי retry ה-hash מחושב בזרימה. במסלול alreadyComplete או אחרי retry
        // קוראים את הקובץ המוגמר פעם אחת, במקום לקרוא כל partial בכל ניסיון.
        final actual = streamDigest?.toString() ??
            await _hashFileSha256InIsolate(destPath, isCancelled);
        if (actual != expectedSha256.toLowerCase()) {
          _deleteQuietly(destPath);
          _deleteQuietly(sidecarPath);
          throw const PatchDownloadException('sha256 של ה-DB המלא אינו תואם');
        }
      }
      // ביטול שהתרחש אחרי שכל הבייטים הגיעו — הקובץ שלם ונשמר (עם resumeToken);
      // הריצה הבאה תזהה alreadyComplete. עקביות: מאותת ביטול, לא הצלחה שקטה.
      _throwIfCancelled(isCancelled);
    } catch (_) {
      // חלקי נשמר להמשך רק אם הוא באמת ניתן-לחידוש: יש validator חזק בקובץ הצד
      // (או שהקובץ כבר שלם). אחרת כלל ה-entry ימחק אותו ממילא בריצה הבאה, והוא
      // רק תופס עד 1.5GB עד אז — מוחקים מיד.
      if (!_partialIsResumable(
          destPath, sidecarPath, expectedSize, resumeToken)) {
        _deleteQuietly(destPath);
        // קובץ הצד חי ומת עם הנתונים: נמחק רק אם הקובץ עצמו אכן נעלם.
        if (!file.existsSync()) _deleteQuietly(sidecarPath);
      }
      rethrow;
    }
  }

  /// נתיב קובץ הצד (`.resume`) של [destPath]. חשוף כדי שהצרכן שמוחק את הקובץ
  /// לאחר חילוץ מוצלח (או בכשל חילוץ) ינקה גם את קובץ הצד.
  static String resumeSidecarPath(String destPath) => '$destPath.resume';

  /// נתיב החלק [index] של ארכיון מפוצל שמורכב אל [destPath].
  static String splitPartPath(String destPath, int index) =>
      '$destPath.part-${index.toString().padLeft(3, '0')}';

  /// מוריד את [asset] אל [destPath]: קובץ יחיד דרך [downloadToFile] (עם
  /// ה-digest כ-sha256 צפוי), ונכס מפוצל דרך [downloadSplitToFile].
  Future<void> downloadReleaseAssetToFile({
    required ReleaseAsset asset,
    required String destPath,
    String? resumeToken,
    void Function(int downloaded, int? total)? onProgress,
    bool Function()? isCancelled,
  }) {
    final split = asset.split;
    if (split != null) {
      return downloadSplitToFile(
        split: split,
        destPath: destPath,
        resumeToken: resumeToken,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
    }
    final digest = asset.digest;
    return downloadToFile(
      url: asset.downloadUrl,
      destPath: destPath,
      expectedSize: asset.size > 0 ? asset.size : null,
      expectedSha256: digest != null && digest.startsWith('sha256:')
          ? digest.substring('sha256:'.length)
          : null,
      resumeToken: resumeToken,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// מוריד כל חלק דרך [downloadToFile] (resume ו-sha256 לכל חלק), מחבר אל
  /// [destPath] ומאמת את השלם; [resumeToken] כובל גם את הארכיון המחובר.
  Future<void> downloadSplitToFile({
    required SplitAsset split,
    required String destPath,
    String? resumeToken,
    void Function(int downloaded, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    _throwIfCancelled(isCancelled);
    final sidecarPath = resumeSidecarPath(destPath);
    final joinedToken =
        resumeToken == null ? null : '$resumeToken|joined:${split.sha256}';

    if (joinedToken != null &&
        _readSidecar(sidecarPath)?.token == joinedToken &&
        File(destPath).existsSync() &&
        File(destPath).lengthSync() == split.size) {
      onProgress?.call(split.size, split.size);
      if (await _hashFileSha256InIsolate(destPath, isCancelled) ==
          split.sha256) {
        _deleteSplitParts(destPath, from: 0);
        return;
      }
    }
    _deleteRequired(
      destPath,
      'מחיקת ארכיון קודם נכשלה — לא ניתן לחבר את חלקי ההורדה',
    );
    _deleteQuietly(sidecarPath);
    _deleteSplitParts(destPath, from: split.parts.length);

    var completed = 0;
    for (var i = 0; i < split.parts.length; i++) {
      final part = split.parts[i];
      final base = completed;
      await downloadToFile(
        url: part.downloadUrl,
        destPath: splitPartPath(destPath, i),
        expectedSize: part.size,
        expectedSha256: part.sha256,
        resumeToken: resumeToken == null
            ? null
            : '$resumeToken|${part.name}|${part.sha256}',
        onProgress: (downloaded, _) =>
            onProgress?.call(base + downloaded, split.size),
        isCancelled: isCancelled,
      );
      completed += part.size;
    }
    _throwIfCancelled(isCancelled);

    await _joinSplitParts(split, destPath);
    if (joinedToken != null) _writeSidecar(sidecarPath, joinedToken, null);
  }

  /// מצרף את החלקים ב-isolate נפרד (קריאה, sha256 וכתיבה של מאות MB).
  Future<void> _joinSplitParts(SplitAsset split, String destPath) =>
      _joinPartsInIsolate(
        [
          for (var i = 0; i < split.parts.length; i++)
            splitPartPath(destPath, i)
        ],
        destPath,
        split.size,
        split.sha256,
      );

  /// מוחק חלקים (ואת קבצי הצד שלהם) מהאינדקס [from] והלאה — שרידים של
  /// פיצול קודם שהיו בו יותר חלקים, או כל החלקים אחרי חיבור מוצלח.
  void _deleteSplitParts(String destPath, {required int from}) {
    final dir = Directory(p.dirname(destPath));
    if (!dir.existsSync()) return;
    final pattern = RegExp(
        '^${RegExp.escape(p.basename(destPath))}' r'\.part-(\d+)(\.resume)?$');
    try {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final match = pattern.firstMatch(p.basename(entity.path));
        if (match != null && int.parse(match.group(1)!) >= from) {
          _deleteQuietly(entity.path);
        }
      }
    } catch (_) {}
  }

  /// זורם את גוף התגובה אל [file], תוך המשך מ-[offset] בעזרת `Range`.
  /// מחזיר את גודל הקובץ הכולל שנכתב ואת ה-sha256 שחושב בזרימה (או null אם
  /// [computeHash] כבוי). שמירת חלקי בהפרעה נקבעת על-ידי [downloadToFile].
  Future<({int downloaded, Digest? digest})> _streamToFile({
    required String url,
    required File file,
    required int offset,
    int? expectedSize,
    bool computeHash = false,
    String? validator,
    String? sidecarPath,
    String? resumeToken,
    void Function(int downloaded, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    // כובל את הבייטים לגרסת השרת דרך קובץ הצד: נכתב ברגע שהם מגיעים כדי שהפרעה
    // תשאיר validator להמשך בריצה הבאה.
    void persistValidator(String? etag) {
      if (sidecarPath != null && resumeToken != null) {
        _writeSidecar(sidecarPath, resumeToken, etag);
      }
    }

    // עד 2 ניסיונות "מאפס": 206 שאינו תואם לבקשה, 416 שאינו מוכיח שלמות, שרת
    // שמתעלם מ-Range, קטע 206 באורך שגוי, או 206 בלי total ידוע — כולם מובילים
    // לניסיון חוזר מאפס בלי Range. המשך תקין של 206 קצר (subset לגיטימי לפי
    // RFC 9110 §15.3.7) אינו ניסיון-שגיאה: הוא ממשיך באותו ניסיון עד ה-total.
    var currentOffset = offset;
    for (var attempt = 0; attempt < 2; attempt++) {
      // hasher — נבנה פעם לכל ניסיון; רץ ברצף על התחילית ועל כל סבבי-ההמשך.
      // ה-hash של התחילית מחושב לפני שליחת הבקשה: ביטול/כשל-קריאה כאן אינם
      // משאירים תגובת HTTP פתוחה.
      _ChunkedDigestSink? digestSink;
      ByteConversionSink? hashInput;
      if (computeHash) {
        digestSink = _ChunkedDigestSink();
        hashInput = sha256.startChunkedConversion(digestSink);
        if (currentOffset > 0) {
          await for (final chunk in file.openRead(0, currentOffset)) {
            _throwIfCancelled(isCancelled);
            hashInput.add(chunk);
          }
        }
      }

      var roundOffset = currentOffset;
      var downloaded = currentOffset;
      var restart = false;
      // ה-total הראשון שדווח בסבב 206 — כל סבב המשך חייב לדווח את אותו total,
      // אחרת ('/40' ואז '/31') היה מתקבל קובץ קטוע כ"הצלחה". מתאפס לכל ניסיון.
      int? sessionTotal;
      var rounds = 0;

      // לולאת המשך: 206 קצר חוקי (downloaded < total) שולח Range נוסף עד ה-total.
      while (true) {
        _throwIfCancelled(isCancelled);
        // חסם קשיח על סבבי-המשך: שרת ששולח מעט בייטים בכל 206 היה מציף בבקשות.
        // חריגה = כשל הניסיון; החלקי (בייטים תקינים) נשמר והריצה הבאה תמשיך.
        if (rounds++ >= _maxContinuationRounds) {
          hashInput?.close();
          throw PatchDownloadException(
            'חידוש ההורדה חרג ממספר הסבבים המרבי ($_maxContinuationRounds): $url',
          );
        }
        final headers = <String, String>{'Accept': 'application/octet-stream'};
        if (roundOffset > 0) {
          headers['Range'] = 'bytes=$roundOffset-';
          // כובל את ההמשך לגרסת הנכס: אם הייצוג הוחלף השרת יחזיר 200 ולא 206.
          if (validator != null) headers['If-Range'] = validator;
        }
        final response = await _sendWithManualRedirects(url, headers);

        if (response.statusCode == 200) {
          // השרת התעלם מ-Range — גוף מלא מאפס (200 = משאב שלם בהגדרה).
          try {
            // הבייטים הישנים נמחקים לפני שמירת ה-validator החדש: קריסה בין
            // השניים הייתה משאירה בייטים ישנים כבולים ל-ETag חדש (frankenfile).
            if (file.existsSync()) {
              _deleteRequired(
                file.path,
                'מחיקת קובץ חלקי מייצוג קודם נכשלה — לא ניתן להמשיך בהורדה',
              );
            }
            validator = _strongEtag(response.headers['etag']);
            persistValidator(validator);
          } catch (_) {
            // התגובה כבר פתוחה — משחררים את החיבור לפני הפצת השגיאה.
            await _abandonBody(response);
            rethrow;
          }
          final responseLength = response.contentLength;
          if (expectedSize != null &&
              responseLength != null &&
              responseLength != expectedSize) {
            hashInput?.close();
            await _abandonBody(response);
            _deleteQuietly(file.path);
            if (sidecarPath != null) _deleteQuietly(sidecarPath);
            throw PatchDownloadException(
              'Content-Length של ההורדה ($responseLength) אינו תואם '
              'לגודל הצפוי ($expectedSize)',
            );
          }
          if (computeHash) {
            // ה-hasher הקודם כבר קיבל את התחילית הישנה; תגובת 200 היא גוף מלא
            // מאפס, ולכן סוגרים אותו לפני יצירת hasher חדש.
            hashInput?.close();
            digestSink = _ChunkedDigestSink();
            hashInput = sha256.startChunkedConversion(digestSink);
          }
          final outcome = await _consumeBody(
            response: response,
            file: file,
            resumeOffset: 0,
            // גם כשאין גודל מה-manifest, Content-Length הוא חוזה אורך של גוף
            // ה-200: הוא משמש כחסם כתיבה ולא רק כחיווי התקדמות.
            expectedSize: expectedSize ?? responseLength,
            overallTotal: expectedSize ?? responseLength,
            hashInput: hashInput,
            onProgress: onProgress,
            isCancelled: isCancelled,
          );
          downloaded = outcome.downloaded;
          hashInput?.close();
          if (responseLength != null && downloaded != responseLength) {
            _deleteQuietly(file.path);
            if (sidecarPath != null) _deleteQuietly(sidecarPath);
            throw PatchDownloadException(
              'גוף ההורדה נקטע: Content-Length הצהיר $responseLength בייטים, '
              'אך התקבלו $downloaded',
            );
          }
          _throwIfCancelled(isCancelled);
          return (downloaded: downloaded, digest: digestSink?.value);
        }

        if (response.statusCode == 416) {
          // 416 אינו הוכחה לשלמות: ייתכן שהחלקי המקומי גדול מהנכס המרוחק.
          // מקבלים כשלם רק אם ה-total ב-Content-Range תואם ל-offset (ולצפוי).
          final total =
              _parseUnsatisfiedRangeTotal(response.headers['content-range']);
          await _abandonBody(response);
          // 416 שסותר total שכבר דווח ב-206 קודם ('/40' ואז '*/21') אינו שלמות.
          final complete = roundOffset > 0 &&
              file.existsSync() &&
              file.lengthSync() == roundOffset &&
              total != null &&
              total == roundOffset &&
              (sessionTotal == null || total == sessionTotal) &&
              (expectedSize == null || total == expectedSize);
          if (complete) {
            hashInput?.close();
            _throwIfCancelled(isCancelled);
            return (downloaded: roundOffset, digest: digestSink?.value);
          }
          hashInput?.close();
          _throwIfCancelled(isCancelled);
          _deleteQuietly(file.path);
          restart = true;
          break;
        }

        if (response.statusCode != 206) {
          await _abandonBody(response);
          hashInput?.close();
          throw PatchDownloadException(
            'שגיאה בהורדה (${response.statusCode}): $url',
          );
        }

        // עקביות ה-validator לאורך סבבי 206. סבב ראשון (validator ריק) קובע את
        // ה-validator; סבב עם ETag ששונה מהמאומץ = ייצוג שהתחלף באמצע → restart.
        // סבב בלי ETag כש-validator קיים: If-Range כבר נשלח, אז 206 מוכיח התאמה.
        final roundEtag = _strongEtag(response.headers['etag']);
        if (validator == null) {
          if (roundEtag != null) {
            validator = roundEtag;
            try {
              persistValidator(roundEtag);
            } catch (_) {
              // כשל דיסק אחרי שהתגובה נפתחה — משחררים את החיבור לפני ההפצה.
              await _abandonBody(response);
              rethrow;
            }
          }
        } else if (roundEtag != null && roundEtag != validator) {
          await _abandonBody(response);
          hashInput?.close();
          _throwIfCancelled(isCancelled);
          _deleteQuietly(file.path);
          restart = true;
          break;
        }

        final range = _parseContentRange(response.headers['content-range']);

        // ה-total חייב להישאר עקבי לאורך סבבי-ההמשך. שרת שמשנה אותו באמצע
        // (למשל '/40' ואז '/31') אינו אמין → מוחקים ומתחילים מאפס.
        if (range?.total != null) {
          sessionTotal ??= range!.total;
          if (range!.total != sessionTotal) {
            await _abandonBody(response);
            hashInput?.close();
            _throwIfCancelled(isCancelled);
            _deleteQuietly(file.path);
            restart = true;
            break;
          }
        }

        final validRange = range != null &&
            range.start == roundOffset &&
            range.end >= range.start &&
            (range.total == null || range.end < range.total!) &&
            (expectedSize == null || range.total == expectedSize) &&
            (response.contentLength == null ||
                response.contentLength == range.end - range.start + 1);
        if (!validRange) {
          await _abandonBody(response);
          hashInput?.close();
          _throwIfCancelled(isCancelled);
          restart = true;
          break;
        }

        final expectedRoundBytes = range.end - range.start + 1;
        final outcome = await _consumeBody(
          response: response,
          file: file,
          resumeOffset: roundOffset,
          expectedSize: expectedSize,
          // מד ההתקדמות חייב לשקף את הגודל הכולל, לא את גודל הסבב הנוכחי, אחרת
          // הורדה רב-סבבית הייתה מדווחת 100% מוקדם. עדיפות: expectedSize→total.
          overallTotal: expectedSize ?? sessionTotal,
          // חסם כתיבה פר-סבב: שרת שחורג מהטווח שהצהיר נעצר מיד, לא אחרי GB.
          maxRoundBytes: expectedRoundBytes,
          hashInput: hashInput,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
        downloaded = outcome.downloaded;

        // אורך הגוף חייב להיות בדיוק end-start+1 — גם כש-Content-Length חסר.
        // חוסר התאמה = קטע לא אמין → מוחקים ומתחילים מאפס.
        if (outcome.overrun || downloaded - roundOffset != expectedRoundBytes) {
          hashInput?.close();
          _throwIfCancelled(isCancelled);
          _deleteQuietly(file.path);
          restart = true;
          break;
        }

        // ללא total ידוע (206 עם `*` ו-expectedSize חסר) אי אפשר לאשר שלמות —
        // 206 בודד אינו מוכיח שהנכס הושלם; מתחילים מאפס (GET מלא → 200).
        final knownTotal = range.total;
        if (knownTotal == null) {
          hashInput?.close();
          _throwIfCancelled(isCancelled);
          _deleteQuietly(file.path);
          restart = true;
          break;
        }
        if (downloaded >= knownTotal) {
          hashInput?.close();
          _throwIfCancelled(isCancelled);
          return (downloaded: downloaded, digest: digestSink?.value);
        }
        // 206 קצר חוקי — סבב המשך. חייב להתקדם, אחרת נעצור כדי לא להיתקע.
        if (downloaded <= roundOffset) {
          hashInput?.close();
          throw PatchDownloadException('חידוש ההורדה לא התקדם: $url');
        }
        roundOffset = downloaded;
      }

      if (restart) {
        // התחלה מאפס = משיכת ייצוג טרי; ה-validator ייקבע מחדש מהתגובה הבאה.
        // הבייטים הישנים נמחקים כאן (לכל מסלולי ה-restart, כולל invalidRange) —
        // אחרת persistValidator של הניסיון הבא היה כובל בייטים ישנים ל-ETag חדש.
        if (file.existsSync()) {
          _deleteRequired(
            file.path,
            'מחיקת קובץ חלקי לפני ניסיון חוזר נכשלה — לא ניתן להמשיך בהורדה',
          );
        }
        currentOffset = 0;
        validator = null;
        continue;
      }
    }
    throw PatchDownloadException('חידוש ההורדה נכשל לאחר ניסיון חוזר: $url');
  }

  /// נוטש מיד את גוף התגובה במסלולי שגיאה של הנכס (1.5GB): מבטל את המנוי לזרם
  /// בלי לרוקן אותו, אחרת שרת שממשיך לשדר היה מזרים את כל הנכס רק כדי לדווח כשל
  /// מקומי. אובדן שימוש-חוזר בחיבור נסבל במסלול שגיאה.
  Future<void> _abandonBody(http.StreamedResponse response) async {
    try {
      await response.stream.listen((_) {}).cancel();
    } catch (_) {}
  }

  /// כותב את גוף התגובה לקובץ מ-[resumeOffset] ומחזיר את הגודל הכולל שנכתב,
  /// עם דגל `overrun` כשהגוף חרג מ-[maxRoundBytes] (נעצר לפני הכתיבה החורגת).
  /// ה-hasher (אם קיים) כבר הוזן בתחילית ע"י [_streamToFile]; כאן מוסיפים רק
  /// את בייטי הזרם ולא סוגרים אותו — הסגירה נעשית ב-[_streamToFile] אחרי
  /// שכל סבבי-ההמשך הסתיימו.
  Future<({int downloaded, bool overrun})> _consumeBody({
    required http.StreamedResponse response,
    required File file,
    required int resumeOffset,
    int? expectedSize,
    int? overallTotal,
    int? maxRoundBytes,
    ByteConversionSink? hashInput,
    void Function(int downloaded, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final append = resumeOffset > 0;

    final sink =
        file.openWrite(mode: append ? FileMode.append : FileMode.write);
    // גודל כולל למד ההתקדמות: המחשב ([overallTotal]) גובר על אומדן-הסבב, שאינו
    // נכון בהורדה רב-סבבית. נופלים לאומדן-הסבב רק כשאין total מחושב.
    final total = overallTotal ??
        (response.contentLength == null
            ? null
            : resumeOffset + response.contentLength!);
    var downloaded = resumeOffset;
    // סגירה שקטה — רק במסלול שגיאה/ביטול, כדי לא להסתיר את החריגה המקורית
    // ולשחרר את ה-handle (ב-Windows handle פתוח חוסם מחיקה/resume).
    var closed = false;
    Future<void> closeQuietly() async {
      if (closed) return;
      closed = true;
      try {
        await sink.close();
      } catch (_) {}
    }

    var overrun = false;
    try {
      await for (final chunk in response.stream.timeout(stallTimeout)) {
        _throwIfCancelled(isCancelled);
        // חריגה מהגודל הצפוי = נתונים שגויים — מוחקים וזורקים.
        if (expectedSize != null && downloaded + chunk.length > expectedSize) {
          await closeQuietly();
          _deleteQuietly(file.path);
          _deleteQuietly(resumeSidecarPath(file.path));
          throw PatchDownloadException(
              'ההורדה חורגת מהגודל הצפוי ($expectedSize בייטים)');
        }
        // גוף שחורג מהטווח שהוצהר ב-Content-Range נעצר לפני הכתיבה — בלי זה
        // שרת עוין/תקול היה כותב בלי גבול; ה-break מבטל את המנוי לזרם.
        if (maxRoundBytes != null &&
            (downloaded - resumeOffset) + chunk.length > maxRoundBytes) {
          overrun = true;
          break;
        }
        sink.add(chunk);
        hashInput?.add(chunk);
        downloaded += chunk.length;
        onProgress?.call(downloaded, total);
      }
      // ביטול שהתרחש ב-onProgress של הצ'אנק האחרון — הלולאה מסתיימת בלי בדיקה,
      // ולכן בודקים כאן כדי לא לחזור בהצלחה שקטה אחרי ביטול.
      _throwIfCancelled(isCancelled);
    } catch (_) {
      await closeQuietly();
      rethrow;
    }
    // מסלול הצלחה: flush/close חייבים להפיץ שגיאה (דיסק מלא / כשל IO). כישלון
    // כאן משאיר קובץ שאורכו מלא אך תוכנו פגום, שהיה עובר alreadyComplete בריצה
    // הבאה — לכן מוחקים קובץ+צד לפני הזריקה.
    try {
      await sink.flush();
      await sink.close();
      closed = true;
    } catch (error) {
      // flush שנכשל משאיר sink פתוח — חובה לסגור לפני המחיקה, אחרת ב-Windows
      // המחיקה נכשלת בשקט והקובץ הפגום עובר alreadyComplete בריצה הבאה.
      await closeQuietly();
      _deleteQuietly(file.path);
      _deleteQuietly(resumeSidecarPath(file.path));
      throw PatchDownloadException('שמירת הקובץ שהורד לדיסק נכשלה: $error');
    }
    return (downloaded: downloaded, overrun: overrun);
  }

  /// עוקב אחר הפניות (3xx) ידנית — `package:http` משמיט את כל הכותרות (כולל
  /// `Range`) כשהוא עוקב אוטומטית, וכתובות GitHub Releases מפנות ל-objects.
  Future<http.StreamedResponse> _sendWithManualRedirects(
    String url,
    Map<String, String> headers,
  ) async {
    var uri = Uri.parse(url);
    const maxHops = 6;
    for (var hop = 0; hop <= maxHops; hop++) {
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers.addAll(headers);
      final response = await _httpClient.send(request).timeout(connectTimeout);
      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        if (location == null) return response; // ללא Location → יטופל כשגיאה
        // נטישה מיידית ולא drain: גוף redirect גדול/זורם היה מעכב את ההפניה
        // בלי גבול ומבזבז רוחב פס.
        await _abandonBody(response);
        uri = uri.resolve(location); // resolve תומך ב-Location יחסי
        continue;
      }
      return response;
    }
    throw PatchDownloadException('יותר מדי הפניות (redirects): $url');
  }

  bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  /// מפענח כותרת `Content-Range: bytes start-end/total` של תגובת 206.
  /// `total` עשוי להיות `*` לפי RFC 9110, ואז מוחזר null.
  ({int start, int end, int? total})? _parseContentRange(String? contentRange) {
    if (contentRange == null) return null;
    final match = RegExp(
      r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$',
      caseSensitive: false,
    ).firstMatch(contentRange);
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final totalText = match.group(3)!;
    final total = totalText == '*' ? null : int.tryParse(totalText);
    if (start == null || end == null || (totalText != '*' && total == null)) {
      return null;
    }
    return (start: start, end: end, total: total);
  }

  /// מפענח את ה-total מכותרת `Content-Range: bytes */N` של תגובת 416 (RFC 9110,
  /// case-insensitive). מחזיר null אם הכותרת חסרה או שאינה בפורמט הצפוי.
  int? _parseUnsatisfiedRangeTotal(String? contentRange) {
    if (contentRange == null) return null;
    // מעוגן (^...$) בדיוק כמו פענוח ה-206: כותרת עם זבל נלווה אינה הוכחת שלמות.
    final match = RegExp(r'^\s*bytes\s+\*/(\d+)\s*$', caseSensitive: false)
        .firstMatch(contentRange.trim());
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// חלקי ניתן-לחידוש רק אם קובץ הצד מחזיק validator חזק (אפשר לשלוח If-Range),
  /// או שהקובץ כבר שלם ([expectedSize] מולא). חלקי בלי validator שאינו שלם
  /// יימחק ממילא ע"י כלל ה-entry בריצה הבאה, ולכן אין ערך לשמור אותו.
  bool _partialIsResumable(
    String destPath,
    String sidecarPath,
    int? expectedSize,
    String? resumeToken,
  ) {
    // בלי טוקן, או עם sidecar שאינו תואם לו, כלל ה-entry ימחק את הקובץ ממילא.
    if (resumeToken == null) return false;
    // רץ מתוך catch — כשל מערכת-קבצים כאן אסור שיסתיר את החריגה המקורית.
    try {
      final file = File(destPath);
      if (!file.existsSync()) return false;
      final sidecar = _readSidecar(sidecarPath);
      if (sidecar?.token != resumeToken) return false;
      if (expectedSize != null && file.lengthSync() >= expectedSize) {
        return true;
      }
      return _strongEtag(sidecar?.etag) != null;
    } catch (_) {
      return false;
    }
  }

  /// קורא את קובץ הצד: שורה ראשונה = טוקן, שורה שנייה (אופציונלית) = ה-ETag
  /// החזק. מחזיר null אם חסר או שגיאה בקריאה.
  ({String token, String? etag})? _readSidecar(String sidecarPath) {
    try {
      final f = File(sidecarPath);
      if (!f.existsSync()) return null;
      final lines = f.readAsStringSync().split('\n');
      final etag = lines.length > 1 && lines[1].isNotEmpty ? lines[1] : null;
      return (token: lines.first, etag: etag);
    } catch (_) {
      return null;
    }
  }

  /// כותב את הטוקן (וה-ETag אם קיים) לקובץ הצד: טוקן בשורה הראשונה, ETag בשנייה.
  void _writeSidecar(String sidecarPath, String token, String? etag) {
    try {
      final content = etag == null ? token : '$token\n$etag';
      File(sidecarPath).writeAsStringSync(content, flush: true);
    } catch (error) {
      throw PatchDownloadException(
        'כתיבת קובץ הזהות להמשך ההורדה נכשלה ($sidecarPath): $error',
      );
    }
  }

  /// מחזיר את ה-ETag רק אם הוא חזק (ללא קידומת `W/`) — ETag חלש אינו שמיש עם
  /// If-Range, ולכן נחשב כאילו אין validator. גרשיים מיותרים/רווחים מנוקים.
  String? _strongEtag(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.startsWith('W/')) return null;
    return trimmed;
  }

  /// מוריד לזיכרון ומחשב את ה-sha256 תוך כדי הזרימה — צ'אנק-צ'אנק, כדי שלא
  /// יורץ hash על מערך של מאות MB בפעימה אחת על ה-isolate הראשי.
  Future<({Uint8List bytes, Digest digest})> _download(
    String url, {
    required int maxBytes,
    void Function(int downloaded, int? total)? onProgress,
    bool Function()? isCancelled,
  }) {
    // ה-patch קטן — קטיעת רשת פשוט מתחילה אותו מחדש (אין מה להמשיך).
    return _withNetworkRetry(
      () => _downloadOnce(
        url,
        maxBytes: maxBytes,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
      isCancelled: isCancelled,
    );
  }

  Future<({Uint8List bytes, Digest digest})> _downloadOnce(
    String url, {
    required int maxBytes,
    void Function(int downloaded, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final request = http.Request('GET', Uri.parse(url))
      ..headers['Accept'] = 'application/octet-stream';
    final response = await _httpClient.send(request).timeout(connectTimeout);
    if (response.statusCode != 200) {
      await _abandonBody(response);
      throw PatchDownloadException(
        'שגיאה בהורדה (${response.statusCode}): $url',
      );
    }
    final total = response.contentLength;
    final builder = BytesBuilder(copy: false);
    final digestSink = _ChunkedDigestSink();
    final hashInput = sha256.startChunkedConversion(digestSink);
    var downloaded = 0;
    await for (final chunk in response.stream.timeout(stallTimeout)) {
      _throwIfCancelled(isCancelled);
      // בדיקה לפני הצבירה — לא צוברים לזיכרון בייטים שחורגים מהגודל הצפוי.
      if (downloaded + chunk.length > maxBytes) {
        throw PatchDownloadException(
            'ההורדה חורגת מהגודל הצפוי ($maxBytes בייטים)');
      }
      builder.add(chunk);
      hashInput.add(chunk);
      downloaded += chunk.length;
      onProgress?.call(downloaded, total);
    }
    hashInput.close();
    return (bytes: builder.takeBytes(), digest: digestSink.value);
  }

  void _verify({
    required int actual,
    required int expected,
    required String label,
  }) {
    if (actual != expected) {
      throw PatchDownloadException(
          '$label אינו תואם: צפוי $expected, התקבל $actual');
    }
  }

  void _verifyDigest({
    required Digest actual,
    required String expected,
    required String label,
  }) {
    if (actual.toString() != expected.toLowerCase()) {
      throw PatchDownloadException('$label אינו תואם');
    }
  }

  /// מאמת sha256 של קובץ שעל הדיסק; החישוב רץ ב-isolate נפרד (בזרימה) כדי לא
  /// לחסום את ה-isolate הראשי, ומקבל נתיב בלבד — לא מערך בייטים.
  Future<void> _verifyFileHash({
    required String path,
    required String expected,
    required String label,
  }) async {
    final actual = await _hashFileSha256InIsolate(path);
    if (actual != expected.toLowerCase()) {
      throw PatchDownloadException('$label אינו תואם');
    }
  }

  void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled != null && isCancelled()) {
      throw const PatchDownloadCancelled();
    }
  }

  /// מריץ את [run] ומנסה שוב על כשל רשת חולף לפי [networkRetryDelays]. אחרי
  /// הניסיון האחרון הכשל נזרק כ-[PatchNetworkException]; שאר החריגות מופצות כפי
  /// שהן. [onRetry] רץ לפני כל ניסיון חוזר (לחישוב נקודת ההמשך).
  Future<T> _withNetworkRetry<T>(
    Future<T> Function() run, {
    bool Function()? isCancelled,
    FutureOr<void> Function()? onRetry,
  }) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await run();
      } catch (e) {
        if (e is PatchNetworkException) rethrow;
        if (!isTransientNetworkError(e)) rethrow;
        _throwIfCancelled(isCancelled);
        if (attempt >= networkRetryDelays.length) {
          throw PatchNetworkException(e);
        }
        await _waitBeforeRetry(networkRetryDelays[attempt], isCancelled);
        await onRetry?.call();
      }
    }
  }

  /// ממתין [delay] בפרוסות קצרות כדי שביטול יתפוס גם באמצע ההשהיה.
  Future<void> _waitBeforeRetry(
    Duration delay,
    bool Function()? isCancelled,
  ) async {
    const slice = Duration(milliseconds: 200);
    var remaining = delay;
    while (remaining > Duration.zero) {
      _throwIfCancelled(isCancelled);
      final step = remaining < slice ? remaining : slice;
      await Future<void>.delayed(step);
      remaining -= step;
    }
    _throwIfCancelled(isCancelled);
  }

  void _deleteQuietly(String path) => _deleteFileQuietly(path);

  /// מוחק קובץ שחייב להיעלם לפני שאפשר להמשיך בבטחה.
  void _deleteRequired(String path, String failureMessage) {
    final file = File(path);
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      if (!file.existsSync()) return;
      throw PatchDownloadException(failureMessage);
    }
    if (file.existsSync()) {
      throw PatchDownloadException(failureMessage);
    }
  }

  void dispose() {
    if (_ownsClient) _httpClient.close();
  }
}

/// sha256 של קובץ ב-isolate נפרד. [isCancelled] אינו עובר בין isolates, ולכן
/// נבדק כאן כל 100ms ומגיע ל-worker כהודעה; ביטול נזרק כ-[PatchDownloadCancelled].
Future<String> _hashFileSha256InIsolate(String path,
    [bool Function()? isCancelled]) async {
  if (isCancelled == null) return _runHashWorker(path, null);
  if (isCancelled()) throw const PatchDownloadCancelled();
  final control = ReceivePort();
  SendPort? workerCancel;
  var cancelled = false;
  control.listen((port) {
    workerCancel = port as SendPort;
    if (cancelled) workerCancel!.send(null);
  });
  final poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
    if (cancelled || !isCancelled()) return;
    cancelled = true;
    workerCancel?.send(null);
  });
  try {
    return await _runHashWorker(path, control.sendPort);
  } finally {
    poll.cancel();
    control.close();
  }
}

/// נפרד מ-[_hashFileSha256InIsolate] כדי שה-closure לא ילכוד את ה-ReceivePort.
Future<String> _runHashWorker(String path, SendPort? control) =>
    Isolate.run(() async {
      if (control == null) return _hashFileSha256(path);
      final cancel = ReceivePort();
      var cancelled = false;
      cancel.listen((_) => cancelled = true);
      control.send(cancel.sendPort);
      try {
        return await _hashFileSha256(path, () => cancelled);
      } finally {
        cancel.close();
      }
    });

/// מחשב sha256 של קובץ בזרימה (עשוי לעבור 1GB — לא readAsBytes). רץ רק בתוך
/// worker; מבחוץ קוראים ל-[_hashFileSha256InIsolate].
Future<String> _hashFileSha256(String path,
    [bool Function()? isCancelled]) async {
  final digestSink = _ChunkedDigestSink();
  final input = sha256.startChunkedConversion(digestSink);
  await for (final chunk in File(path).openRead()) {
    if (isCancelled != null && isCancelled()) {
      throw const PatchDownloadCancelled();
    }
    input.add(chunk);
  }
  input.close();
  return digestSink.value.toString();
}

/// top-level כדי שה-closure של `Isolate.run` לא ילכוד את ה-PatchDownloader.
Future<void> _joinPartsInIsolate(List<String> partPaths, String destPath,
        int expectedSize, String expectedSha256) =>
    Isolate.run(
        () => _joinParts(partPaths, destPath, expectedSize, expectedSha256));

/// מצרף לקובץ זמני, מוחק כל חלק אחרי צירופו, ומעביר ל-[destPath] רק אחרי
/// אימות. אינו נעצר בביטול: חיבור שנקטע היה מאבד את החלקים שכבר צורפו.
void _joinParts(List<String> partPaths, String destPath, int expectedSize,
    String expectedSha256) {
  final tempPath = '$destPath.joining';
  final digestSink = _ChunkedDigestSink();
  final hasher = sha256.startChunkedConversion(digestSink);
  var written = 0;
  try {
    final output = File(tempPath).openSync(mode: FileMode.writeOnly);
    try {
      for (final partPath in partPaths) {
        final input = File(partPath).openSync();
        try {
          for (var chunk = input.readSync(1 << 20);
              chunk.isNotEmpty;
              chunk = input.readSync(1 << 20)) {
            hasher.add(chunk);
            output.writeFromSync(chunk);
            written += chunk.length;
          }
        } finally {
          input.closeSync();
        }
        _deleteFileQuietly(partPath);
        _deleteFileQuietly(PatchDownloader.resumeSidecarPath(partPath));
      }
      output.flushSync();
    } finally {
      output.closeSync();
    }
    hasher.close();
    if (written != expectedSize) {
      throw PatchDownloadException(
          'גודל הארכיון המחובר ($written) אינו תואם לצפוי ($expectedSize)');
    }
    if (digestSink.value.toString() != expectedSha256) {
      throw const PatchDownloadException('sha256 של הארכיון המחובר אינו תואם');
    }
    File(tempPath).renameSync(destPath);
  } catch (_) {
    _deleteFileQuietly(tempPath);
    rethrow;
  }
}

void _deleteFileQuietly(String path) {
  try {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  } catch (_) {}
}

/// אוסף את ה-Digest מ-`startChunkedConversion` של sha256 — בכל המסלולים
/// הזורמים: הורדה לדיסק, הורדה לזיכרון, וחישוב מקובץ קיים.
class _ChunkedDigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
