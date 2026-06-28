import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../models/delta_manifest.dart';

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

/// מוריד קובץ patch דחוס, מאמת sha256 וגודל (דחוס ומחולץ), ומחלץ ל-`.db`.
///
/// ה-patches קטנים (עד עשרות MB מחולצים), לכן ההורדה והחילוץ בזיכרון. אם
/// אימות נכשל — הקבצים נמחקים ונזרק [PatchDownloadException].
class PatchDownloader {
  final http.Client _httpClient;
  final bool _ownsClient;

  /// פונקציית חילוץ zstd — מוזרקת על-ידי הצרכן (החבילה אגנוסטית לפלטפורמה).
  final Future<Uint8List?> Function(Uint8List compressed) _decompress;
  final Duration connectTimeout;
  final Duration stallTimeout;

  PatchDownloader({
    required Future<Uint8List?> Function(Uint8List compressed) decompress,
    http.Client? httpClient,
    this.connectTimeout = const Duration(seconds: 20),
    this.stallTimeout = const Duration(seconds: 30),
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _decompress = decompress;

  /// מוריד ומחלץ את [patchFile] מ-[downloadUrl] לתיקייה [destDir].
  /// מחזיר את הנתיב לקובץ ה-`.db` המחולץ והמאומת.
  Future<String> downloadAndExtract({
    required PatchFileEntry patchFile,
    required String downloadUrl,
    required Directory destDir,
    void Function(int downloaded, int? total)? onProgress,
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
      final compressed = await _download(
        downloadUrl,
        maxBytes: patchFile.size,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );

      _verify(
        actual: compressed.length,
        expected: patchFile.size,
        label: 'גודל הקובץ הדחוס',
      );
      _verifyHash(
        bytes: compressed,
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
      _verifyHash(
        bytes: extracted,
        expected: patchFile.uncompressedSha256,
        label: 'sha256 של הקובץ המחולץ',
      );

      File(extractedPath).writeAsBytesSync(extracted, flush: true);
      return extractedPath;
    } catch (_) {
      _deleteQuietly(extractedPath);
      rethrow;
    }
  }

  /// מוריד קובץ גדול ישירות לדיסק בזרימה (ללא טעינה ל-RAM) — ל-DB המלא
  /// (~1.1GB). מאמת sha256 אם [expectedSha256] סופק; מוחק קובץ פגום בכשל.
  Future<void> downloadToFile({
    required String url,
    required String destPath,
    int? expectedSize,
    String? expectedSha256,
    void Function(int downloaded, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final file = File(destPath);
    if (file.existsSync()) file.deleteSync();
    final sink = file.openWrite();
    final digestSink = _ChunkedDigestSink();
    final hashInput = expectedSha256 != null
        ? sha256.startChunkedConversion(digestSink)
        : null;
    var downloaded = 0;
    try {
      final request = http.Request('GET', Uri.parse(url))
        ..headers['Accept'] = 'application/octet-stream';
      final response = await _httpClient.send(request).timeout(connectTimeout);
      if (response.statusCode != 200) {
        throw PatchDownloadException(
          'שגיאה בהורדה (${response.statusCode}): $url',
        );
      }
      final total = response.contentLength;
      await for (final chunk in response.stream.timeout(stallTimeout)) {
        _throwIfCancelled(isCancelled);
        // בדיקה לפני הכתיבה — לא כותבים לדיסק בייטים שחורגים מהגודל הצפוי.
        if (expectedSize != null && downloaded + chunk.length > expectedSize) {
          throw PatchDownloadException(
              'ההורדה חורגת מהגודל הצפוי ($expectedSize בייטים)');
        }
        sink.add(chunk);
        hashInput?.add(chunk);
        downloaded += chunk.length;
        onProgress?.call(downloaded, total);
      }
      await sink.flush();
    } catch (_) {
      await sink.close();
      _deleteQuietly(destPath);
      rethrow;
    }
    await sink.close();

    if (expectedSize != null && downloaded != expectedSize) {
      _deleteQuietly(destPath);
      throw PatchDownloadException(
          'גודל ה-DB שהורד ($downloaded) אינו תואם לצפוי ($expectedSize)');
    }
    if (expectedSha256 != null) {
      hashInput!.close();
      if (digestSink.value.toString() != expectedSha256.toLowerCase()) {
        _deleteQuietly(destPath);
        throw const PatchDownloadException('sha256 של ה-DB המלא אינו תואם');
      }
    }
  }

  Future<Uint8List> _download(
    String url, {
    required int maxBytes,
    void Function(int downloaded, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final request = http.Request('GET', Uri.parse(url))
      ..headers['Accept'] = 'application/octet-stream';
    final response = await _httpClient.send(request).timeout(connectTimeout);
    if (response.statusCode != 200) {
      throw PatchDownloadException(
        'שגיאה בהורדה (${response.statusCode}): $url',
      );
    }
    final total = response.contentLength;
    final builder = BytesBuilder(copy: false);
    var downloaded = 0;
    await for (final chunk in response.stream.timeout(stallTimeout)) {
      _throwIfCancelled(isCancelled);
      // בדיקה לפני הצבירה — לא צוברים לזיכרון בייטים שחורגים מהגודל הצפוי.
      if (downloaded + chunk.length > maxBytes) {
        throw PatchDownloadException(
            'ההורדה חורגת מהגודל הצפוי ($maxBytes בייטים)');
      }
      builder.add(chunk);
      downloaded += chunk.length;
      onProgress?.call(downloaded, total);
    }
    return builder.takeBytes();
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

  void _verifyHash({
    required Uint8List bytes,
    required String expected,
    required String label,
  }) {
    final actual = sha256.convert(bytes).toString();
    if (actual != expected.toLowerCase()) {
      throw PatchDownloadException('$label אינו תואם');
    }
  }

  void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled != null && isCancelled()) {
      throw const PatchDownloadCancelled();
    }
  }

  void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  void dispose() {
    if (_ownsClient) _httpClient.close();
  }
}

/// אוסף את ה-Digest מ-`startChunkedConversion` של sha256 בהורדה לדיסק.
class _ChunkedDigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
