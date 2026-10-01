import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seforim_library_updater/src/models/library_release.dart';
import 'package:seforim_library_updater/src/models/split_asset.dart';
import 'package:seforim_library_updater/src/services/github_library_release_client.dart';
import 'package:seforim_library_updater/src/services/library_update_discovery.dart';
import 'package:seforim_library_updater/src/services/patch_downloader.dart';
import 'package:test/test.dart';

const _archive = 'seforim-schema6.db.zst';
const _manifestName = '$_archive.manifest.json';

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// ארכיון של 50 בייטים בשלושה חלקים (20+20+10), בצורת split_release_asset.sh.
final Uint8List _full = Uint8List.fromList(List.generate(50, (i) => i * 3));
final List<Uint8List> _parts = [
  Uint8List.sublistView(_full, 0, 20),
  Uint8List.sublistView(_full, 20, 40),
  Uint8List.sublistView(_full, 40),
];

String _partName(int i) => '$_archive.part-${i.toString().padLeft(3, '0')}';

Map<String, Object?> _manifestJson({String? wholeSha, List<int>? sizes}) => {
      'schemaVersion': 1,
      'archive': _archive,
      'size': _full.length,
      'sha256': wholeSha ?? _sha(_full),
      'partSizeLimit': 20,
      'githubAssetLimit': kGithubAssetLimit,
      'parts': [
        for (var i = 0; i < _parts.length; i++)
          {
            'name': _partName(i),
            'size': sizes?[i] ?? _parts[i].length,
            'sha256': _sha(_parts[i]),
          },
      ],
    };

Map<String, String> get _partUrls => {
      for (var i = 0; i < _parts.length; i++)
        _partName(i): 'https://x/${_partName(i)}'
    };

SplitAsset _split({String? wholeSha}) => SplitAsset.fromManifestJson(
      _manifestJson(wholeSha: wholeSha),
      manifestName: _manifestName,
      partUrls: _partUrls,
    );

