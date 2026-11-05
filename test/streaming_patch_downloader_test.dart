import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory staging;
  final bytes = Uint8List.fromList(List.generate(8192, (i) => i % 251));

  setUp(() {
    root = Directory.systemTemp.createTempSync('streaming_patch_');
    staging = Directory(p.join(root.path, 'staging'));
  });
  tearDown(() => root.delete(recursive: true));

  PatchFileEntry entry({
    String name = 'patch.db.zst',
    int? outputSize,
    String? inputHash,
    String? outputHash,
  }) => PatchFileEntry(
    file: name,
    compression: 'zstd',
    sha256: inputHash ?? sha256.convert(bytes).toString(),
    size: bytes.length,
    uncompressedSha256: outputHash ?? sha256.convert(bytes).toString(),
    uncompressedSize: outputSize ?? bytes.length,
  );

  String compressedPath() => p.join(staging.path, 'patch.db.zst');
  String outputPath() => p.join(staging.path, 'patch.db');
  String partialPath() => '${outputPath()}.extracting';
  http.Client client({void Function()? requested}) =>
      MockClient.streaming((request, _) async {
        requested?.call();
        return http.StreamedResponse(
          Stream.value(bytes),
          200,
          contentLength: bytes.length,
          headers: {'etag': '"asset-1"'},
        );
      });

  test(
    'HTTP: streamed result is verified and published without an output read',
    () async {
      var observedLimit = 0;
      final progress = <(int, int)>[];
      final downloader = StreamingPatchDownloader(
        httpClient: client(),
        extractor:
            (
              source,
              destination, {
              required maxOutputBytes,
              isCancelled,
              onProgress,
            }) async {
              expect(File(outputPath()).existsSync(), isFalse);
              expect(destination, partialPath());
              expect(await File(source).readAsBytes(), bytes);
              observedLimit = maxOutputBytes;
              return _copyExtractor(
                source,
                destination,
                maxOutputBytes: maxOutputBytes,
                isCancelled: isCancelled,
                onProgress: onProgress,
              );
            },
      );
      final result = await downloader.downloadAndExtract(
        patchFile: entry(),
        downloadUrl: 'https://example.test/patch',
        destDir: staging,
        onExtractionProgress: (written, total) =>
            progress.add((written, total)),
      );
      expect(result, outputPath());
      expect(await File(result).readAsBytes(), bytes);
      expect(observedLimit, bytes.length);
      expect(progress.first, (0, bytes.length));
      expect(progress.last, (bytes.length, bytes.length));
      expect(File(partialPath()).existsSync(), isFalse);
      expect(File(compressedPath()).existsSync(), isFalse);
      expect(File('${compressedPath()}.resume').existsSync(), isFalse);
    },
  );

  test('local mirror source is preserved after verified extraction', () async {
    final source = File(p.join(root.path, 'mirror.db.zst'));
    await source.writeAsBytes(bytes);
    final downloader = StreamingPatchDownloader(extractor: _copyExtractor);
    addTearDown(downloader.dispose);
    final result = await downloader.downloadAndExtract(
      patchFile: entry(),
      downloadUrl: source.path,
      destDir: staging,
    );
    expect(await File(result).readAsBytes(), bytes);
    expect(await source.readAsBytes(), bytes);
  });

  test('compressed hash mismatch never invokes the decoder', () async {
    var invoked = false;
    final downloader = StreamingPatchDownloader(
      httpClient: client(),
      extractor:
          (
            source,
            destination, {
            required maxOutputBytes,
            isCancelled,
            onProgress,
          }) async {
            invoked = true;
            throw StateError('must not reach extraction');
          },
    );
    await expectLater(
      downloader.downloadAndExtract(
        patchFile: entry(inputHash: '00' * 32),
        downloadUrl: 'https://example.test/patch',
        destDir: staging,
      ),
      throwsA(isA<PatchDownloadException>()),
    );
    expect(invoked, isFalse);
    expect(File(compressedPath()).existsSync(), isFalse);
    expect(File(outputPath()).existsSync(), isFalse);
    expect(File(partialPath()).existsSync(), isFalse);
  });

  for (final failure in ['hash', 'reported size', 'actual size']) {
    test('$failure mismatch is rejected before publication', () async {
      final downloader = StreamingPatchDownloader(
        httpClient: client(),
        extractor:
            (
              source,
              destination, {
              required maxOutputBytes,
              isCancelled,
              onProgress,
            }) async {
              final result = await _copyExtractor(
                source,
                destination,
                maxOutputBytes: maxOutputBytes,
              );
              if (failure == 'actual size') {
                await File(destination).writeAsBytes([9]);
              }
              return FileExtractionResult(
                bytesWritten:
                    result.bytesWritten + (failure == 'reported size' ? 1 : 0),
                sha256: failure == 'hash' ? '00' * 32 : result.sha256,
              );
            },
      );
      await expectLater(
        downloader.downloadAndExtract(
          patchFile: entry(),
          downloadUrl: 'https://example.test/patch',
          destDir: staging,
        ),
        throwsA(isA<PatchDownloadException>()),
      );
      expect(File(outputPath()).existsSync(), isFalse);
      expect(File(partialPath()).existsSync(), isFalse);
      expect(File(compressedPath()).existsSync(), isFalse);
    });
  }

  test(
    'output limit is passed to decoder and no oversized chunk is written',
    () async {
      var largestWritten = 0;
      final downloader = StreamingPatchDownloader(
        httpClient: client(),
        extractor:
            (
              source,
              destination, {
              required maxOutputBytes,
              isCancelled,
              onProgress,
            }) => _copyExtractor(
              source,
              destination,
              maxOutputBytes: maxOutputBytes,
              onProgress: (written) => largestWritten = written,
            ),
      );
      await expectLater(
        downloader.downloadAndExtract(
          patchFile: entry(outputSize: 1500),
          downloadUrl: 'https://example.test/patch',
          destDir: staging,
        ),
        throwsA(isA<PatchDownloadException>()),
      );
      expect(largestWritten, 1024);
      expect(File(outputPath()).existsSync(), isFalse);
      expect(File(partialPath()).existsSync(), isFalse);
    },
  );

  test('decoder corruption removes partial output and invalid input', () async {
    final downloader = StreamingPatchDownloader(
      httpClient: client(),
      extractor:
          (
            source,
            destination, {
            required maxOutputBytes,
            isCancelled,
            onProgress,
          }) async {
            await File(destination).writeAsBytes([1, 2]);
            throw const FormatException('truncated compressed frame');
          },
    );
    await expectLater(
      downloader.downloadAndExtract(
        patchFile: entry(),
        downloadUrl: 'https://example.test/patch',
        destDir: staging,
      ),
      throwsFormatException,
    );
    expect(File(outputPath()).existsSync(), isFalse);
    expect(File(partialPath()).existsSync(), isFalse);
    expect(File(compressedPath()).existsSync(), isFalse);
  });

  test(
    'cancellation during extraction cleans output and reuses verified input',
    () async {
      var cancelled = false;
      var requests = 0;
      var decoderCalls = 0;
      final downloader = StreamingPatchDownloader(
        httpClient: client(requested: () => requests++),
        extractor:
            (
              source,
              destination, {
              required maxOutputBytes,
              isCancelled,
              onProgress,
            }) {
              decoderCalls++;
              return _copyExtractor(
                source,
                destination,
                maxOutputBytes: maxOutputBytes,
                isCancelled: isCancelled,
                onProgress: onProgress,
              );
            },
      );
      await expectLater(
        downloader.downloadAndExtract(
          patchFile: entry(),
          downloadUrl: 'https://example.test/patch',
          destDir: staging,
          isCancelled: () => cancelled,
          onExtractionProgress: (written, _) {
            if (written >= 2048) cancelled = true;
          },
        ),
        throwsA(isA<PatchDownloadCancelled>()),
      );
      expect(File(partialPath()).existsSync(), isFalse);
      expect(File(outputPath()).existsSync(), isFalse);
      expect(await File(compressedPath()).readAsBytes(), bytes);

      cancelled = false;
      final result = await downloader.downloadAndExtract(
        patchFile: entry(),
        downloadUrl: 'https://example.test/patch',
        destDir: staging,
      );
      expect(await File(result).readAsBytes(), bytes);
      expect(requests, 1);
      expect(decoderCalls, 2);
      expect(
        await downloader.findReusableExtracted(
          patchFile: entry(),
          destDir: staging,
        ),
        result,
      );
      expect(
        await downloader.downloadAndExtract(
          patchFile: entry(),
          downloadUrl: 'https://example.test/patch',
          destDir: staging,
        ),
        result,
      );
      expect(requests, 1);
      expect(decoderCalls, 2);
    },
  );

  test('cancellation just after decoder completion does not publish', () async {
    var cancelled = false;
    final downloader = StreamingPatchDownloader(
      httpClient: client(),
      extractor:
          (
            source,
            destination, {
            required maxOutputBytes,
            isCancelled,
            onProgress,
          }) async {
            final result = await _copyExtractor(
              source,
              destination,
              maxOutputBytes: maxOutputBytes,
            );
            cancelled = true;
            return result;
          },
    );
    await expectLater(
      downloader.downloadAndExtract(
        patchFile: entry(),
        downloadUrl: 'https://example.test/patch',
        destDir: staging,
        isCancelled: () => cancelled,
      ),
      throwsA(isA<PatchDownloadCancelled>()),
    );
    expect(File(outputPath()).existsSync(), isFalse);
    expect(File(partialPath()).existsSync(), isFalse);
  });

  test('reused cache respects cancellation from final download progress',
      () async {
    await staging.create();
    await File(outputPath()).writeAsBytes(bytes);
    await File(compressedPath()).writeAsBytes(bytes);
    var cancelled = false;
    final downloader = StreamingPatchDownloader(
      httpClient: client(requested: () => fail('cache should be reused')),
      extractor: _copyExtractor,
    );
    await expectLater(
      downloader.downloadAndExtract(
        patchFile: entry(),
        downloadUrl: 'https://example.test/patch',
        destDir: staging,
        isCancelled: () => cancelled,
        onProgress: (_, _) => cancelled = true,
      ),
      throwsA(isA<PatchDownloadCancelled>()),
    );
    expect(await File(outputPath()).readAsBytes(), bytes);
    expect(await File(compressedPath()).readAsBytes(), bytes);
  });

  test(
    'cancellation from final verification callback precedes publication',
    () async {
      var cancelled = false;
      final downloader = StreamingPatchDownloader(
        httpClient: client(),
        extractor: _copyExtractor,
      );
      await expectLater(
        downloader.downloadAndExtract(
          patchFile: entry(),
          downloadUrl: 'https://example.test/patch',
          destDir: staging,
          isCancelled: () => cancelled,
          onExtractionProgress: (_, _) {},
          onVerifyProgress: (_, _) => cancelled = true,
        ),
        throwsA(isA<PatchDownloadCancelled>()),
      );
      expect(File(outputPath()).existsSync(), isFalse);
      expect(File(partialPath()).existsSync(), isFalse);
      expect(await File(compressedPath()).readAsBytes(), bytes);
    },
  );

  test(
    'resource failure removes partial output but keeps verified archive',
    () async {
      final downloader = StreamingPatchDownloader(
        httpClient: client(),
        extractor:
            (
              source,
              destination, {
              required maxOutputBytes,
              isCancelled,
              onProgress,
            }) async {
              await File(destination).writeAsBytes([0]);
              throw StateError('native decoder unavailable');
            },
      );
      await expectLater(
        downloader.downloadAndExtract(
          patchFile: entry(),
          downloadUrl: 'https://example.test/patch',
          destDir: staging,
        ),
        throwsStateError,
      );
      expect(File(outputPath()).existsSync(), isFalse);
      expect(File(partialPath()).existsSync(), isFalse);
      expect(await File(compressedPath()).readAsBytes(), bytes);
    },
  );

  test('already cancelled request does not create or clean files', () async {
    final downloader = StreamingPatchDownloader(
      httpClient: client(requested: () => fail('must not request')),
      extractor: _copyExtractor,
    );
    await expectLater(
      downloader.downloadAndExtract(
        patchFile: entry(),
        downloadUrl: 'https://example.test/patch',
        destDir: staging,
        isCancelled: () => true,
      ),
      throwsA(isA<PatchDownloadCancelled>()),
    );
    expect(staging.existsSync(), isFalse);
  });

  test('network disconnect resumes before one verified extraction', () async {
    var requests = 0;
    final downloader = StreamingPatchDownloader(
      networkRetryDelays: const [Duration.zero],
      extractor: _copyExtractor,
      httpClient: MockClient.streaming((request, _) async {
        requests++;
        if (requests == 1) {
          return http.StreamedResponse(
            (() async* {
              yield Uint8List.sublistView(bytes, 0, 3072);
              throw const SocketException('connection interrupted');
            })(),
            200,
            contentLength: bytes.length,
            headers: {'etag': '"asset-1"'},
          );
        }
        expect(request.headers['range'], 'bytes=3072-');
        expect(request.headers['if-range'], '"asset-1"');
        return http.StreamedResponse(
          Stream.value(Uint8List.sublistView(bytes, 3072)),
          206,
          contentLength: bytes.length - 3072,
          headers: {
            'etag': '"asset-1"',
            'content-range': 'bytes 3072-${bytes.length - 1}/${bytes.length}',
          },
        );
      }),
    );
    final result = await downloader.downloadAndExtract(
      patchFile: entry(),
      downloadUrl: 'https://example.test/patch',
      destDir: staging,
    );
    expect(await File(result).readAsBytes(), bytes);
    expect(requests, 2);
  });

  test(
    'extraction holds both destination locks until cleanup completes',
    () async {
      final started = Completer<void>();
      final proceed = Completer<void>();
      final downloader = StreamingPatchDownloader(
        httpClient: client(),
        extractor:
            (
              source,
              destination, {
              required maxOutputBytes,
              isCancelled,
              onProgress,
            }) async {
              started.complete();
              await proceed.future;
              return _copyExtractor(
                source,
                destination,
                maxOutputBytes: maxOutputBytes,
              );
            },
      );
      final pending = downloader.downloadAndExtract(
        patchFile: entry(),
        downloadUrl: 'https://example.test/patch',
        destDir: staging,
      );
      await started.future;
      final contender = StreamingPatchDownloader(
        httpClient: client(requested: () => fail('contender made a request')),
        extractor: _copyExtractor,
      );
      try {
        await expectLater(
          contender.downloadAndExtract(
            patchFile: entry(),
            downloadUrl: 'https://example.test/patch',
            destDir: staging,
          ),
          throwsA(isA<PatchDownloadException>()),
        );
        await expectLater(
          contender.findReusableExtracted(patchFile: entry(), destDir: staging),
          throwsA(isA<PatchDownloadException>()),
        );
        await expectLater(
          contender.downloadToFile(
            url: 'https://example.test/patch',
            destPath: compressedPath(),
          ),
          throwsA(isA<PatchDownloadException>()),
        );
        expect(await File(compressedPath()).readAsBytes(), bytes);
      } finally {
        proceed.complete();
        await pending;
      }
      expect(
        await contender.findReusableExtracted(
          patchFile: entry(),
          destDir: staging,
        ),
        outputPath(),
      );
    },
  );

  for (final name in [
    '../live.db.zst',
    r'..\live.db.zst',
    '.zst',
    '..zst',
    '...zst',
    '/live.db.zst',
    r'C:\live.db.zst',
  ]) {
    test('unsafe manually constructed patch name is rejected: $name', () async {
      final downloader = StreamingPatchDownloader(
        httpClient: client(requested: () => fail('unsafe path was downloaded')),
        extractor: _copyExtractor,
      );
      await expectLater(
        downloader.downloadAndExtract(
          patchFile: entry(name: name),
          downloadUrl: 'https://example.test/patch',
          destDir: staging,
        ),
        throwsA(isA<PatchDownloadException>()),
      );
      expect(staging.existsSync(), isFalse);
    });
  }

  for (final target in ['patch.db.zst', 'patch.db', 'patch.db.extracting']) {
    test(
      'local source alias of $target is rejected without removing source',
      () async {
        await staging.create();
        final source = File(p.join(staging.path, target));
        await source.writeAsBytes(bytes);
        final downloader = StreamingPatchDownloader(extractor: _copyExtractor);
        addTearDown(downloader.dispose);
        await expectLater(
          downloader.downloadAndExtract(
            patchFile: entry(),
            downloadUrl: source.path,
            destDir: staging,
          ),
          throwsArgumentError,
        );
        expect(await source.readAsBytes(), bytes);
      },
    );
  }

  test('crashed temporary output is discarded and cannot be reused', () async {
    await staging.create();
    await File(partialPath()).writeAsBytes(bytes);
    var requests = 0;
    final downloader = StreamingPatchDownloader(
      httpClient: client(requested: () => requests++),
      extractor: _copyExtractor,
    );
    expect(
      await downloader.findReusableExtracted(
        patchFile: entry(),
        destDir: staging,
      ),
      isNull,
    );
    final result = await downloader.downloadAndExtract(
      patchFile: entry(),
      downloadUrl: 'https://example.test/patch',
      destDir: staging,
    );
    expect(requests, 1);
    expect(await File(result).readAsBytes(), bytes);
    expect(File(partialPath()).existsSync(), isFalse);
  });
}

/// Deliberately codec-independent: these tests cover the shared file lifecycle
/// and integrity contract; native zstd decoding is tested by each host backend.
Future<FileExtractionResult> _copyExtractor(
  String source,
  String destination, {
  required int maxOutputBytes,
  bool Function()? isCancelled,
  void Function(int bytesWritten)? onProgress,
}) async {
  final input = await File(source).open();
  final output = await File(destination).open(mode: FileMode.write);
  final hasher = Sha256Stream();
  final buffer = Uint8List(1024);
  var written = 0;
  try {
    for (
      var read = await input.readInto(buffer);
      read > 0;
      read = await input.readInto(buffer)
    ) {
      if (isCancelled?.call() ?? false) throw const PatchDownloadCancelled();
      if (written + read > maxOutputBytes) {
        throw const PatchDownloadException('output limit exceeded');
      }
      await output.writeFrom(buffer, 0, read);
      hasher.addSlice(buffer, 0, read);
      written += read;
      onProgress?.call(written);
    }
    if (isCancelled?.call() ?? false) throw const PatchDownloadCancelled();
    await output.flush();
    return FileExtractionResult(bytesWritten: written, sha256: hasher.close());
  } finally {
    hasher.dispose();
    await input.close();
    await output.close();
  }
}
