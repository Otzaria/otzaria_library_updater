import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:test/test.dart';

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

class _Fixture {
  _Fixture(int length) {
    bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = (i * 31 + (i >> 9)) & 0xff;
    }
    parts = [
      Uint8List.sublistView(bytes, 0, length ~/ 2),
      Uint8List.sublistView(bytes, length ~/ 2),
    ];
    split = SplitAsset(
      archive: 'full.db.zst',
      size: bytes.length,
      sha256: _sha(bytes),
      manifestName: 'full.db.zst.manifest.json',
      parts: [
        for (var i = 0; i < parts.length; i++)
          SplitAssetPart(
            name: 'full.db.zst.part-${i.toString().padLeft(3, '0')}',
            size: parts[i].length,
            sha256: _sha(parts[i]),
            downloadUrl: 'https://example.test/part-$i',
          ),
      ],
    );
  }

  late final Uint8List bytes;
  late final List<Uint8List> parts;
  late final SplitAsset split;

  PatchDownloader downloader(List<int> requests) => PatchDownloader(
    decompress: (bytes) async => bytes,
    networkRetryDelays: const [],
    httpClient: MockClient.streaming((request, _) async {
      final index = int.parse(request.url.path.split('-').last);
      requests.add(index);
      return http.StreamedResponse(
        Stream.value(parts[index]),
        200,
        contentLength: parts[index].length,
        headers: {'etag': '"part-$index"'},
      );
    }),
  );

  SplitAsset withMetadata({int? size, String? sha256}) => SplitAsset(
    archive: split.archive,
    size: size ?? split.size,
    sha256: sha256 ?? split.sha256,
    manifestName: split.manifestName,
    parts: split.parts,
  );

  void expectPartsRetained(String destination, {bool sidecars = true}) {
    for (var i = 0; i < parts.length; i++) {
      final path = PatchDownloader.splitPartPath(destination, i);
      expect(File(path).existsSync(), isTrue, reason: 'part $i');
      expect(_sha(File(path).readAsBytesSync()), split.parts[i].sha256);
      expect(File('$path.resume').existsSync(), sidecars);
    }
  }
}

final class _PublicationIO extends IOOverrides {
  _PublicationIO(this.staging, {this.beforeRename, this.afterRename});

  final String staging;
  final FutureOr<void> Function()? beforeRename;
  final void Function()? afterRename;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path == staging ? _PublicationFile(file, this) : file;
  }
}

class _PublicationFile implements File {
  _PublicationFile(this.file, this.owner);

  final File file;
  final _PublicationIO owner;

  @override
  String get path => file.path;

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);

  @override
  Future<File> rename(String newPath) async {
    await owner.beforeRename?.call();
    final result = await file.rename(newPath);
    owner.afterRename?.call();
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'unexpected file operation: ${invocation.memberName}',
  );
}

