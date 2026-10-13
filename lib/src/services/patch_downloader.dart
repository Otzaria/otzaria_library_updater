import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../hashing/fast_sha256.dart';
import '../hashing/fast_sha256_sink.dart';
import '../messages/library_updater_messages.dart';
import '../models/delta_manifest.dart';
import '../models/library_release.dart';
import '../models/split_asset.dart';

part 'patch_downloader_segmented.dart';

/// נזרק כשהורדה או אימות נכשלים. הקבצים הפגומים נמחקים לפני הזריקה.
class PatchDownloadException implements Exception {
  final String message;
  const PatchDownloadException(this.message);
  @override
  String toString() => message;
}

/// נזרק כשהמשתמש ביטל את ההורדה.
class PatchDownloadCancelled implements Exception {
  const PatchDownloadCancelled();
}

/// נזרק כשהחיבור לרשת נקטע וגם הניסיונות החוזרים לא הצליחו. קובץ חלקי
/// ניתן-לחידוש נשמר; אינו [PatchDownloadException] כי זה אינו נכס פגום.
class PatchNetworkException implements Exception {
  final Object cause;
  const PatchNetworkException(this.cause);
  String get message => LibraryUpdaterMessages.current.networkInterrupted;
  @override
  String toString() => 'PatchNetworkException: $message ($cause)';
}

/// מוריד קובצי patch ו-DB מלא, מאמת sha256 וגודל, ומחלץ patch ל-`.db`.
///
/// [downloadToFile] ו-[downloadAndExtract] מקבלים גם נתיב מקומי במקום URL
/// (מראה offline) — ראו [isRemoteUrl].
class PatchDownloader {
  /// חסם עליון על סבבי-המשך (206 קצר) בניסיון בודד.
  static const int _maxContinuationRounds = 32;

  /// `IOSink.add` אינו מפעיל לחץ-נגד; בלי flush תקופתי ההפרש בין רשת מהירה
  /// ליעד איטי (כונן נייד) נערם ב-RAM.
  static const int _writeBufferBytes = 4 << 20;

  final http.Client _httpClient;
  final bool _ownsClient;

  /// פונקציית חילוץ zstd — מוזרקת על-ידי הצרכן (החבילה אגנוסטית לפלטפורמה).
  final Future<Uint8List?> Function(Uint8List compressed) _decompress;

  /// ניתנים לשינוי בזמן ריצה — נכנסים לתוקף בבקשה הבאה.
  Duration connectTimeout;
  Duration stallTimeout;

  /// ההשהיות בין ניסיונות חוזרים אחרי קטיעת רשת; רשימה ריקה מבטלת אותם.
  final List<Duration> networkRetryDelays;