void main() {
  group('SplitAsset.fromManifestJson', () {
    test('מפענח מניפסט תקין עם כתובות החלקים', () {
      final split = _split();
      expect(split.archive, _archive);
      expect(split.size, 50);
      expect(split.parts.map((p) => p.size), [20, 20, 10]);
      expect(split.parts.first.downloadUrl, 'https://x/${_partName(0)}');
    });

    void expectRejected(Object? json,
        {Map<String, String>? urls, Map<String, int> sizes = const {}}) {
      expect(
        () => SplitAsset.fromManifestJson(json,
            manifestName: _manifestName,
            partUrls: urls ?? _partUrls,
            partSizes: sizes),
        throwsFormatException,
      );
    }

    test('חלק שחסר ב-release נדחה', () {
      expectRejected(_manifestJson(),
          urls: {..._partUrls}..remove(_partName(1)));
    });

    test('גודל חלק שאינו תואם ל-release נדחה', () {
      expectRejected(_manifestJson(), sizes: {_partName(0): 21});
    });

    test('סכום חלקים שונה מגודל הארכיון נדחה', () {
      expectRejected(_manifestJson(sizes: [20, 20, 9]));
    });

    test('schemaVersion לא מוכר ושם לא בטוח נדחים', () {
      expectRejected({..._manifestJson(), 'schemaVersion': 2});
      expectRejected({..._manifestJson(), 'archive': '../$_archive'});
      expectRejected({..._manifestJson(), 'archive': 'other.db.zst'});
    });
  });

  group('LibraryRelease.fullDbAssetFor', () {
    LibraryRelease release(List<String> names) => LibraryRelease(
          tag: 'v31',
          isPrerelease: false,
          isDraft: false,
          publishedAt: null,
          assets: [
            for (final n in names)
              ReleaseAsset(name: n, downloadUrl: 'https://x/$n', size: 1),
          ],
        );

    test('מניפסט פיצול של DB מלא נבחר, ומניפסט patch לא', () {
      final r = release(
          [_manifestName, _partName(0), 'patch-v30-v31.db.zst.manifest.json']);
      final asset = r.fullDbAssetFor(maxSchemaVersion: 6);
      expect(asset?.name, _manifestName);
      expect(asset?.isSplitFullDbManifest, isTrue);
      expect(asset?.advertisedFullDbSchemaVersion, 6);
      expect(asset?.isFullDbArchive, isFalse);
      expect(
        ReleaseAsset(
                name: 'patch-v30-v31.db.zst.manifest.json',
                downloadUrl: '',
                size: 1)
            .isSplitFullDbManifest,
        isFalse,
      );
    });

    test('קובץ יחיד גובר על פיצול באותה סכמה; סכמה גבוהה מדי מדולגת', () {
      expect(
        release([_manifestName, _archive])
            .fullDbAssetFor(maxSchemaVersion: 6)
            ?.name,
        _archive,
      );
      expect(
        release(['seforim-schema7.db.zst.manifest.json', 'seforim.db.zst'])
            .fullDbAssetFor(maxSchemaVersion: 6)
            ?.name,
        'seforim.db.zst',
      );
    });
  });

  group('discovery של DB מפוצל', () {
    String releasesJson() => jsonEncode([
          {
            'tag_name': 'v31',
            'prerelease': false,
            'draft': false,
            'assets': [
              {
                'name': _manifestName,
                'browser_download_url': 'https://x/$_manifestName',
                'size': 400,
                'id': 7,
              },
              for (var i = 0; i < _parts.length; i++)
                {
                  'name': _partName(i),
                  'browser_download_url': 'https://x/${_partName(i)}',
                  'size': _parts[i].length,
                },
            ],
          },
        ]);

    LibraryUpdateDiscovery discovery(http.Response Function() manifest) =>
        LibraryUpdateDiscovery(
          supportedDbSchemaVersion: 6,
          client: GithubLibraryReleaseClient(
            httpClient: MockClient((request) async {
              final url = request.url.toString();
              if (url.contains('/releases?')) {
                return http.Response(releasesJson(), 200);
              }
              if (url.endsWith(_manifestName)) return manifest();
              return http.Response('not found', 404);
            }),
          ),
        );

    test('מניפסט תקין → נכס מלא בגודל השלם עם החלקים', () async {
      final result =
          await discovery(() => http.Response(jsonEncode(_manifestJson()), 200))
              .discover(allowPrerelease: false);
      final asset = result.latestFullDbAsset!;
      expect(asset.name, _archive);
      expect(asset.size, 50);
      expect(asset.digest, 'sha256:${_sha(_full)}');
      expect(asset.id, 7);
      expect(asset.split?.parts, hasLength(3));
      expect(result.latestVersion, 31);
      expect(result.latestDbSchemaVersion, 6);
    });

    test('מניפסט פגום → אין fallback מלא, אך הגרסה האחרונה מזוהה', () async {
      final result = await discovery(() => http.Response('{', 200))
          .discover(allowPrerelease: false);
      expect(result.latestFullDbAsset, isNull);
      expect(result.latestReleaseTag, isNull);
      expect(result.latestVersion, 31);
      expect(result.latestDbSchemaVersion, 6);
    });
  });

  group('PatchDownloader.downloadSplitToFile', () {
    late Directory tmp;
    late String dest;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('split_download_test');
      dest = '${tmp.path}/seforim.db.zst';
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    /// שרת חלקים: [bodies] קובע מה מוגש לכל חלק (ברירת מחדל: החלק עצמו).
    PatchDownloader server(
      List<http.BaseRequest> captured, {
      Map<int, http.StreamedResponse Function(http.BaseRequest)> bodies =
          const {},
    }) {
      return PatchDownloader(
        decompress: (c) async => c,
        networkRetryDelays: const [],
        httpClient: MockClient.streaming((request, _) async {
          captured.add(request);
          final index = int.parse(request.url.path.split('part-').last);
          final custom = bodies[index];
          if (custom != null) return custom(request);
          return http.StreamedResponse(
            Stream.value(_parts[index]),
            200,
            contentLength: _parts[index].length,
            headers: {'etag': '"p$index"'},
          );
        }),
      );
    }

    List<String> leftovers() => tmp
        .listSync()
        .map((e) => e.path.split(RegExp(r'[\\/]')).last)
        .where((n) => n != 'seforim.db.zst' && n != 'seforim.db.zst.resume')
        .toList();

    test('מוריד, מחבר ומאמת; החלקים נמחקים וההתקדמות מצטברת', () async {
      final captured = <http.BaseRequest>[];
      final progress = <int>[];
      await server(captured).downloadSplitToFile(
        split: _split(),
        destPath: dest,
        resumeToken: 'v31',
        onProgress: (d, total) {
          expect(total, 50);
          progress.add(d);
        },
      );
      expect(File(dest).readAsBytesSync(), _full);
      expect(captured, hasLength(3));
      expect(progress.last, 50);
      expect(progress, orderedEquals([...progress]..sort()));
      expect(leftovers(), isEmpty);
    });

    test('המשך אחרי חלק שנקטע: Range לחלק השני בלבד, הראשון לא יורד שוב',
        () async {
      File(PatchDownloader.splitPartPath(dest, 0)).writeAsBytesSync(_parts[0]);
      File('${PatchDownloader.splitPartPath(dest, 0)}.resume')
          .writeAsStringSync('v31|${_partName(0)}|${_sha(_parts[0])}\n"p0"');
      final partial = PatchDownloader.splitPartPath(dest, 1);
      File(partial).writeAsBytesSync(_parts[1].sublist(0, 8));
      File('$partial.resume')
          .writeAsStringSync('v31|${_partName(1)}|${_sha(_parts[1])}\n"p1"');

      final captured = <http.BaseRequest>[];
      await server(captured, bodies: {
        1: (req) => http.StreamedResponse(
              Stream.value(_parts[1].sublist(8)),
              206,
              contentLength: 12,
              headers: {'content-range': 'bytes 8-19/20', 'etag': '"p1"'},
            ),
      }).downloadSplitToFile(
          split: _split(), destPath: dest, resumeToken: 'v31');

      expect(
          captured.map((r) => r.url.path.split('part-').last), ['001', '002']);
      expect(captured.first.headers['Range'], 'bytes=8-');
      expect(File(dest).readAsBytesSync(), _full);
    });

    test('חלק פגום → נכשל, החלק נמחק והארכיון לא נכתב', () async {
      final bad = Uint8List.fromList(List.filled(20, 9));
      await expectLater(
        server([], bodies: {
          1: (_) =>
              http.StreamedResponse(Stream.value(bad), 200, contentLength: 20),
        }).downloadSplitToFile(
            split: _split(), destPath: dest, resumeToken: 'v31'),
        throwsA(isA<PatchDownloadException>()),
      );
      expect(
          File(PatchDownloader.splitPartPath(dest, 1)).existsSync(), isFalse);
      expect(File(dest).existsSync(), isFalse);
      // החלק הראשון התקין נשמר להמשך.
      expect(File(PatchDownloader.splitPartPath(dest, 0)).existsSync(), isTrue);
    });

    test('חלק חסר בשרת (404) → נכשל בלי ארכיון', () async {
      await expectLater(
        server([], bodies: {
          2: (_) => http.StreamedResponse(const Stream.empty(), 404),
        }).downloadSplitToFile(
            split: _split(), destPath: dest, resumeToken: 'v31'),
        throwsA(isA<PatchDownloadException>()),
      );
      expect(File(dest).existsSync(), isFalse);
    });

    test('sha256 של השלם שגוי במניפסט → נכשל והארכיון נמחק', () async {
      await expectLater(
        server([]).downloadSplitToFile(
          split: _split(wholeSha: 'a' * 64),
          destPath: dest,
          resumeToken: 'v31',
        ),
        throwsA(isA<PatchDownloadException>()
            .having((e) => e.message, 'message', contains('המחובר'))),
      );
      expect(File(dest).existsSync(), isFalse);
    });

    test('חיבור חלקים גדולים מגוש קריאה אחד זהה בייט-לבייט', () async {
      final big = Uint8List.fromList(List.generate(
          3 * 1024 * 1024 + 7, (i) => (i * 31 + (i >> 9)) & 0xff));
      final sizes = [1500000, 1048576, big.length - 2548576];
      final bigParts = [
        Uint8List.sublistView(big, 0, sizes[0]),
        Uint8List.sublistView(big, sizes[0], sizes[0] + sizes[1]),
        Uint8List.sublistView(big, sizes[0] + sizes[1]),
      ];
      final split = SplitAsset.fromManifestJson({
        ..._manifestJson(),
        'size': big.length,
        'sha256': _sha(big),
        'partSizeLimit': sizes[0],
        'parts': [
          for (var i = 0; i < 3; i++)
            {
              'name': _partName(i),
              'size': sizes[i],
              'sha256': _sha(bigParts[i]),
            },
        ],
      }, manifestName: _manifestName, partUrls: _partUrls);
      await server([], bodies: {
        for (var i = 0; i < 3; i++)
          i: (_) => http.StreamedResponse(Stream.value(bigParts[i]), 200,
              contentLength: sizes[i]),
      }).downloadSplitToFile(split: split, destPath: dest, resumeToken: 'v31');
      expect(File(dest).readAsBytesSync(), big);
      expect(leftovers(), isEmpty);
    });

    /// מריץ הורדה מלאה ומפעיל את [beforeJoin] כשהחלק האחרון כמעט נכתב — אחרי
    /// שהחלקים הקודמים כבר אומתו, ולפני החיבור.
    Future<void> downloadThen(void Function() beforeJoin) {
      var fired = false;
      return server([]).downloadSplitToFile(
        split: _split(),
        destPath: dest,
        resumeToken: 'v31',
        onProgress: (d, _) {
          if (d == _full.length && !fired) {
            fired = true;
            beforeJoin();
          }
        },
      );
    }

    test('חלק שנעלם לפני החיבור → PathNotFoundException בלי פלט חלקי',
        () async {
      await expectLater(
        downloadThen(
            () => File(PatchDownloader.splitPartPath(dest, 1)).deleteSync()),
        throwsA(isA<PathNotFoundException>()),
      );
      expect(File(dest).existsSync(), isFalse);
      expect(leftovers().where((n) => !n.contains('.part-')), isEmpty);
    });

    test('חלק שהשתבש לפני החיבור → PatchDownloadException בלי פלט חלקי',
        () async {
      await expectLater(
        downloadThen(() => File(PatchDownloader.splitPartPath(dest, 0))
            .writeAsBytesSync(List.filled(20, 9))),
        throwsA(isA<PatchDownloadException>()
            .having((e) => e.message, 'message', contains('המחובר'))),
      );
      expect(File(dest).existsSync(), isFalse);
      expect(leftovers().where((n) => !n.contains('.part-')), isEmpty);
    });

    test('ארכיון שכבר חובר בריצה קודמת → אין הורדה', () async {
      await server([]).downloadSplitToFile(
          split: _split(), destPath: dest, resumeToken: 'v31');
      final captured = <http.BaseRequest>[];
      await server(captured).downloadSplitToFile(
          split: _split(), destPath: dest, resumeToken: 'v31');
      expect(captured, isEmpty);
      expect(File(dest).readAsBytesSync(), _full);
    });

    test('ביטול באימות ארכיון שכבר חובר → PatchDownloadCancelled, הארכיון נשמר',
        () async {
      await server([]).downloadSplitToFile(
          split: _split(), destPath: dest, resumeToken: 'v31');
      final captured = <http.BaseRequest>[];
      var verifying = false;
      await expectLater(
        server(captured).downloadSplitToFile(
          split: _split(),
          destPath: dest,
          resumeToken: 'v31',
          onProgress: (_, __) => verifying = true,
          isCancelled: () => verifying,
        ),
        throwsA(isA<PatchDownloadCancelled>()),
      );
      expect(captured, isEmpty);
      expect(File(dest).readAsBytesSync(), _full);
    });

    test('שרידי חלקים מעבר למספר החלקים הנוכחי נמחקים', () async {
      File(PatchDownloader.splitPartPath(dest, 5)).writeAsBytesSync([1]);
      File('${PatchDownloader.splitPartPath(dest, 5)}.resume')
          .writeAsStringSync('old');
      await server([]).downloadSplitToFile(
          split: _split(), destPath: dest, resumeToken: 'v31');
      expect(leftovers(), isEmpty);
    });

    test('downloadReleaseAssetToFile: נכס יחיד מאומת לפי ה-digest', () async {
      final downloader = PatchDownloader(
        decompress: (c) async => c,
        httpClient: MockClient.streaming((_, __) async => http.StreamedResponse(
            Stream.value(_full), 200,
            contentLength: _full.length)),
      );
      await expectLater(
        downloader.downloadReleaseAssetToFile(
          asset: ReleaseAsset(
            name: _archive,
            downloadUrl: 'https://x/$_archive',
            size: _full.length,
            digest: 'sha256:${'b' * 64}',
          ),
          destPath: dest,
        ),
        throwsA(isA<PatchDownloadException>()),
      );
      await downloader.downloadReleaseAssetToFile(
        asset: ReleaseAsset(
          name: _archive,
          downloadUrl: 'https://x/$_archive',
          size: _full.length,
          digest: 'sha256:${_sha(_full)}',
        ),
        destPath: dest,
      );
      expect(File(dest).readAsBytesSync(), _full);
    });
  });
}
