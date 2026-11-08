import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:test/test.dart';

const _archive = 'seforim.db.zst';
const _manifest = '$_archive.manifest.json';
String _partName(int index) =>
    '$_archive.part-${index.toString().padLeft(3, '0')}';
String _hex(List<int> bytes) => sha256.convert(bytes).toString();

class _Fixture {
  _Fixture(this.root, {int? freeBytes, int sizeAdjustment = 0}) {
    final body = <String, List<int>>{
      for (var i = 0; i < parts.length; i++) _partName(i): parts[i],
      _manifest: utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'archive': _archive,
          'size': whole.length,
          'sha256': _hex(whole),
          'parts': [
            for (var i = 0; i < parts.length; i++)
              {
                'name': _partName(i),
                'size': parts[i].length,
                'sha256': _hex(parts[i]),
              },
          ],
        }),
      ),
    };
    final releases = [
      {
        'tag_name': 'v5',
        'prerelease': false,
        'draft': false,
        'published_at': '2026-09-01T00:00:00Z',
        'assets': [
          for (final entry in body.entries)
            {
              'name': entry.key,
              'browser_download_url': 'https://example.test/v5/${entry.key}',
              'size': entry.value.length,
              'digest': 'sha256:${_hex(entry.value)}',
            },
        ],
      },
    ];
    client = MockClient.streaming((request, _) async {
      final List<int> bytes;
      if (request.url.host == 'api.github.com') {
        bytes = utf8.encode(
          jsonEncode(
            request.url.queryParameters['page'] == '1' ? releases : [],
          ),
        );
      } else {
        final name = request.url.pathSegments.last;
        fetched.add(name);
        bytes = body[name]!;
      }
      return http.StreamedResponse(
        Stream.value(bytes),
        200,
        contentLength: bytes.length,
      );
    });
    exporter = LibraryMirrorExporter(
      supportedDbSchemaVersion: kSupportedDbSchemaVersion,
      client: _ResolvedSizeClient(client, sizeAdjustment),
      httpClient: client,
      freeBytesFor: (_) => freeBytes,
    );
  }

  final Directory root;
  final parts = [
    Uint8List(32)..fillRange(0, 32, 1),
    Uint8List(24)..fillRange(0, 24, 2),
  ];
  final fetched = <String>[];
  late final http.Client client;
  late final LibraryMirrorExporter exporter;

  List<int> get whole => [...parts[0], ...parts[1]];
  List<int> get previous => List.filled(whole.length, 9);
  String get destDir => p.join(root.path, 'mirror');
  String get destination => p.join(destDir, 'assets', 'v5', _archive);
  String get partsDir => LibraryMirrorExporter.splitPartsDir(destination);
  String get temporary => p.join(partsDir, '$_archive.assembling');
  File part(int index) => File(p.join(partsDir, _partName(index)));
  String stage(int percent) =>
      LibraryUpdaterMessages.current.exportAssembling('v5', _archive, percent);

  void seedPrevious([List<int>? bytes]) {
    File(destination).parent.createSync(recursive: true);
    File(destination).writeAsBytesSync(bytes ?? previous);
  }

  void expectPreviousAndNoTemporary() {
    expect(File(destination).readAsBytesSync(), previous);
    expect(File(temporary).existsSync(), isFalse);
    expect(
      File(PatchDownloader.resumeSidecarPath(destination)).existsSync(),
      isFalse,
    );
  }

  void expectRetainedParts() {
    for (var i = 0; i < parts.length; i++) {
      expect(part(i).readAsBytesSync(), parts[i]);
    }
  }

  void dispose() {
    exporter.dispose();
    client.close();
  }
}

class _ResolvedSizeClient extends GithubLibraryReleaseClient {
  _ResolvedSizeClient(http.Client client, this.adjustment)
    : super(httpClient: client);
  final int adjustment;

  @override
  Future<ReleaseAsset> resolveSplitAsset(
    LibraryRelease release,
    ReleaseAsset asset,
  ) async {
    final resolved = await super.resolveSplitAsset(release, asset);
    if (adjustment == 0) return resolved;
    final split = resolved.split!;
    return ReleaseAsset.fromSplit(
      asset,
      SplitAsset(
        archive: split.archive,
        size: split.size + adjustment,
        sha256: split.sha256,
        manifestName: split.manifestName,
        parts: split.parts,
      ),
    );
  }
}

