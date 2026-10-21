import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seforim_library_updater/src/services/patch_downloader.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('file_hash_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  final downloader = PatchDownloader(
    httpClient: MockClient((_) async => http.Response('', 500)),
    decompress: (c) async => c,
  );
  const chunk = PatchDownloader.fileHashReadBytes;

  Uint8List bytesOf(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = (i * 31 + (i >> 11)) & 0xff;
    }
    return bytes;
  }

  group('sha256 של קובץ על הדיסק בגבולות חוצץ הקריאה', () {
    for (final length in [
      0,
      1,
      chunk - 1,
      chunk,
      chunk + 1,
      3 * chunk + 7,
      (4 << 20) + 3,
    ]) {
      test('$length בתים', () async {
        final bytes = bytesOf(length);
        final path = '${tmp.path}/f.bin';
        File(path).writeAsBytesSync(bytes);
        final verified = <(int, int)>[];
        final ok = await downloader.verifyExistingFile(
          destPath: path,
          expectedSize: length,
          expectedSha256: sha256.convert(bytes).toString(),
          resumeToken: 't',
          onVerifyProgress: (done, total) => verified.add((done, total)),
        );
        expect(ok, isTrue);
        if (length > 0) expect(verified.last, (length, length));
        for (var i = 1; i < verified.length; i++) {
          expect(verified[i].$1, greaterThan(verified[i - 1].$1));
        }
      });
    }

    test('בית אחד שונה בסוף הגוש השני → לא מאומת', () async {
      final bytes = bytesOf(2 * chunk + 5);
      final hash = sha256.convert(bytes).toString();
      bytes[2 * chunk - 1] ^= 1;
      final path = '${tmp.path}/f.bin';
      File(path).writeAsBytesSync(bytes);
      final ok = await downloader.verifyExistingFile(
        destPath: path,
        expectedSize: bytes.length,
        expectedSha256: hash,
        resumeToken: 't',
      );
      expect(ok, isFalse);
    });
  });
}
