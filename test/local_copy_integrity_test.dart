import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late PatchDownloader downloader;
  setUp(() {
    root = Directory.systemTemp.createTempSync('local_copy_integrity_');
    downloader = PatchDownloader(decompress: (_) async => null);
  });
  tearDown(() async {
    downloader.dispose();
    await root.delete(recursive: true);
  });

  test('same source/destination is rejected before deletion', () async {
    final source = File(p.join(root.path, 'mirror.zst'));
    await source.writeAsString('untouched mirror');
    await expectLater(
      downloader.downloadToFile(url: source.path, destPath: source.path),
      throwsArgumentError,
    );
    expect(await source.readAsString(), 'untouched mirror');
  });

  test(
    'symlink alias is rejected before deletion',
    () async {
      final source = File(p.join(root.path, 'mirror.zst'));
      final alias = Link(p.join(root.path, 'alias.zst'));
      await source.writeAsString('untouched mirror');
      await alias.create(source.path);
      await expectLater(
        downloader.downloadToFile(url: source.path, destPath: alias.path),
        throwsArgumentError,
      );
      expect(await source.readAsString(), 'untouched mirror');
      expect(await alias.target(), source.path);
    },
    skip: Platform.isWindows
        ? 'Windows symlinks require host privileges'
        : false,
  );

  test('last-chunk cancellation removes partial copy', () async {
    final source = File(p.join(root.path, 'mirror.zst'));
    final dest = File(p.join(root.path, 'copy.zst'));
    final bytes = Uint8List(4096);
    await source.writeAsBytes(bytes);
    var cancelled = false;
    await expectLater(
      downloader.downloadToFile(
        url: source.path,
        destPath: dest.path,
        expectedSize: bytes.length,
        isCancelled: () => cancelled,
        onProgress: (copied, total) {
          if (copied == total) cancelled = true;
        },
      ),
      throwsA(isA<PatchDownloadCancelled>()),
    );
    expect(await dest.exists(), isFalse);
    expect(await source.readAsBytes(), bytes);
  });

  test('source growing during copy is bounded even without a hash', () async {
    final source = File(p.join(root.path, 'mirror.zst'));
    final dest = File(p.join(root.path, 'copy.zst'));
    const originalSize = 2 << 20;
    await source.writeAsBytes(Uint8List(originalSize));
    var changed = false;
    var highestCopied = 0;
    await expectLater(
      downloader.downloadToFile(
        url: source.path,
        destPath: dest.path,
        expectedSize: originalSize,
        onProgress: (copied, total) {
          highestCopied = copied;
          if (!changed) {
            changed = true;
            source.writeAsBytesSync(Uint8List(1 << 20), mode: FileMode.append);
          }
        },
      ),
      throwsA(isA<PatchDownloadException>()),
    );
    expect(highestCopied, lessThanOrEqualTo(originalSize));
    expect(await dest.exists(), isFalse);
    expect(await source.length(), 3 << 20);
  });

  test('source shrinking during copy is never accepted as complete', () async {
    final source = File(p.join(root.path, 'mirror.zst'));
    final dest = File(p.join(root.path, 'copy.zst'));
    const originalSize = 2 << 20;
    await source.writeAsBytes(Uint8List(originalSize));
    var changed = false;
    await expectLater(
      downloader.downloadToFile(
        url: source.path,
        destPath: dest.path,
        expectedSize: originalSize,
        onProgress: (copied, total) {
          if (!changed) {
            changed = true;
            final handle = source.openSync(mode: FileMode.append);
            try {
              handle.truncateSync(copied);
            } finally {
              handle.closeSync();
            }
          }
        },
      ),
      throwsA(anyOf(isA<PatchDownloadException>(), isA<FileSystemException>())),
    );
    expect(await dest.exists(), isFalse);
    expect(await source.length(), lessThan(originalSize));
  });
}
