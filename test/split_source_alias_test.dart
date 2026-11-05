import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String destination;
  late PatchDownloader downloader;
  final bytes = List<int>.generate(1024, (index) => index % 251);
  final digest = sha256.convert(bytes).toString();

  setUp(() {
    directory = Directory.systemTemp.createTempSync('split-source-alias');
    destination = '${directory.path}/archive.zst';
    downloader = PatchDownloader(decompress: (input) async => input);
  });
  tearDown(() {
    downloader.dispose();
    directory.deleteSync(recursive: true);
  });

  SplitAsset split(String source) => SplitAsset(
    archive: 'archive.zst',
    size: bytes.length,
    sha256: digest,
    manifestName: 'archive.zst.manifest.json',
    parts: [
      SplitAssetPart(
        name: 'archive.zst.part-000',
        size: bytes.length,
        sha256: digest,
        downloadUrl: source,
      ),
    ],
  );

  for (final suffix in [
    '',
    '.part-019',
    '.part-000.seg-1',
    '.resume',
    '.lock',
  ]) {
    test(
      'split rejects local source at managed path $suffix before cleanup',
      () async {
        final source = File('$destination$suffix')..writeAsBytesSync(bytes);
        if (suffix.isNotEmpty) File(destination).writeAsStringSync('previous');

        await expectLater(
          downloader.downloadSplitToFile(
            split: split(source.path),
            destPath: destination,
          ),
          throwsArgumentError,
        );

        expect(source.readAsBytesSync(), bytes);
        if (suffix.isNotEmpty) {
          expect(File(destination).readAsStringSync(), 'previous');
        }
        if (suffix != '.lock') {
          expect(File('$destination.lock').existsSync(), isFalse);
        }
      },
    );
  }

  test(
    'split rejects a source symlink to destination before cleanup',
    () async {
      File(destination).writeAsBytesSync(bytes);
      final alias = Link('${directory.path}/source-link')
        ..createSync(destination);
      await expectLater(
        downloader.downloadSplitToFile(
          split: split(alias.path),
          destPath: destination,
        ),
        throwsArgumentError,
      );
      expect(File(destination).readAsBytesSync(), bytes);
      expect(alias.existsSync(), isTrue);
      expect(File('$destination.lock').existsSync(), isFalse);
    },
    skip: Platform.isWindows
        ? 'symlink privileges depend on host policy'
        : false,
  );

  test(
    'ordinary local parts still copy and verify without deleting sources',
    () async {
      final source = File('${directory.path}/source.zst')
        ..writeAsBytesSync(bytes);
      await downloader.downloadSplitToFile(
        split: split(source.path),
        destPath: destination,
      );
      expect(File(destination).readAsBytesSync(), bytes);
      expect(source.readAsBytesSync(), bytes);
    },
  );

  test('single local download rejects a source used as its lock', () async {
    final source = File('$destination.lock')..writeAsBytesSync(bytes);
    await expectLater(
      downloader.downloadToFile(url: source.path, destPath: destination),
      throwsArgumentError,
    );
    expect(source.readAsBytesSync(), bytes);
    expect(File(destination).existsSync(), isFalse);
  });
}