  static const List<Duration> defaultNetworkRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
  ];

  /// מספר החיבורים המקבילים לקובץ גדול ב-[downloadToFile]; 1 מבטל את הפיצול.
  final int maxConnections;

  /// קובץ מרוחק בגודל צפוי זה ומעלה יורד ב-[maxConnections] טווחים.
  final int segmentThresholdBytes;

  static const int defaultMaxConnections = 4;
  static const int defaultSegmentThresholdBytes = 64 << 20;

  PatchDownloader({
    required Future<Uint8List?> Function(Uint8List compressed) decompress,
    http.Client? httpClient,
    this.connectTimeout = const Duration(seconds: 20),
    this.stallTimeout = const Duration(seconds: 30),
    this.networkRetryDelays = defaultNetworkRetryDelays,
    this.maxConnections = defaultMaxConnections,
    this.segmentThresholdBytes = defaultSegmentThresholdBytes,
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _decompress = decompress;

  /// כשל רשת חולף: החיבור נסגר/אופס, או שהזרם נעצר מעבר ל-timeout.
  static bool isTransientNetworkError(Object error) =>
      error is PatchNetworkException ||
      error is SocketException ||
      error is HttpException ||
      error is HandshakeException ||
      error is TimeoutException ||
      error is http.ClientException;

  /// `true` לכתובת HTTP/HTTPS; `false` לנתיב קובץ מקומי (מראה offline).
  static bool isRemoteUrl(String url) =>
      url.startsWith('http://') || url.startsWith('https://');

  /// מוריד ומחלץ את [patchFile] מ-[downloadUrl] לתיקייה [destDir] ומחזיר את
  /// נתיב ה-`.db` המאומת. [onVerifyProgress] — אימות ה-sha256 של המחולץ.
  Future<String> downloadAndExtract({
    required PatchFileEntry patchFile,
    required String downloadUrl,
    required Directory destDir,
    void Function(int downloaded, int? total)? onProgress,
    void Function(int bytesDone, int bytesTotal)? onVerifyProgress,
    bool Function()? isCancelled,
  }) async {
    final messages = LibraryUpdaterMessages.current;
    if (!destDir.existsSync()) {
      destDir.createSync(recursive: true);
    }
    final extractedName = patchFile.file.endsWith('.zst')
        ? patchFile.file.substring(0, patchFile.file.length - 4)
        : '${patchFile.file}.db';
    final extractedPath = p.join(destDir.path, extractedName);
    if (!p.isWithin(destDir.path, extractedPath)) {
      throw PatchDownloadException(messages.manifestMissingField('file'));
    }

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
        label: messages.compressedFileSizeLabel,
      );
      _verifyDigest(
        actual: download.digest,
        expected: patchFile.sha256,
        label: messages.compressedFileHashLabel,
      );

      _throwIfCancelled(isCancelled);

      final extracted = await _decompress(compressed);
      if (extracted == null || extracted.isEmpty) {
        throw PatchDownloadException(messages.patchExtractionFailed);
      }

      _verify(
        actual: extracted.length,
        expected: patchFile.uncompressedSize,
        label: messages.extractedFileSizeLabel,
      );

      // ה-hash מחושב מהדיסק ב-isolate, בלי להעתיק את הבייטים דרך SendPort.
      await File(extractedPath).writeAsBytes(extracted, flush: true);
      await _verifyFileHash(
        path: extractedPath,
        expected: patchFile.uncompressedSha256,
        label: messages.extractedFileHashLabel,
        onVerifyProgress: onVerifyProgress,
      );
      return extractedPath;
    } catch (_) {
      _deleteQuietly(extractedPath);
      rethrow;
    }
  }

  /// מוריד קובץ גדול לדיסק בזרימה, עם resume, אימות sha256 וניסיונות חוזרים
  /// אחרי קטיעת רשת ([networkRetryDelays]).
  ///
  /// [resumeToken] כובל קובץ חלקי לגרסת הנכס דרך `<destPath>.resume` (טוקן,
  /// ETag חזק לשליחת If-Range, וסימון אימות `sha256|גודל|זמן-שינוי`). חלקי
  /// בלי טוקן תואם נמחק, אלא אם הוא שלם ובאותו sha256 — אז הוא נקשר לטוקן
  /// החדש. נכס שלם שסימון האימות שלו תואם אינו מגובב שוב; נכס שלם ופגום
  /// יורד מחדש. קובץ הצד נמחק רק יחד עם הקובץ עצמו — הצרכן שמוחק את הקובץ
  /// אחרי חילוץ מנקה אותו דרך [resumeSidecarPath].
  ///
  /// קובץ מרוחק מ-[segmentThresholdBytes] ומעלה יורד בכמה טווחים מקבילים
  /// כשהשרת מכבד `Range` — ראו [_downloadSegmented].
  ///
  /// [onExistingBytes] — כמה מהקובץ כבר על הדיסק ואינו עובר ברשת (0 כשנמחק).
  /// [onVerifyProgress] — קריאת קובץ שכבר על הדיסק לצורך אימות.
  ///
  /// הורדה שנייה לאותו [destPath] בזמן שהראשונה רצה נכשלת מיד ב-
  /// [PatchDownloadException], בלי לגעת בקבצים (`<destPath>.lock`).
  Future<void> downloadToFile({
    required String url,
    required String destPath,
    int? expectedSize,
    String? expectedSha256,
    String? resumeToken,
    void Function(int downloaded, int? total)? onProgress,
    void Function(int verified, int total)? onVerifyProgress,
    void Function(int bytes)? onExistingBytes,
    bool Function()? isCancelled,
  }) async {
    // ביטול בכניסה קודם לכל שינוי בדיסק ולכל בקשת רשת.
    _throwIfCancelled(isCancelled);
    final lock = _DestinationLock.acquire(destPath);
    try {
      await _downloadToFileLocked(
        url: url,
        destPath: destPath,
        expectedSize: expectedSize,
        expectedSha256: expectedSha256,
        resumeToken: resumeToken,
        onProgress: onProgress,
        onVerifyProgress: onVerifyProgress,
        onExistingBytes: onExistingBytes,
        isCancelled: isCancelled,
      );
    } finally {
      lock.release();
    }
  }

  Future<void> _downloadToFileLocked({
    required String url,
    required String destPath,
    int? expectedSize,
    String? expectedSha256,
    String? resumeToken,
    void Function(int downloaded, int? total)? onProgress,
    void Function(int verified, int total)? onVerifyProgress,
    void Function(int bytes)? onExistingBytes,
    bool Function()? isCancelled,
  }) async {
    final messages = LibraryUpdaterMessages.current;

    if (!isRemoteUrl(url)) {
      await _copyLocalFile(
        url: url,
        destPath: destPath,
        expectedSize: expectedSize,
        expectedSha256: expectedSha256,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      return;
    }

    final file = File(destPath);
    final sidecarPath = resumeSidecarPath(destPath);
    // ביטול באמצע ה-hash של האימוץ אינו סיבה למחוק קובץ שלא נגענו בו.
    var adopting = false;

    try {
      String? storedValidator;
      String? storedVerified;
      if (resumeToken == null) {
        _deleteRequired(
          destPath,
          messages.deleteExistingWithoutResumeIdentityFailed,
        );
        _deleteQuietly(sidecarPath);
      } else if (file.existsSync()) {
        final sidecar = _readSidecar(sidecarPath);
        adopting = sidecar?.token != resumeToken;
        final adopted = !adopting
            ? null
            : await _adoptSameContent(
                file,
                sidecarPath,
                sidecar?.verified,
                resumeToken,
                expectedSize,
                expectedSha256,
                isCancelled,
                onVerifyProgress,
              );
        if (adopted != null) {
          adopting = false;
          storedVerified = adopted;
        } else if (adopting) {
          adopting = false;
          // כשל שקט היה כובל תוכן ישן לטוקן החדש (frankenfile).
          _deleteRequired(
            destPath,
            messages.deletePartialFromPreviousVersionFailed,
          );
          _deleteQuietly(sidecarPath);
        } else {
          storedValidator = _strongEtag(sidecar?.etag);
          storedVerified = sidecar?.verified;
        }
      }

      var offset = file.existsSync() ? file.lengthSync() : 0;
      final alreadyComplete = expectedSize != null && offset >= expectedSize;
      final segmented = _segmentationApplies(expectedSize);
      final resumedPlan = segmented && !alreadyComplete
          ? _readSegmentPlan(destPath, resumeToken, url, expectedSize!,
              expectedSha256?.toLowerCase())
          : null;
      if (resumedPlan == null) _deleteSegmentLeftovers(destPath);

      // חלקי בלי validator אינו נאמן: אין If-Range שיכבול אותו לגרסת השרת.
      if (!alreadyComplete &&
          offset > 0 &&
          storedValidator == null &&
          resumedPlan == null) {
        _deleteRequired(destPath, messages.deletePartialWithoutValidatorFailed);
        offset = 0;
      }

      if (offset > 0) onExistingBytes?.call(offset);
      if (alreadyComplete) {
        onProgress?.call(offset, offset);
        if (offset == expectedSize &&
            await _completeFileVerified(
              destPath,
              sidecarPath,
              resumeToken,
              expectedSha256,
              storedVerified,
              isCancelled,
              onVerifyProgress,
            )) {
          _throwIfCancelled(isCancelled);
          return;
        }
        _deleteRequired(destPath, messages.deletePartialBeforeRetryFailed);
        _deleteQuietly(sidecarPath);
        storedValidator = null;
        offset = 0;
        onExistingBytes?.call(0);
      }

      if (segmented) {
        final result = await _downloadSegmented(
          url: url,
          destPath: destPath,
          size: expectedSize!,
          sha256: expectedSha256?.toLowerCase(),
          resumeToken: resumeToken,
          resumed: resumedPlan,
          validator: storedValidator,
          onProgress: onProgress,
          onVerifyProgress: onVerifyProgress,
          onExistingBytes: onExistingBytes,
          isCancelled: isCancelled,
        );
        if (result.done) {
          _throwIfCancelled(isCancelled);
          return;
        }
        storedValidator = result.validator;
        offset = file.existsSync() ? file.lengthSync() : 0;
        onExistingBytes?.call(offset);
      }

      // אחרי קטיעה ה-hash מחושב פעם אחת על הקובץ המוגמר, לא על כל partial.
      var retrying = false;
      final outcome = await _withNetworkRetry(
        () async {
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
            onVerifyProgress: onVerifyProgress,
            onExistingBytes: onExistingBytes,
            isCancelled: isCancelled,
          );
        },
        isCancelled: isCancelled,
        onRetry: () {
          retrying = true;
          if (_partialIsResumable(
              destPath, sidecarPath, expectedSize, resumeToken)) {
            storedValidator = _strongEtag(_readSidecar(sidecarPath)?.etag);
            offset = file.lengthSync();
            onExistingBytes?.call(offset);
            return;
          }
          if (file.existsSync()) {
            _deleteRequired(destPath, messages.deletePartialBeforeRetryFailed);
          }
          storedValidator = null;
          offset = 0;
          onExistingBytes?.call(0);
        },
      );
      final downloaded = outcome.downloaded;

      if (expectedSize != null && downloaded != expectedSize) {
        _deleteQuietly(destPath);
        _deleteQuietly(sidecarPath);
        throw PatchDownloadException(
          messages.fullDbSizeMismatch(downloaded, expectedSize),
        );
      }
      if (expectedSha256 != null) {
        final expected = expectedSha256.toLowerCase();
        final actual = outcome.digest?.toString() ??
            await _hashFileSha256InIsolate(
                destPath, isCancelled, onVerifyProgress);
        if (actual != expected) {
          _deleteQuietly(destPath);
          _deleteQuietly(sidecarPath);
          throw PatchDownloadException(messages.fullDbHashMismatch);
        }
        if (resumeToken != null) {
          await _markVerified(sidecarPath, resumeToken, expected, file);
        }
      }
      // ביטול אחרי שכל הבייטים הגיעו — הקובץ שלם ונשמר, אך מאותתים ביטול.
      _throwIfCancelled(isCancelled);
    } catch (_) {
      // חלקי נשמר רק אם הוא ניתן-לחידוש; אחרת הריצה הבאה תמחק אותו ממילא.
      if (!adopting &&
          !_partialIsResumable(
              destPath, sidecarPath, expectedSize, resumeToken)) {
        _deleteQuietly(destPath);
        _deleteSegmentLeftovers(destPath);
        if (!file.existsSync()) _deleteQuietly(sidecarPath);
      }
      rethrow;
    }
  }

  /// נתיב קובץ הצד (`.resume`) של [destPath].
  static String resumeSidecarPath(String destPath) => '$destPath.resume';

  /// מוחק את קובצי ההורדה המפוצלת של [destPath] (`.segments`, `.seg-N`),
  /// לצד [destPath] ו-[resumeSidecarPath] שהצרכן מוחק בעצמו.
  static void deleteSegmentFiles(String destPath) =>
      _deleteSegmentLeftovers(destPath);

  /// הטוקן שנשמר בקובץ הצד של [destPath], אם יש.
  String? storedResumeToken(String destPath) =>
      _readSidecar(resumeSidecarPath(destPath))?.token;

  /// האם [destPath] כבר מחזיק בדיוק את [expectedSha256], לנכס שלא ירד דרך
  /// [downloadToFile]. אינו מוחק דבר; סימון תואם חוסך את ה-hash.
  Future<bool> verifyExistingFile({
    required String destPath,
    required int expectedSize,
    required String expectedSha256,
    required String resumeToken,
    void Function(int verified, int total)? onVerifyProgress,
    bool Function()? isCancelled,
  }) async {
    final file = File(destPath);
    if (!file.existsSync() || file.lengthSync() != expectedSize) return false;
    final expected = expectedSha256.toLowerCase();
    final sidecar = _readSidecar(resumeSidecarPath(destPath));
    if (sidecar?.token == resumeToken &&
        _matchesVerifiedMark(sidecar?.verified, file, expected)) {
      return true;
    }
    final actual =
        await _hashFileSha256InIsolate(destPath, isCancelled, onVerifyProgress);
    if (actual != expected) return false;
    recordVerified(
        destPath: destPath, resumeToken: resumeToken, sha256: expected);
    return true;
  }

  /// רושם ש-[destPath] אומת מול [sha256], כדי שהריצה הבאה תדלג על ה-hash.
  /// כשל כתיבה נבלע — הסימון הוא חיסכון בלבד.
  void recordVerified({
    required String destPath,
    required String resumeToken,
    required String sha256,
  }) {
    final mark = _verifiedMarkFor(File(destPath), sha256.toLowerCase());
    if (mark == null) return;
    try {
      _writeSidecar(resumeSidecarPath(destPath), resumeToken, null,
          verified: mark);
    } catch (_) {}
  }

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
      LibraryUpdaterMessages.current.deletePreviousArchiveFailed,
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

    await _joinPartsInIsolate(
      [for (var i = 0; i < split.parts.length; i++) splitPartPath(destPath, i)],
      destPath,
      split.size,
      split.sha256,
    );
    if (joinedToken != null) _writeSidecar(sidecarPath, joinedToken, null);
  }

  /// מוחק חלקים (ואת קבצי הצד שלהם) מהאינדקס [from] והלאה.
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

  /// זורם את גוף התגובה אל [file], תוך המשך מ-[offset] בעזרת `Range`, ומחזיר
  /// את הגודל שנכתב ואת ה-sha256 שחושב בזרימה (null כש-[computeHash] כבוי).
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
    void Function(int verified, int total)? onVerifyProgress,
    void Function(int bytes)? onExistingBytes,
    bool Function()? isCancelled,
  }) async {
    final messages = LibraryUpdaterMessages.current;
    // נכתב ברגע שהבייטים מגיעים, כדי שהפרעה תשאיר validator להמשך.
    void persistValidator(String? etag) {
      if (sidecarPath != null && resumeToken != null) {
        _writeSidecar(sidecarPath, resumeToken, etag);
      }
    }

    // עד 2 ניסיונות "מאפס" (206/416 לא עקביים, שרת שמתעלם מ-Range); המשך
    // תקין של 206 קצר ממשיך באותו ניסיון עד ה-total.
    var currentOffset = offset;
    for (var attempt = 0; attempt < 2; attempt++) {
      Sha256DigestCollector? digestSink;
      FastSha256Sink? hashInput;
      // התחילית מגובבת רק אחרי ש-206 מוכיח שה-Range כובד: ה-CDN של GitHub
      // מחזיר 200, וגיבוב מוקדם של ~1.4GB מהדיסק היה נזרק לחינם.
      var prefixHashed = false;
      try {
        if (computeHash) {
          digestSink = Sha256DigestCollector();
          hashInput = FastSha256.start(digestSink);
        }

        var roundOffset = currentOffset;
        var downloaded = currentOffset;
        var restart = false;
        // ה-total הראשון שדווח ב-206; כל סבב המשך חייב לדווח אותו total.
        int? sessionTotal;
        var rounds = 0;

        while (true) {
          _throwIfCancelled(isCancelled);
          if (rounds++ >= _maxContinuationRounds) {
            hashInput?.close();
            throw PatchDownloadException(
              messages.resumeRoundLimit(_maxContinuationRounds, url),
            );
          }
          final headers = <String, String>{
            'Accept': 'application/octet-stream'
          };
          if (roundOffset > 0) {
            headers['Range'] = 'bytes=$roundOffset-';
            if (validator != null) headers['If-Range'] = validator;
          }
          final response = await _sendWithManualRedirects(url, headers);

          if (response.statusCode == 200) {
            // השרת התעלם מ-Range — גוף מלא מאפס.
            try {
              // הבייטים הישנים נמחקים לפני שמירת ה-validator החדש (frankenfile).
              if (file.existsSync()) {
                _deleteRequired(
                  file.path,
                  messages.deletePartialFromPreviousRepresentationFailed,
                );
              }
              validator = _strongEtag(response.headers['etag']);
              persistValidator(validator);
              onExistingBytes?.call(0);
            } catch (_) {
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
                messages.contentLengthMismatch(responseLength, expectedSize),
              );
            }
            if (computeHash) {
              hashInput?.dispose();
              digestSink = Sha256DigestCollector();
              hashInput = FastSha256.start(digestSink);
            }
            final outcome = await _consumeBody(
              response: response,
              file: file,
              resumeOffset: 0,
              // Content-Length הוא חוזה האורך של גוף ה-200, גם בלי גודל צפוי.
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
                messages.truncatedBody(responseLength, downloaded),
              );
            }
            _throwIfCancelled(isCancelled);
            return (downloaded: downloaded, digest: digestSink?.value);
          }

          if (response.statusCode == 416) {
            // 416 מתקבל כשלמות רק כשה-total תואם ל-offset (ולצפוי).
            final total =
                _parseUnsatisfiedRangeTotal(response.headers['content-range']);
            await _abandonBody(response);
            final complete = roundOffset > 0 &&
                file.existsSync() &&
                file.lengthSync() == roundOffset &&
                total != null &&
                total == roundOffset &&
                (sessionTotal == null || total == sessionTotal) &&
                (expectedSize == null || total == expectedSize);
            if (complete) {
              // ה-digest המוחזר הוא של כל הקובץ — כאן התחילית חייבת להיגבב.
              if (computeHash && !prefixHashed && roundOffset > 0) {
                prefixHashed = true;
                await _hashPrefix(file, roundOffset, hashInput!, isCancelled,
                    onVerifyProgress);
              }
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
              messages.downloadHttpError(response.statusCode, url),
            );
          }

          // סבב ראשון קובע את ה-validator; ETag שהתחלף באמצע → restart.
          final roundEtag = _strongEtag(response.headers['etag']);
          if (validator == null) {
            if (roundEtag != null) {
              validator = roundEtag;
              try {
                persistValidator(roundEtag);
              } catch (_) {
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

          if (computeHash && !prefixHashed && currentOffset > 0) {
            prefixHashed = true;
            try {
              await _hashPrefix(file, currentOffset, hashInput!, isCancelled,
                  onVerifyProgress);
            } catch (_) {
              await _abandonBody(response);
              hashInput?.close();
              rethrow;
            }
          }

          final expectedRoundBytes = range.end - range.start + 1;
          final outcome = await _consumeBody(
            response: response,
            file: file,
            resumeOffset: roundOffset,
            expectedSize: expectedSize,
            // המד משקף את הגודל הכולל, לא את גודל הסבב הנוכחי.
            overallTotal: expectedSize ?? sessionTotal,
            maxRoundBytes: expectedRoundBytes,
            hashInput: hashInput,
            onProgress: onProgress,
            isCancelled: isCancelled,
          );
          downloaded = outcome.downloaded;

          // אורך הגוף חייב להיות בדיוק end-start+1 — גם כש-Content-Length חסר.
          if (outcome.overrun ||
              downloaded - roundOffset != expectedRoundBytes) {
            hashInput?.close();
            _throwIfCancelled(isCancelled);
            _deleteQuietly(file.path);
            restart = true;
            break;
          }

          // בלי total ידוע 206 בודד אינו מוכיח שלמות; מתחילים מאפס.
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
          if (downloaded <= roundOffset) {
            hashInput?.close();
            throw PatchDownloadException(messages.resumeMadeNoProgress(url));
          }
          roundOffset = downloaded;
        }

        if (restart) {
          // הבייטים הישנים נמחקים לפני שהניסיון הבא כובל validator חדש.
          if (file.existsSync()) {
            _deleteRequired(
              file.path,
              messages.deletePartialBeforeRetryFailed,
            );
          }
          currentOffset = 0;
          onExistingBytes?.call(0);
          validator = null;
          continue;
        }
      } finally {
        hashInput?.dispose();
      }
    }
    throw PatchDownloadException(messages.resumeFailedAfterRetry(url));
  }

  /// מזרים ל-[hashInput] את [length] הבתים הראשונים של [file].
  Future<void> _hashPrefix(
    File file,
    int length,
    FastSha256Sink hashInput,
    bool Function()? isCancelled,
    void Function(int verified, int total)? onVerifyProgress,
  ) async {
    var hashed = 0;
    await for (final chunk in file.openRead(0, length)) {
      _throwIfCancelled(isCancelled);
      hashInput.add(chunk);
      hashed += chunk.length;
      onVerifyProgress?.call(hashed, length);
    }
  }

  /// נוטש את גוף התגובה בלי לרוקן אותו, כדי ששרת שממשיך לשדר לא יזרים את
  /// כל הנכס רק כדי לדווח כשל מקומי.
  Future<void> _abandonBody(http.StreamedResponse response) async {
    try {
      await response.stream.listen((_) {}).cancel();
    } catch (_) {}
  }

  /// בקשת GET שנזנחת באמת ב-timeout של החיבור, ולא רק נשכחת.
  Future<http.StreamedResponse> _sendGet(
    Uri uri,
    Map<String, String> headers, {
    bool followRedirects = true,
    Future<void>? abortTrigger,
  }) async {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      'GET',
      uri,
      abortTrigger: abortTrigger == null
          ? abort.future
          : Future.any([abort.future, abortTrigger]),
    )
      ..followRedirects = followRedirects
      ..headers.addAll(headers);
    final pending = _httpClient.send(request);
    try {
      return await pending.timeout(connectTimeout);
    } on TimeoutException {
      abort.complete();
      unawaited(pending.then(_abandonBody, onError: (Object _) {}));
      rethrow;
    }
  }

  /// כותב את גוף התגובה לקובץ מ-[resumeOffset] ומחזיר את הגודל הכולל שנכתב,
  /// עם `overrun` כשהגוף חרג מ-[maxRoundBytes]. אינו סוגר את [hashInput].
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
    final messages = LibraryUpdaterMessages.current;

    final sink =
        file.openWrite(mode: append ? FileMode.append : FileMode.write);
    final total = overallTotal ??
        (response.contentLength == null
            ? null
            : resumeOffset + response.contentLength!);
    var downloaded = resumeOffset;
    // ב-Windows handle פתוח חוסם מחיקה/resume — נסגר גם במסלול שגיאה.
    var closed = false;
    Future<void> closeQuietly() async {
      if (closed) return;
      closed = true;
      try {
        await sink.close();
      } catch (_) {}
    }

    var overrun = false;
    var buffered = 0;
    try {
      await for (final chunk in response.stream.timeout(stallTimeout)) {
        _throwIfCancelled(isCancelled);
        if (expectedSize != null && downloaded + chunk.length > expectedSize) {
          await closeQuietly();
          _deleteQuietly(file.path);
          _deleteQuietly(resumeSidecarPath(file.path));
          throw PatchDownloadException(
            messages.downloadExceedsExpectedSize(expectedSize),
          );
        }
        // גוף שחורג מהטווח שהוצהר נעצר לפני הכתיבה.
        if (maxRoundBytes != null &&
            (downloaded - resumeOffset) + chunk.length > maxRoundBytes) {
          overrun = true;
          break;
        }
        sink.add(chunk);
        hashInput?.add(chunk);
        downloaded += chunk.length;
        buffered += chunk.length;
        onProgress?.call(downloaded, total);
        if (buffered >= _writeBufferBytes) {
          buffered = 0;
          await sink.flush();
        }
      }
      // ביטול שהתרחש ב-onProgress של הצ'אנק האחרון.
      _throwIfCancelled(isCancelled);
    } catch (_) {
      await closeQuietly();
      rethrow;
    }
    // כשל flush/close משאיר קובץ באורך מלא ובתוכן פגום — נמחק לפני הזריקה.
    try {
      await sink.flush();
      await sink.close();
      closed = true;
    } catch (error) {
      await closeQuietly();
      _deleteQuietly(file.path);
      _deleteQuietly(resumeSidecarPath(file.path));
      throw PatchDownloadException(messages.saveDownloadedFileFailed('$error'));
    }
    return (downloaded: downloaded, overrun: overrun);
  }

  /// עוקב אחר הפניות ידנית — `package:http` משמיט את `Range` כשהוא עוקב לבד.
  Future<http.StreamedResponse> _sendWithManualRedirects(
    String url,
    Map<String, String> headers, {
    Future<void>? abortTrigger,
  }) async {
    var uri = Uri.parse(url);
    const maxHops = 6;
    for (var hop = 0; hop <= maxHops; hop++) {
      final response = await _sendGet(uri, headers,
          followRedirects: false, abortTrigger: abortTrigger);
      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        if (location == null) return response;
        await _abandonBody(response);
        uri = uri.resolve(location);
        continue;
      }
      return response;
    }
    throw PatchDownloadException(
      LibraryUpdaterMessages.current.tooManyRedirects(url),
    );
  }

  bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  /// מפענח `Content-Range: bytes start-end/total` של 206; total `*` ⇒ null.
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

  /// מפענח את ה-total מ-`Content-Range: bytes */N` של 416.
  int? _parseUnsatisfiedRangeTotal(String? contentRange) {
    if (contentRange == null) return null;
    final match = RegExp(r'^\s*bytes\s+\*/(\d+)\s*$', caseSensitive: false)
        .firstMatch(contentRange.trim());
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// חלקי ניתן-לחידוש רק עם validator חזק בקובץ הצד, או כשהוא כבר שלם.
  bool _partialIsResumable(
    String destPath,
    String sidecarPath,
    int? expectedSize,
    String? resumeToken,
  ) {
    if (resumeToken == null) return false;
    // רץ מתוך catch — כשל כאן אסור שיסתיר את החריגה המקורית.
    try {
      if (_hasSegmentState(destPath, resumeToken)) return true;
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

  /// קובץ הצד: טוקן, ETag חזק (אופציונלי), סימון אימות (אופציונלי).
  ({String token, String? etag, String? verified})? _readSidecar(
      String sidecarPath) {
    try {
      final f = File(sidecarPath);
      if (!f.existsSync()) return null;
      final lines = f.readAsStringSync().split('\n');
      final etag = lines.length > 1 && lines[1].isNotEmpty ? lines[1] : null;
      final verified =
          lines.length > 2 && lines[2].isNotEmpty ? lines[2] : null;
      return (token: lines.first, etag: etag, verified: verified);
    } catch (_) {
      return null;
    }
  }

  /// בלי ETag ובלי סימון נכתב הטוקן לבדו — וכך גם נמחק סימון של תוכן משתנה.
  void _writeSidecar(String sidecarPath, String token, String? etag,
      {String? verified}) {
    try {
      final lines = <String>[
        token,
        if (etag != null || verified != null) etag ?? '',
        if (verified != null) verified,
      ];
      File(sidecarPath).writeAsStringSync(lines.join('\n'), flush: true);
    } catch (error) {
      throw PatchDownloadException(
        LibraryUpdaterMessages.current
            .writeResumeSidecarFailed(sidecarPath, '$error'),
      );
    }
  }

  /// `sha256|גודל|זמן-שינוי` כפי שהיו ברגע האימות; null כשאין stat קריא.
  String? _verifiedMarkFor(File file, String digest) {
    try {
      final stat = file.statSync();
      return '$digest|${stat.size}|${stat.modified.microsecondsSinceEpoch}';
    } catch (_) {
      return null;
    }
  }

  bool _matchesVerifiedMark(String? mark, File file, String expectedSha256) =>
      mark != null && mark == _verifiedMarkFor(file, expectedSha256);

  Future<bool> _completeFileVerified(
    String destPath,
    String sidecarPath,
    String? resumeToken,
    String? expectedSha256,
    String? storedVerified,
    bool Function()? isCancelled,
    void Function(int verified, int total)? onVerifyProgress,
  ) async {
    if (expectedSha256 == null) return true;
    final expected = expectedSha256.toLowerCase();
    final file = File(destPath);
    if (_matchesVerifiedMark(storedVerified, file, expected)) return true;
    final actual =
        await _hashFileSha256InIsolate(destPath, isCancelled, onVerifyProgress);
    if (actual != expected) return false;
    if (resumeToken != null) {
      await _markVerified(sidecarPath, resumeToken, expected, file);
    }
    return true;
  }

  /// flush לפני הסימון, כדי שזמן-השינוי שנרשם יהיה הסופי.
  Future<void> _markVerified(
      String sidecarPath, String token, String digest, File file) async {
    try {
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
    } catch (_) {
      return;
    }
    final mark = _verifiedMarkFor(file, digest);
    if (mark == null) return;
    try {
      _writeSidecar(sidecarPath, token, _readSidecar(sidecarPath)?.etag,
          verified: mark);
    } catch (_) {}
  }

  /// נכס שפורסם מחדש בזהות חדשה אך בתוכן זהה נקשר לטוקן החדש במקום להימחק.
  /// מחזיר את סימון האימות, או null אם התוכן אינו זהה.
  Future<String?> _adoptSameContent(
    File file,
    String sidecarPath,
    String? storedVerified,
    String resumeToken,
    int? expectedSize,
    String? expectedSha256,
    bool Function()? isCancelled,
    void Function(int verified, int total)? onVerifyProgress,
  ) async {
    if (expectedSha256 == null ||
        expectedSize == null ||
        file.lengthSync() != expectedSize) {
      return null;
    }
    final expected = expectedSha256.toLowerCase();
    if (!_matchesVerifiedMark(storedVerified, file, expected)) {
      final actual = await _hashFileSha256InIsolate(
          file.path, isCancelled, onVerifyProgress);
      if (actual != expected) return null;
    }
    final mark = _verifiedMarkFor(file, expected);
    if (mark == null) return null;
    _writeSidecar(sidecarPath, resumeToken, null, verified: mark);
    return mark;
  }

  /// ETag חזק בלבד (ללא `W/`) — ETag חלש אינו שמיש עם If-Range.
  String? _strongEtag(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.startsWith('W/')) return null;
    return trimmed;
  }

  /// מוריד לזיכרון ומחשב sha256 בזרימה; patch קטן מתחיל מחדש אחרי קטיעה.
  Future<({Uint8List bytes, Digest digest})> _download(
    String url, {
    required int maxBytes,
    void Function(int downloaded, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!isRemoteUrl(url)) {
      final bytes = await _readLocalFile(
        url,
        maxBytes: maxBytes,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      return (bytes: bytes, digest: FastSha256.convert(bytes));
    }
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
    final messages = LibraryUpdaterMessages.current;
    final response = await _sendGet(
      Uri.parse(url),
      const {'Accept': 'application/octet-stream'},
    );
    if (response.statusCode != 200) {
      await _abandonBody(response);
      throw PatchDownloadException(
        messages.downloadHttpError(response.statusCode, url),
      );
    }
    final total = response.contentLength;
    final builder = BytesBuilder(copy: false);
    final digestSink = Sha256DigestCollector();
    final hashInput = FastSha256.start(digestSink);
    try {
      var downloaded = 0;
      await for (final chunk in response.stream.timeout(stallTimeout)) {
        _throwIfCancelled(isCancelled);
        if (downloaded + chunk.length > maxBytes) {
          throw PatchDownloadException(
            messages.downloadExceedsExpectedSize(maxBytes),
          );
        }
        builder.add(chunk);
        hashInput.add(chunk);
        downloaded += chunk.length;
        onProgress?.call(downloaded, total);
      }
      hashInput.close();
    } finally {
      hashInput.dispose();
    }
    return (bytes: builder.takeBytes(), digest: digestSink.value);
  }

  void _verify({
    required int actual,
    required int expected,
    required String label,
  }) {
    if (actual != expected) {
      throw PatchDownloadException(
        LibraryUpdaterMessages.current
            .checksumMismatchDetailed(label, '$expected', '$actual'),
      );
    }
  }

  void _verifyDigest({
    required Digest actual,
    required String expected,
    required String label,
  }) {
    if (actual.toString() != expected.toLowerCase()) {
      throw PatchDownloadException(
        LibraryUpdaterMessages.current.checksumMismatch(label),
      );
    }
  }

  /// מאמת sha256 של קובץ שעל הדיסק; החישוב רץ ב-isolate נפרד.
  Future<void> _verifyFileHash({
    required String path,
    required String expected,
    required String label,
    void Function(int bytesDone, int bytesTotal)? onVerifyProgress,
  }) async {
    final actual = await _hashFileSha256InIsolate(path, null, onVerifyProgress);
    if (actual != expected.toLowerCase()) {
      throw PatchDownloadException(
        LibraryUpdaterMessages.current.checksumMismatch(label),
      );
    }
  }

  void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled != null && isCancelled()) {
      throw const PatchDownloadCancelled();
    }
  }

  /// מריץ את [run] ומנסה שוב על כשל רשת חולף לפי [networkRetryDelays]; אחרי
  /// הניסיון האחרון נזרק [PatchNetworkException]. [onRetry] רץ לפני כל ניסיון.
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

  Future<Uint8List> _readLocalFile(
    String path, {
    required int maxBytes,
    void Function(int downloaded, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final messages = LibraryUpdaterMessages.current;
    final file = File(path);
    if (!await file.exists()) {
      throw PatchDownloadException(messages.localFileNotFound(path));
    }
    _throwIfCancelled(isCancelled);
    if (await file.length() > maxBytes) {
      throw PatchDownloadException(messages.localFileTooLarge(maxBytes, path));
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxBytes) {
      throw PatchDownloadException(messages.localFileTooLarge(maxBytes, path));
    }
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }

  /// מעתיק קובץ מנתיב מקומי אל [destPath] בזרימה, עם אימות גודל ו-sha256.
  /// ללא resume; [destPath] נמחק בכל כשל או ביטול.
  Future<void> _copyLocalFile({
    required String url,
    required String destPath,
    int? expectedSize,
    String? expectedSha256,
    void Function(int downloaded, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final messages = LibraryUpdaterMessages.current;
    final source = File(url);
    if (!await source.exists()) {
      throw PatchDownloadException(messages.localSourceNotFound(url));
    }
    final size = await source.length();
    if (expectedSize != null && size != expectedSize) {
      throw PatchDownloadException(
        messages.localFileSizeMismatch(expectedSize, size, url),
      );
    }
    IOSink? sink;
    final digestSink = expectedSha256 != null ? Sha256DigestCollector() : null;
    final input = digestSink != null ? FastSha256.start(digestSink) : null;
    try {
      _deleteQuietly(destPath);
      sink = File(destPath).openWrite();
      var copied = 0;
      var buffered = 0;
      await for (final chunk in source.openRead()) {
        _throwIfCancelled(isCancelled);
        sink.add(chunk);
        input?.add(chunk);
        copied += chunk.length;
        buffered += chunk.length;
        onProgress?.call(copied, size);
        if (buffered >= _writeBufferBytes) {
          buffered = 0;
          await sink.flush();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      input?.close();
      if (expectedSha256 != null &&
          digestSink!.value.toString() != expectedSha256.toLowerCase()) {
        throw PatchDownloadException(messages.localFileHashMismatch(url));
      }
    } catch (_) {
      // ב-Windows handle פתוח חוסם את המחיקה.
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      _deleteQuietly(destPath);
      rethrow;
    } finally {
      input?.dispose();
    }
  }

  void dispose() {
    if (_ownsClient) _httpClient.close();
  }
}

/// sha256 של קובץ ב-isolate נפרד. ביטול ([isCancelled] נדגם כל 100ms) והתקדמות
/// עוברים כהודעות; ביטול נזרק כ-[PatchDownloadCancelled].
Future<String> _hashFileSha256InIsolate(
  String path, [
  bool Function()? isCancelled,
  void Function(int verified, int total)? onProgress,
]) =>
    _runCancellableWorker(_hashFileWork(path), isCancelled, onProgress);

/// נבנה בפונקציה נפרדת כדי שה-closure ילכוד רק את [path].
_WorkerBody<String> _hashFileWork(String path) =>
    (isCancelled, onProgress) => _hashFileSha256(path, isCancelled, onProgress);

typedef _WorkerBody<T> = Future<T> Function(
  bool Function()? isCancelled,
  void Function(int done, int total)? onProgress,
);

/// מריץ את [work] ב-isolate נפרד; ביטול נדגם כל 100ms ונמסר בהודעה.
Future<T> _runCancellableWorker<T>(
  _WorkerBody<T> work,
  bool Function()? isCancelled,
  void Function(int done, int total)? onProgress,
) async {
  if (isCancelled == null && onProgress == null) {
    return _runWorker(work, null);
  }
  if (isCancelled != null && isCancelled()) {
    throw const PatchDownloadCancelled();
  }
  final control = ReceivePort();
  SendPort? workerCancel;
  var cancelled = false;
  control.listen((message) {
    if (message is SendPort) {
      workerCancel = message;
      if (cancelled) workerCancel!.send(null);
    } else if (message is List && onProgress != null) {
      onProgress(message[0] as int, message[1] as int);
    }
  });
  final poll = isCancelled == null
      ? null
      : Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (cancelled || !isCancelled()) return;
          cancelled = true;
          workerCancel?.send(null);
        });
  try {
    final result = await _runWorker(work, control.sendPort);
    // עבודה קצרה יכולה להסתיים לפני הדגימה הבאה של הביטול.
    if (cancelled || (isCancelled?.call() ?? false)) {
      throw const PatchDownloadCancelled();
    }
    return result;
  } finally {
    poll?.cancel();
    control.close();
  }
}

/// נפרד מ-[_runCancellableWorker] כדי שה-closure לא ילכוד את ה-ReceivePort.
Future<T> _runWorker<T>(_WorkerBody<T> work, SendPort? control) =>
    Isolate.run(() async {
      if (control == null) return work(null, null);
      final cancel = ReceivePort();
      var cancelled = false;
      cancel.listen((_) => cancelled = true);
      control.send(cancel.sendPort);
      try {
        return await work(
          () => cancelled,
          (done, total) => control.send([done, total]),
        );
      } finally {
        cancel.close();
      }
    });

/// sha256 של קובץ בזרימה; רץ רק בתוך worker. התקדמות מדווחת כל ~4MB.
Future<String> _hashFileSha256(
  String path, [
  bool Function()? isCancelled,
  void Function(int verified, int total)? onProgress,
]) async {
  const reportEvery = 4 << 20;
  final file = File(path);
  final total = onProgress == null ? 0 : await file.length();
  final digestSink = Sha256DigestCollector();
  final input = FastSha256.start(digestSink);
  try {
    var verified = 0;
    var lastReported = 0;
    await for (final chunk in file.openRead()) {
      if (isCancelled != null && isCancelled()) {
        throw const PatchDownloadCancelled();
      }
      input.add(chunk);
      verified += chunk.length;
      if (onProgress != null &&
          (verified - lastReported >= reportEvery || verified == total)) {
        lastReported = verified;
        onProgress(verified, total);
      }
    }
    input.close();
  } finally {
    input.dispose();
  }
  return digestSink.value.toString();
}

/// top-level כדי שה-closure של `Isolate.run` לא ילכוד את ה-PatchDownloader.
/// המלל הפעיל עובר ל-isolate, אחרת הודעת כשל הייתה חוזרת בעברית.
Future<void> _joinPartsInIsolate(List<String> partPaths, String destPath,
    int expectedSize, String expectedSha256) {
  final messages = LibraryUpdaterMessages.current;
  return Isolate.run(() {
    LibraryUpdaterMessages.current = messages;
    _joinParts(partPaths, destPath, expectedSize, expectedSha256);
  });
}

/// מצרף לקובץ זמני, מוחק כל חלק אחרי צירופו, ומעביר ל-[destPath] רק אחרי
/// אימות. אינו נעצר בביטול: חיבור שנקטע היה מאבד חלקים שכבר צורפו.
void _joinParts(List<String> partPaths, String destPath, int expectedSize,
    String expectedSha256) {
  final messages = LibraryUpdaterMessages.current;
  final tempPath = '$destPath.joining';
  final digestSink = Sha256DigestCollector();
  final hasher = FastSha256.start(digestSink);
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
        messages.joinedArchiveSizeMismatch(written, expectedSize),
      );
    }
    if (digestSink.value.toString() != expectedSha256) {
      throw PatchDownloadException(messages.joinedArchiveHashMismatch);
    }
    File(tempPath).renameSync(destPath);
  } catch (_) {
    _deleteFileQuietly(tempPath);
    rethrow;
  } finally {
    hasher.dispose();
  }
}

/// נעילה בלעדית של יעד הורדה: קבוצה בתהליך (נעילת קובץ ב-POSIX אינה חוסמת
/// את אותו תהליך) ונעילת `<dest>.lock` בין תהליכים.
class _DestinationLock {
  _DestinationLock._(this._key, this._file, this._path);

  static final Set<String> _held = {};

  final String _key;
  final RandomAccessFile _file;
  final String _path;

  static _DestinationLock acquire(String destPath) {
    final path = '$destPath.lock';
    final key = p.canonicalize(destPath);
    final messages = LibraryUpdaterMessages.current;
    if (!_held.add(key)) {
      throw PatchDownloadException(messages.writeResumeSidecarFailed(
          path, 'already being downloaded in this process'));
    }
    RandomAccessFile? file;
    try {
      file = File(path).openSync(mode: FileMode.append);
      file.lockSync(FileLock.exclusive);
      return _DestinationLock._(key, file, path);
    } catch (error) {
      try {
        file?.closeSync();
      } catch (_) {}
      _held.remove(key);
      throw PatchDownloadException(
          messages.writeResumeSidecarFailed(path, '$error'));
    }
  }

  void release() {
    try {
      _file.unlockSync();
    } catch (_) {}
    try {
      _file.closeSync();
    } catch (_) {}
    _deleteFileQuietly(_path);
    _held.remove(_key);
  }
}

void _deleteFileQuietly(String path) {
  try {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  } catch (_) {}
}
