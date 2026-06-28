import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seforim_library_updater/src/models/delta_manifest.dart';
import 'package:seforim_library_updater/src/services/patch_downloader.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('downloader_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // "patch" מדומה: compressed=הבייטים שמוגשים; decompress=זהות (מחזיר אותם).
  final uncompressed = Uint8List.fromList(List.generate(64, (i) => i));
  final compressed = Uint8List.fromList(List.generate(32, (i) => 255 - i));

  PatchFileEntry entry({String? badCompressedHash, int? badSize}) =>
      PatchFileEntry(
        file: 'patch-v1-v2.db.zst',
        compression: 'zstd',
        sha256: badCompressedHash ?? sha256.convert(compressed).toString(),
        size: badSize ?? compressed.length,
        uncompressedSha256: sha256.convert(uncompressed).toString(),
        uncompressedSize: uncompressed.length,
      );

  PatchDownloader buildDownloader() {
    final mock = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        Stream.value(compressed),
        200,
        contentLength: compressed.length,
      );
    });
    return PatchDownloader(
      httpClient: mock,
      decompress: (c) async => uncompressed,
    );
  }

  test('הורדה+חילוץ מוצלחים כותבים את ה-.db המחולץ', () async {
    final path = await buildDownloader().downloadAndExtract(
      patchFile: entry(),
      downloadUrl: 'https://x/patch-v1-v2.db.zst',
      destDir: tmp,
    );
    expect(path, endsWith('patch-v1-v2.db'));
    expect(File(path).readAsBytesSync(), uncompressed);
  });

  test('sha256 דחוס שגוי → נכשל וה-.db לא נכתב', () async {
    expect(
      () => buildDownloader().downloadAndExtract(
        patchFile: entry(badCompressedHash: 'deadbeef'),
        downloadUrl: 'https://x/p',
        destDir: tmp,
      ),
      throwsA(isA<PatchDownloadException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(File('${tmp.path}/patch-v1-v2.db').existsSync(), isFalse);
  });

  test('גודל דחוס שגוי → נכשל', () async {
    expect(
      () => buildDownloader().downloadAndExtract(
        patchFile: entry(badSize: 999),
        downloadUrl: 'https://x/p',
        destDir: tmp,
      ),
      throwsA(isA<PatchDownloadException>()),
    );
  });

  test('sha256 מחולץ שגוי → נכשל', () async {
    // decompress מחזיר בייטים שלא תואמים ל-uncompressedSha256
    final mock = MockClient.streaming((request, bodyStream) async =>
        http.StreamedResponse(Stream.value(compressed), 200,
            contentLength: compressed.length));
    final downloader = PatchDownloader(
      httpClient: mock,
      decompress: (c) async => Uint8List.fromList([9, 9, 9]),
    );
    expect(
      () => downloader.downloadAndExtract(
        patchFile: entry(),
        downloadUrl: 'https://x/p',
        destDir: tmp,
      ),
      throwsA(isA<PatchDownloadException>()),
    );
  });

  group('downloadToFile (DB מלא)', () {
    // downloadToFile אינו מחלץ, אך ה-constructor דורש decompress (חובה כעת).
    PatchDownloader fullDownloader() => PatchDownloader(
          httpClient: MockClient.streaming((request, bodyStream) async =>
              http.StreamedResponse(Stream.value(compressed), 200,
                  contentLength: compressed.length)),
          decompress: (c) async => uncompressed,
        );

    test('הורדה זורמת מצליחה וכותבת את הקובץ', () async {
      final dest = '${tmp.path}/seforim.db.zst';
      await fullDownloader().downloadToFile(
        url: 'https://x/seforim.db.zst',
        destPath: dest,
        expectedSize: compressed.length,
      );
      expect(File(dest).readAsBytesSync(), compressed);
    });

    test('expectedSize קטן מהמתקבל → עוצר וה-קובץ לא נשאר', () async {
      final dest = '${tmp.path}/seforim.db.zst';
      await expectLater(
        fullDownloader().downloadToFile(
          url: 'https://x/seforim.db.zst',
          destPath: dest,
          expectedSize: 8, // קטן מ-32 שמתקבלים
        ),
        throwsA(isA<PatchDownloadException>()),
      );
      expect(File(dest).existsSync(), isFalse);
    });

    test('expectedSize גדול מהמתקבל → נכשל באימות אורך סופי', () async {
      final dest = '${tmp.path}/seforim.db.zst';
      await expectLater(
        fullDownloader().downloadToFile(
          url: 'https://x/seforim.db.zst',
          destPath: dest,
          expectedSize: 9999, // גדול מ-32
        ),
        throwsA(isA<PatchDownloadException>()),
      );
      expect(File(dest).existsSync(), isFalse);
    });
  });
}
