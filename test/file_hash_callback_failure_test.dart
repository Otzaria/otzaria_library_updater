import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:test/test.dart';

void main() {
  test(
    'cached verification callback failure settles worker and preserves cache',
    () async {
      final root = await Directory.systemTemp.createTemp('hash_callback_');
      addTearDown(() => root.delete(recursive: true));
      final cached = File(p.join(root.path, 'patch.db'));
      final bytes = Uint8List(8 << 20);
      await cached.writeAsBytes(bytes);
      final entry = PatchFileEntry(
        file: 'patch.db.zst',
        compression: 'zstd',
        sha256: '00' * 32,
        size: 1,
        uncompressedSha256: Sha256Stream.ofBytes(bytes),
        uncompressedSize: bytes.length,
      );
      final downloader = StreamingPatchDownloader(
        extractor:
            (
              source,
              output, {
              required maxOutputBytes,
              isCancelled,
              onProgress,
            }) async => throw StateError('cached verification must not decode'),
      );
      addTearDown(downloader.dispose);
      final failure = StateError('progress listener failed');
      final escaped = <Object>[];
      await runZonedGuarded(() async {
        await expectLater(
          downloader.findReusableExtracted(
            patchFile: entry,
            destDir: root,
            onVerifyProgress: (done, _) {
              if (done > 0) throw failure;
            },
          ),
          throwsA(same(failure)),
        );
      }, (error, stack) => escaped.add(error));
      expect(escaped, isEmpty);
      expect(await cached.length(), bytes.length);
      // A completed future must mean the worker released its handle, including
      // on Windows where an outstanding reader would prevent this rename.
      final renamed = await cached.rename('${cached.path}.closed');
      await renamed.rename(cached.path);
      expect(
        await downloader.findReusableExtracted(patchFile: entry, destDir: root),
        cached.path,
      );
    },
  );
}
