import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/testing.dart';
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:test/test.dart';

final class _AsyncCleanup extends IOOverrides {
  _AsyncCleanup(this.directory, this.paths);

  final String directory;
  final Set<String> paths;
  final List<String> deleted = [];
  var synchronousDeletes = 0;
  var synchronousLists = 0;
  var listing = false;
  var deletedWhileListing = false;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return paths.contains(path) ? _CleanupFile(file, this) : file;
  }

  @override
  Directory createDirectory(String path) {
    final dir = super.createDirectory(path);
    return path == directory ? _CleanupDirectory(dir, this) : dir;
  }
}

class _CleanupFile implements File {
  _CleanupFile(this.file, this.owner);

  final File file;
  final _AsyncCleanup owner;

  @override
  String get path => file.path;

  @override
  Future<bool> exists() => file.exists();

  @override
  bool existsSync() => file.existsSync();

  @override
  Future<String> resolveSymbolicLinks() => file.resolveSymbolicLinks();

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      file.open(mode: mode);

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    owner.deletedWhileListing |= owner.listing;
    final result = await file.delete(recursive: recursive);
    owner.deleted.add(path);
    return result;
  }

  @override
  void deleteSync({bool recursive = false}) {
    owner.synchronousDeletes++;
    throw UnsupportedError('large-file cleanup must be asynchronous');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'unexpected file operation: ${invocation.memberName}',
  );
}

class _CleanupDirectory implements Directory {
  _CleanupDirectory(this.directory, this.owner);

  final Directory directory;
  final _AsyncCleanup owner;

  @override
  Future<bool> exists() => directory.exists();

  @override
  bool existsSync() => directory.existsSync();

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    owner.listing = true;
    try {
      yield* directory.list(recursive: recursive, followLinks: followLinks);
    } finally {
      owner.listing = false;
    }
  }

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) {
    owner.synchronousLists++;
    throw UnsupportedError('split cleanup must enumerate asynchronously');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'unexpected directory operation: ${invocation.memberName}',
  );
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('async_download_cleanup');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  PatchDownloader downloader() {
    final value = PatchDownloader(
      decompress: (bytes) async => bytes,
      httpClient: MockClient(
        (_) async => throw StateError('unexpected network'),
      ),
    );
    addTearDown(value.dispose);
    return value;
  }

  for (final outcome in ['success', 'cancellation', 'hash failure']) {
    test('local copy uses asynchronous cleanup on $outcome', () async {
      final source = File('${temp.path}/source.zst');
      final destination = File('${temp.path}/destination.zst');
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      source.writeAsBytesSync(bytes);
      destination.writeAsStringSync('old destination');
      final io = _AsyncCleanup(temp.path, {destination.path});
      var cancelled = false;

      final operation = IOOverrides.runWithIOOverrides(
        () => downloader().downloadToFile(
          url: source.path,
          destPath: destination.path,
          expectedSha256: outcome == 'hash failure'
              ? '0' * 64
              : sha256.convert(bytes).toString(),
          onProgress: (_, _) => cancelled = outcome == 'cancellation',
          isCancelled: () => cancelled,
        ),
        io,
      );
      if (outcome == 'success') {
        await operation;
        expect(destination.readAsBytesSync(), bytes);
      } else {
        await expectLater(
          operation,
          throwsA(
            outcome == 'cancellation'
                ? isA<PatchDownloadCancelled>()
                : isA<PatchDownloadException>(),
          ),
        );
        expect(destination.existsSync(), isFalse);
      }
      expect(io.synchronousDeletes, 0);
      expect(io.deleted, isNotEmpty);
      expect(source.readAsBytesSync(), bytes);
    });
  }

  test(
    'reusing a joined archive asynchronously removes leftover split parts',
    () async {
      final destination = '${temp.path}/full.db.zst';
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final digest = sha256.convert(bytes).toString();
      File(destination).writeAsBytesSync(bytes);
      File('$destination.resume').writeAsStringSync('v1|joined:$digest');
      final paths = <String>{};
      for (final index in [0, 7]) {
        final part = PatchDownloader.splitPartPath(destination, index);
        File(part).writeAsBytesSync(bytes);
        File('$part.resume').writeAsStringSync('previous part');
        File('$part.lock').writeAsStringSync('persistent lock');
        paths.addAll([part, '$part.resume']);
      }
      final io = _AsyncCleanup(temp.path, paths);
      await IOOverrides.runWithIOOverrides(
        () => downloader().downloadSplitToFile(
          split: SplitAsset(
            archive: 'full.db.zst',
            size: bytes.length,
            sha256: digest,
            manifestName: 'full.db.zst.manifest.json',
            parts: [
              SplitAssetPart(
                name: 'part-0',
                size: bytes.length,
                sha256: digest,
                downloadUrl: 'https://example.test/part-0',
              ),
            ],
          ),
          destPath: destination,
          resumeToken: 'v1',
        ),
        io,
      );
      expect(io.synchronousLists, 0);
      expect(io.deletedWhileListing, isFalse);
      expect(io.synchronousDeletes, 0);
      expect(io.deleted, unorderedEquals(paths));
      expect(File(destination).readAsBytesSync(), bytes);
      for (final index in [0, 7]) {
        expect(
          File(
            '${PatchDownloader.splitPartPath(destination, index)}.lock',
          ).readAsStringSync(),
          'persistent lock',
        );
      }
    },
  );
}