final class _AssemblyIo extends IOOverrides {
  _AssemblyIo(this.target, {this.onOpen, this.afterFlush, this.failure});

  final String target;
  final void Function()? onOpen;
  final void Function()? afterFlush;
  final String? failure;
  var closed = true;
  var written = 0;
  var writes = 0;
  var synchronousDeletes = 0;
  var deletedWhileOpen = false;
  var asynchronousDeletes = 0;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path == target ? _AssemblyFile(file, this) : file;
  }
}

class _AssemblyFile implements File {
  _AssemblyFile(this.file, this.owner);
  final File file;
  final _AssemblyIo owner;

  @override
  String get path => file.path;
  @override
  bool existsSync() => file.existsSync();
  @override
  Future<bool> exists() => file.exists();

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    final handle = await file.open(mode: mode);
    owner.closed = false;
    owner.onOpen?.call();
    return _AssemblyHandle(handle, owner);
  }

  @override
  Future<File> rename(String newPath) async {
    if (owner.failure == 'rename') {
      throw FileSystemException('rename failed', path);
    }
    return file.rename(newPath);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    owner.asynchronousDeletes++;
    owner.deletedWhileOpen |= !owner.closed;
    return file.delete(recursive: recursive);
  }

  @override
  void deleteSync({bool recursive = false}) {
    owner.synchronousDeletes++;
    owner.deletedWhileOpen |= !owner.closed;
    file.deleteSync(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class _AssemblyHandle implements RandomAccessFile {
  _AssemblyHandle(this.file, this.owner);
  final RandomAccessFile file;
  final _AssemblyIo owner;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    owner.writes++;
    if (owner.failure == 'write' && owner.writes == 2) {
      throw FileSystemException('write failed', owner.target);
    }
    await file.writeFrom(buffer, start, end);
    owner.written += (end ?? buffer.length) - start;
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    await file.flush();
    owner.afterFlush?.call();
    if (owner.failure == 'flush') {
      throw FileSystemException('flush failed', owner.target);
    }
    return this;
  }

  @override
  Future<void> close() async {
    await file.close();
    owner.closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mirror_assembly_safety');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  _Fixture build({int? freeBytes, int sizeAdjustment = 0}) {
    final fixture = _Fixture(
      root,
      freeBytes: freeBytes,
      sizeAdjustment: sizeAdjustment,
    );
    addTearDown(fixture.dispose);
    return fixture;
  }

  test(
    'successful assembly replaces the old output and keeps only part locks',
    () async {
      final f = build()..seedPrevious();
      expect(await f.exporter.export(destDir: f.destDir), isTrue);
      expect(File(f.destination).readAsBytesSync(), f.whole);
      expect(
        Directory(f.partsDir).listSync().map((e) => p.basename(e.path)),
        unorderedEquals([
          for (var i = 0; i < f.parts.length; i++) '${_partName(i)}.lock',
        ]),
      );
      expect(
        File(PatchDownloader.resumeSidecarPath(f.destination)).existsSync(),
        isTrue,
      );
    },
  );

  for (final when in ['last progress', 'flush']) {
    test(
      'cancellation at $when preserves the old output and all verified parts',
      () async {
        final f = build()..seedPrevious();
        var cancelled = false;
        final io = _AssemblyIo(
          f.temporary,
          afterFlush: () {
            if (when == 'flush') cancelled = true;
          },
        );
        await expectLater(
          IOOverrides.runWithIOOverrides(
            () => f.exporter.export(
              destDir: f.destDir,
              onStage: (stage) {
                if (when == 'last progress' && stage == f.stage(100)) {
                  cancelled = true;
                }
              },
              isCancelled: () => cancelled,
            ),
            io,
          ),
          throwsA(isA<StateError>()),
        );
        expect(cancelled, isTrue);
        f.expectPreviousAndNoTemporary();
        f.expectRetainedParts();
        expect(io.closed, isTrue);
        expect(io.deletedWhileOpen, isFalse);
        expect(io.synchronousDeletes, 0);
        expect(io.asynchronousDeletes, greaterThan(0));
        f.fetched.clear();
        expect(await f.exporter.export(destDir: f.destDir), isTrue);
        expect(f.fetched.where((name) => name.contains('.part-')), isEmpty);
        expect(File(f.destination).readAsBytesSync(), f.whole);
      },
    );
  }

  for (final failure in ['callback', 'write', 'flush', 'rename']) {
    test(
      '$failure failure closes and removes staging while retaining the old output',
      () async {
        final f = build()..seedPrevious();
        final io = _AssemblyIo(f.temporary, failure: failure);
        await expectLater(
          IOOverrides.runWithIOOverrides(
            () => f.exporter.export(
              destDir: f.destDir,
              onStage: (stage) {
                if (failure == 'callback' && stage == f.stage(100)) {
                  throw StateError('callback failed');
                }
              },
            ),
            io,
          ),
          throwsA(anyOf(isA<StateError>(), isA<FileSystemException>())),
        );
        f.expectPreviousAndNoTemporary();
        f.expectRetainedParts();
        expect(io.closed, isTrue);
        expect(io.deletedWhileOpen, isFalse);
        expect(io.synchronousDeletes, 0);
        expect(io.asynchronousDeletes, greaterThan(0));
      },
    );
  }

  for (final corruption in ['grows', 'shrinks', 'same size']) {
    test(
      'a part that $corruption after verification cannot replace old output',
      () async {
        final f = build()..seedPrevious();
        final io = _AssemblyIo(
          f.temporary,
          onOpen: () {
            final bytes = switch (corruption) {
              'grows' => [...f.parts[1], 3],
              'shrinks' => f.parts[1].sublist(1),
              _ => List.filled(f.parts[1].length, 3),
            };
            f.part(1).writeAsBytesSync(bytes);
          },
        );
        await expectLater(
          IOOverrides.runWithIOOverrides(
            () => f.exporter.export(destDir: f.destDir),
            io,
          ),
          throwsA(isA<StateError>()),
        );
        expect(io.written, lessThanOrEqualTo(f.whole.length));
        if (corruption == 'grows') expect(io.written, f.parts[0].length);
        f.expectPreviousAndNoTemporary();
        expect(f.part(0).readAsBytesSync(), f.parts[0]);
        expect(f.part(1).existsSync(), isFalse);
        expect(
          File(
            p.join(f.destDir, LibraryMirrorExporter.rejectedSplitsFileName),
          ).existsSync(),
          isFalse,
        );
        expect(io.deletedWhileOpen, isFalse);
        expect(io.synchronousDeletes, 0);
        f.fetched.clear();
        expect(await f.exporter.export(destDir: f.destDir), isTrue);
        expect(f.fetched.where((name) => name.contains('.part-')), [
          _partName(1),
        ]);
        expect(File(f.destination).readAsBytesSync(), f.whole);
      },
    );
  }

  for (final adjustment in [-1, 1]) {
    test(
      'resolved archive size adjustment $adjustment is enforced while assembling',
      () async {
        final f = build(sizeAdjustment: adjustment)..seedPrevious();
        final io = _AssemblyIo(f.temporary);
        await expectLater(
          IOOverrides.runWithIOOverrides(
            () => f.exporter.export(destDir: f.destDir),
            io,
          ),
          throwsA(isA<StateError>()),
        );
        expect(io.written, lessThanOrEqualTo(f.whole.length + adjustment));
        f.expectPreviousAndNoTemporary();
        f.expectRetainedParts();
        expect(io.deletedWhileOpen, isFalse);
        expect(io.synchronousDeletes, 0);
      },
    );
  }

  test(
    'equal-sized unverified output gets no staging credit in space preflight',
    () async {
      const needed = 2 * (32 + 24);
      final f = build(
        freeBytes: needed + DiskSpaceProbe.defaultHeadroomBytes - 1,
      )..seedPrevious();
      await expectLater(
        f.exporter.export(destDir: f.destDir),
        throwsA(isA<StateError>()),
      );
      expect(f.fetched.where((name) => name.contains('.part-')), isEmpty);
      f.expectPreviousAndNoTemporary();
    },
  );

  test(
    'verified assembled output needs no staging space or part downloads',
    () async {
      final f = build(freeBytes: 0);
      f.seedPrevious(f.whole);
      expect(await f.exporter.export(destDir: f.destDir), isTrue);
      expect(f.fetched.where((name) => name.contains('.part-')), isEmpty);
      expect(File(f.destination).readAsBytesSync(), f.whole);
    },
  );
}