void main() {
  late Directory temp;
  late String destination;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('split_assembly_cancellation');
    destination = '${temp.path}/full.db.zst';
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test(
    'cancelling during split assembly retains parts for an offline retry',
    () async {
      final fixture = _Fixture((12 << 20) + 17);
      final requests = <int>[];
      final downloader = fixture.downloader(requests);
      addTearDown(downloader.dispose);
      var cancelled = false;
      var cancelledAt = 0;

      await expectLater(
        downloader.downloadSplitToFile(
          split: fixture.split,
          destPath: destination,
          resumeToken: 'v1',
          onAssembleProgress: (done, total) {
            if (done > 0 && done < total && !cancelled) {
              cancelledAt = done;
              cancelled = true;
            }
          },
          isCancelled: () => cancelled,
        ),
        throwsA(isA<PatchDownloadCancelled>()),
      );

      expect(cancelledAt, greaterThan(0));
      expect(cancelledAt, lessThan(fixture.bytes.length));
      expect(File(destination).existsSync(), isFalse);
      expect(File('$destination.joining').existsSync(), isFalse);
      fixture.expectPartsRetained(destination);
      expect(requests, [0, 1]);

      cancelled = false;
      await downloader.downloadSplitToFile(
        split: fixture.split,
        destPath: destination,
        resumeToken: 'v1',
        isCancelled: () => cancelled,
      );
      expect(requests, [
        0,
        1,
      ], reason: 'verified parts must not be downloaded again');
      expect(_sha(File(destination).readAsBytesSync()), fixture.split.sha256);
      expect(File('$destination.joining').existsSync(), isFalse);
      for (var i = 0; i < fixture.parts.length; i++) {
        final part = PatchDownloader.splitPartPath(destination, i);
        expect(File(part).existsSync(), isFalse);
        expect(File('$part.resume').existsSync(), isFalse);
        expect(File('$part.lock').existsSync(), isTrue);
      }
    },
  );

  test(
    'cancellation from final assembly progress prevents publication',
    () async {
      // A short join finishes before the cancellation timer can fire. The final
      // progress callback must be delivered before the caller commits the file.
      final fixture = _Fixture(51);
      final downloader = fixture.downloader([]);
      addTearDown(downloader.dispose);
      var cancelled = false;

      await expectLater(
        downloader.downloadSplitToFile(
          split: fixture.split,
          destPath: destination,
          resumeToken: 'v1',
          onAssembleProgress: (done, total) {
            if (done == total) cancelled = true;
          },
          isCancelled: () => cancelled,
        ),
        throwsA(isA<PatchDownloadCancelled>()),
      );

      expect(cancelled, isTrue);
      expect(File(destination).existsSync(), isFalse);
      expect(File('$destination.joining').existsSync(), isFalse);
      fixture.expectPartsRetained(destination);
    },
  );

  test(
    'a microtask from final progress can cancel before publication',
    () async {
      final fixture = _Fixture(51);
      final downloader = fixture.downloader([]);
      addTearDown(downloader.dispose);
      var cancelled = false;
      await expectLater(
        downloader.downloadSplitToFile(
          split: fixture.split,
          destPath: destination,
          resumeToken: 'v1',
          onAssembleProgress: (done, total) {
            if (done == total) scheduleMicrotask(() => cancelled = true);
          },
          isCancelled: () => cancelled,
        ),
        throwsA(isA<PatchDownloadCancelled>()),
      );
      expect(File(destination).existsSync(), isFalse);
      expect(File('$destination.joining').existsSync(), isFalse);
      fixture.expectPartsRetained(destination);
    },
  );

  for (final failure in ['hash', 'too much output', 'truncated output']) {
    test(
      'joined $failure retains parts for a freshly verified retry',
      () async {
        final fixture = _Fixture(51);
        final requests = <int>[];
        final downloader = fixture.downloader(requests);
        addTearDown(downloader.dispose);
        final invalid = switch (failure) {
          'hash' => fixture.withMetadata(sha256: '0' * 64),
          'too much output' => fixture.withMetadata(size: 50),
          _ => fixture.withMetadata(size: 52),
        };
        await expectLater(
          downloader.downloadSplitToFile(
            split: invalid,
            destPath: destination,
            resumeToken: 'v1',
          ),
          throwsA(isA<PatchDownloadException>()),
        );
        expect(File(destination).existsSync(), isFalse);
        expect(File('$destination.joining').existsSync(), isFalse);
        fixture.expectPartsRetained(destination, sidecars: false);
        await downloader.downloadSplitToFile(
          split: fixture.split,
          destPath: destination,
          resumeToken: 'v1',
        );
        expect(requests, [0, 1]);
        expect(File(destination).readAsBytesSync(), fixture.bytes);
      },
    );
  }

  test(
    'failed joined hash invalidates an unchanged corrupt part marker',
    () async {
      final fixture = _Fixture(51);
      final requests = <int>[];
      final downloader = fixture.downloader(requests);
      addTearDown(downloader.dispose);
      var corrupted = false;
      await expectLater(
        downloader.downloadSplitToFile(
          split: fixture.split,
          destPath: destination,
          resumeToken: 'v1',
          onPartProgress: (part, done, total) {
            if (part != 1 || done != total || corrupted) return;
            corrupted = true;
            final first = File(PatchDownloader.splitPartPath(destination, 0));
            final modified = first.lastModifiedSync();
            first.writeAsBytesSync(Uint8List(fixture.parts[0].length));
            // Simulate a coarse-timestamp filesystem: size and mtime still match
            // the fast verified marker even though the payload has changed.
            first.setLastModifiedSync(modified);
          },
        ),
        throwsA(isA<PatchDownloadException>()),
      );
      expect(corrupted, isTrue);
      expect(File(destination).existsSync(), isFalse);
      expect(File('$destination.joining').existsSync(), isFalse);
      await downloader.downloadSplitToFile(
        split: fixture.split,
        destPath: destination,
        resumeToken: 'v1',
      );
      expect(requests, [
        0,
        1,
        0,
      ], reason: 'only the corrupt part is fetched again');
      expect(File(destination).readAsBytesSync(), fixture.bytes);
    },
  );

  test(
    'publication failure retains parts and releases the destination lock',
    () async {
      final fixture = _Fixture(51);
      final requests = <int>[];
      final downloader = fixture.downloader(requests);
      addTearDown(downloader.dispose);
      final io = _PublicationIO(
        '$destination.joining',
        beforeRename: () => throw const FileSystemException('rename failed'),
      );
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => downloader.downloadSplitToFile(
            split: fixture.split,
            destPath: destination,
            resumeToken: 'v1',
          ),
          io,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(destination).existsSync(), isFalse);
      expect(File('$destination.joining').existsSync(), isFalse);
      expect(File('$destination.resume').existsSync(), isFalse);
      fixture.expectPartsRetained(destination);
      await downloader.downloadSplitToFile(
        split: fixture.split,
        destPath: destination,
        resumeToken: 'v1',
      );
      expect(requests, [0, 1]);
      expect(File(destination).readAsBytesSync(), fixture.bytes);
    },
  );

  test('a committed archive cannot become a reported cancellation', () async {
    final fixture = _Fixture(51);
    final downloader = fixture.downloader([]);
    addTearDown(downloader.dispose);
    var committed = false;
    var checksAfterCommit = 0;
    var callbacksAfterCommit = 0;
    final io = _PublicationIO(
      '$destination.joining',
      afterRename: () => committed = true,
    );
    await IOOverrides.runWithIOOverrides(
      () => downloader.downloadSplitToFile(
        split: fixture.split,
        destPath: destination,
        resumeToken: 'v1',
        onAssembleProgress: (_, _) {
          if (committed) callbacksAfterCommit++;
        },
        isCancelled: () {
          if (committed) checksAfterCommit++;
          return committed;
        },
      ),
      io,
    );
    expect(committed, isTrue);
    expect(checksAfterCommit, 0);
    expect(callbacksAfterCommit, 0);
    expect(File(destination).readAsBytesSync(), fixture.bytes);
  });

  test('cancellation during asynchronous publication still succeeds', () async {
    final fixture = _Fixture(51);
    final downloader = fixture.downloader([]);
    addTearDown(downloader.dispose);
    final renameStarted = Completer<void>();
    final finishRename = Completer<void>();
    var cancelled = false;
    final io = _PublicationIO(
      '$destination.joining',
      beforeRename: () async {
        renameStarted.complete();
        await finishRename.future;
      },
    );
    final operation = IOOverrides.runWithIOOverrides(
      () => downloader.downloadSplitToFile(
        split: fixture.split,
        destPath: destination,
        resumeToken: 'v1',
        isCancelled: () => cancelled,
      ),
      io,
    );
    await renameStarted.future;
    expect(File(destination).existsSync(), isFalse);
    await expectLater(
      downloader.downloadSplitToFile(
        split: fixture.split,
        destPath: destination,
        resumeToken: 'v1',
      ),
      throwsA(isA<PatchDownloadException>()),
    );
    cancelled = true;
    finishRename.complete();
    await operation;
    expect(File(destination).readAsBytesSync(), fixture.bytes);
    expect(File('$destination.joining').existsSync(), isFalse);
  });

  test('the destination remains locked during assembly callbacks', () async {
    final fixture = _Fixture(51);
    final requests = <int>[];
    final downloader = fixture.downloader(requests);
    final second = fixture.downloader(requests);
    addTearDown(downloader.dispose);
    addTearDown(second.dispose);
    Future<void>? competing;
    await downloader.downloadSplitToFile(
      split: fixture.split,
      destPath: destination,
      resumeToken: 'v1',
      onAssembleProgress: (_, _) {
        competing ??= expectLater(
          second.downloadSplitToFile(
            split: fixture.split,
            destPath: destination,
            resumeToken: 'v1',
          ),
          throwsA(isA<PatchDownloadException>()),
        );
      },
    );
    expect(competing, isNotNull);
    await competing;
    expect(requests, [0, 1]);
    expect(File(destination).readAsBytesSync(), fixture.bytes);
  });
}
