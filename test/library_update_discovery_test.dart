import 'dart:convert';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seforim_library_updater/src/models/library_release.dart';
import 'package:seforim_library_updater/src/models/library_update_plan.dart';
import 'package:seforim_library_updater/src/services/github_library_release_client.dart';
import 'package:seforim_library_updater/src/services/library_update_discovery.dart';
import 'package:seforim_library_updater/src/services/library_update_planner.dart';

LibraryRelease _release({
  required String tag,
  bool prerelease = false,
  bool draft = false,
  List<String> assetNames = const [],
}) {
  return LibraryRelease(
    tag: tag,
    isPrerelease: prerelease,
    isDraft: draft,
    publishedAt: null,
    assets: assetNames
        .map((n) =>
            ReleaseAsset(name: n, downloadUrl: 'https://x/$tag/$n', size: 100))
        .toList(),
  );
}

/// manifest תקין של DB מלא zdb בשם [file] (size 9, כמו ה-assets בקבוצת הסכמה).
Map<String, dynamic> _fullManifest(String file, {int dbVersion = 29}) => {
      'manifestVersion': 1,
      'file': file,
      'size': 9,
      'sha256': 'a' * 64,
      'zdb': {
        'formatMajor': 1,
        'formatMinor': 0,
        'fileUuid': '0123456789abcdef0123456789abcdef',
        'contentXxh64': '0123456789abcdef',
        'logicalSize': 36,
        'pageSize': 4096,
        'dictName': 'seforim-v1',
        'dictId': 7,
        'level': 19,
      },
      'dbVersion': dbVersion,
      'dbSchemaVersion':
          int.parse(RegExp(r'schema(\d+)').firstMatch(file)!.group(1)!),
      'contentHash': 'hash$dbVersion',
      'converter': {'repository': 'Otzaria/otzaria_zvfs', 'commit': 'abc123'},
    };

/// בונה manifest JSON עבור patch from→to.
String _manifestJson(int from, int to) => jsonEncode({
      'fromVersion': from,
      'toVersion': to,
      'fromSchemaVersion': 1,
      'toSchemaVersion': 1,
      'fromContentHash': 'hash$from',
      'toContentHash': 'hash$to',
      'patchFiles': [
        {
          'file': 'patch-v$from-v$to.db.zst',
          'compression': 'zstd',
          'sha256': 'c',
          'size': (to - from) * 1000,
          'uncompressedSha256': 'u',
          'uncompressedSize': (to - from) * 2000,
        }
      ],
    });

void main() {
  group('eligibleReleases', () {
    test('מתעלם מ-draft תמיד', () {
      final result = LibraryUpdateDiscovery.eligibleReleases(
        [
          _release(tag: 'v3'),
          _release(tag: 'v4', draft: true),
        ],
        allowPrerelease: true,
      );
      expect(result.map((r) => r.tag), ['v3']);
    });

    test('ערוץ יציב לא בוחר prerelease', () {
      final result = LibraryUpdateDiscovery.eligibleReleases(
        [
          _release(tag: 'v3'),
          _release(tag: 'v4', prerelease: true),
        ],
        allowPrerelease: false,
      );
      expect(result.map((r) => r.tag), ['v3']);
    });

    test('ערוץ dev כן בוחר prerelease', () {
      final result = LibraryUpdateDiscovery.eligibleReleases(
        [
          _release(tag: 'v3'),
          _release(tag: 'v4', prerelease: true),
        ],
        allowPrerelease: true,
      );
      expect(result.map((r) => r.tag), ['v3', 'v4']);
    });
  });

  group('parseVersionFromTag', () {
    test('מחלץ מ-v3', () {
      expect(LibraryUpdateDiscovery.parseVersionFromTag('v3'), 3);
    });
    test('מחלץ מ-3', () {
      expect(LibraryUpdateDiscovery.parseVersionFromTag('3'), 3);
    });
    test('null אם אין מספר', () {
      expect(LibraryUpdateDiscovery.parseVersionFromTag('latest'), isNull);
    });
  });

  group('discover (mock client)', () {
    // releases: v3 (1→3, 2→3), v2 (1→2), v1 (אין patches)
    final releasesJson = jsonEncode([
      {
        'tag_name': 'v3',
        'prerelease': false,
        'draft': false,
        'published_at': '2026-06-27T21:00:00Z',
        'assets': [
          {
            'name': 'seforim.db.zst',
            'browser_download_url': 'https://x/v3/seforim.db.zst',
            'size': 1197000000
          },
          {
            'name': 'patch-v1-v3.db.zst',
            'browser_download_url': 'https://x/v3/patch-v1-v3.db.zst',
            'size': 2836082
          },
          {
            'name': 'patch-v1-v3.db.zst.manifest.json',
            'browser_download_url':
                'https://x/v3/patch-v1-v3.db.zst.manifest.json',
            'size': 605
          },
          {
            'name': 'patch-v2-v3.db.zst',
            'browser_download_url': 'https://x/v3/patch-v2-v3.db.zst',
            'size': 1870859
          },
          {
            'name': 'patch-v2-v3.db.zst.manifest.json',
            'browser_download_url':
                'https://x/v3/patch-v2-v3.db.zst.manifest.json',
            'size': 605
          },
        ],
      },
      {
        'tag_name': 'v2',
        'prerelease': false,
        'draft': false,
        'published_at': '2026-06-26T11:00:00Z',
        'assets': [
          {
            'name': 'seforim.db.zst',
            'browser_download_url': 'https://x/v2/seforim.db.zst',
            'size': 1195000000
          },
          {
            'name': 'patch-v1-v2.db.zst',
            'browser_download_url': 'https://x/v2/patch-v1-v2.db.zst',
            'size': 1040075
          },
          {
            'name': 'patch-v1-v2.db.zst.manifest.json',
            'browser_download_url':
                'https://x/v2/patch-v1-v2.db.zst.manifest.json',
            'size': 604
          },
        ],
      },
    ]);

    GithubLibraryReleaseClient buildClient() {
      final mock = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/releases?') || url.endsWith('/releases')) {
          return http.Response(releasesJson, 200);
        }
        if (url.endsWith('patch-v1-v3.db.zst.manifest.json')) {
          return http.Response(_manifestJson(1, 3), 200);
        }
        if (url.endsWith('patch-v2-v3.db.zst.manifest.json')) {
          return http.Response(_manifestJson(2, 3), 200);
        }
        if (url.endsWith('patch-v1-v2.db.zst.manifest.json')) {
          return http.Response(_manifestJson(1, 2), 200);
        }
        return http.Response('not found', 404);
      });
      return GithubLibraryReleaseClient(httpClient: mock);
    }

    test('בונה edges, מזהה latest=3 ו-full asset', () async {
      final discovery = LibraryUpdateDiscovery(client: buildClient());
      final result = await discovery.discover(allowPrerelease: false);

      expect(result.latestVersion, 3);
      expect(result.edges, hasLength(3)); // 1→3, 2→3, 1→2
      final pairs =
          result.edges.map((e) => '${e.fromVersion}-${e.toVersion}').toSet();
      expect(pairs, {'1-3', '2-3', '1-2'});

      // ה-edge 1→3 צריך להכיל URL להורדת ה-patch
      final direct = result.edges
          .firstWhere((e) => e.fromVersion == 1 && e.toVersion == 3);
      expect(direct.patchFileUrls['patch-v1-v3.db.zst'],
          'https://x/v3/patch-v1-v3.db.zst');

      expect(
          result.latestFullDbAsset?.downloadUrl, 'https://x/v3/seforim.db.zst');
      expect(result.latestReleaseTag, 'v3');
    });

    test('release חדש עם DB מלא בלבד (ללא patches) נחשב latest', () async {
      // v4 יצא עם seforim.db.zst בלבד; latestVersion חייב להיות 4, לא 3.
      final releasesJsonV4 = jsonEncode([
        {
          'tag_name': 'v4',
          'prerelease': false,
          'draft': false,
          'assets': [
            {
              'name': 'seforim.db.zst',
              'browser_download_url': 'https://x/v4/seforim.db.zst',
              'size': 1200000000
            },
          ],
        },
        {
          'tag_name': 'v3',
          'prerelease': false,
          'draft': false,
          'assets': [
            {
              'name': 'patch-v2-v3.db.zst',
              'browser_download_url': 'https://x/v3/patch-v2-v3.db.zst',
              'size': 1870859
            },
            {
              'name': 'patch-v2-v3.db.zst.manifest.json',
              'browser_download_url':
                  'https://x/v3/patch-v2-v3.db.zst.manifest.json',
              'size': 605
            },
          ],
        },
      ]);
      final mock = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/releases?') || url.endsWith('/releases')) {
          return http.Response(releasesJsonV4, 200);
        }
        if (url.endsWith('patch-v2-v3.db.zst.manifest.json')) {
          return http.Response(_manifestJson(2, 3), 200);
        }
        return http.Response('not found', 404);
      });
      final discovery = LibraryUpdateDiscovery(
          client: GithubLibraryReleaseClient(httpClient: mock));
      final result = await discovery.discover(allowPrerelease: false);

      expect(result.latestVersion, 4); // מה-full DB, גבוה מ-edge המקסימלי (3)
      expect(
          result.latestFullDbAsset?.downloadUrl, 'https://x/v4/seforim.db.zst');
      expect(result.latestReleaseTag, 'v4');
    });

    test('DB מלא ישן מ-latest אינו מוצע כ-fallback', () async {
      final releasesJsonWithStaleFull = jsonEncode([
        {
          'tag_name': 'v4',
          'prerelease': false,
          'draft': false,
          'assets': [
            {
              'name': 'patch-v3-v4.db.zst',
              'browser_download_url': 'https://x/v4/patch-v3-v4.db.zst',
              'size': 1000
            },
            {
              'name': 'patch-v3-v4.db.zst.manifest.json',
              'browser_download_url':
                  'https://x/v4/patch-v3-v4.db.zst.manifest.json',
              'size': 600
            },
          ],
        },
        {
          'tag_name': 'v3',
          'prerelease': false,
          'draft': false,
          'assets': [
            {
              'name': 'seforim.db.zst',
              'browser_download_url': 'https://x/v3/seforim.db.zst',
              'size': 1197000000
            },
          ],
        },
      ]);
      final mock = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/releases?') || url.endsWith('/releases')) {
          return http.Response(releasesJsonWithStaleFull, 200);
        }
        if (url.endsWith('patch-v3-v4.db.zst.manifest.json')) {
          return http.Response(_manifestJson(3, 4), 200);
        }
        return http.Response('not found', 404);
      });
      final discovery = LibraryUpdateDiscovery(
        client: GithubLibraryReleaseClient(httpClient: mock),
      );
      final result = await discovery.discover(allowPrerelease: false);

      expect(result.latestVersion, 4);
      expect(result.edges, hasLength(1));
      expect(result.latestFullDbAsset, isNull);
      expect(result.latestReleaseTag, isNull);
    });
  });

  group('discover — DB מלא לפי סכמה', () {
    // v29 בסכמה 6: DB מלא בשם החדש בלבד + מחסום מ-v28. v28 בסכמה 5.
    final releasesJson = jsonEncode([
      {
        'tag_name': 'v29',
        'prerelease': false,
        'draft': false,
        'assets': [
          for (final n in [
            'seforim-schema6.zdb',
            'patch-v28-v29.db.zst',
            'patch-v28-v29.db.zst.manifest.json',
          ])
            {'name': n, 'browser_download_url': 'https://x/v29/$n', 'size': 9},
        ],
      },
      {
        'tag_name': 'v28',
        'prerelease': false,
        'draft': false,
        'assets': [
          {
            'name': 'seforim.db.zst',
            'browser_download_url': 'https://x/v28/seforim.db.zst',
            'size': 9
          },
        ],
      },
    ]);
    final barrierJson = jsonEncode({
      'fromVersion': 28,
      'toVersion': 29,
      'fromSchemaVersion': 5,
      'toSchemaVersion': 6,
      'patchFormatVersion': 999,
      'fullRebase': true,
      'fromContentHash': 'full-rebase',
      'toContentHash': 'full-rebase',
      'patchFiles': [
        {
          'file': 'patch-v28-v29.db.zst',
          'compression': 'zstd',
          'sha256': 'c',
          'size': 9,
          'uncompressedSha256': 'u',
          'uncompressedSize': 9,
        }
      ],
    });

    LibraryUpdateDiscovery build({
      int? supportedDbSchemaVersion,
      bool fullOnly = false,
      int manifestStatus = 200,
      List<String>? latestAssetNames,
      bool schemaSixDelta = false,
      bool withFullManifests = true,
      int fullManifestStatus = 200,
      void Function(Map<String, dynamic> manifest)? editFullManifest,
    }) {
      final releaseData = jsonDecode(releasesJson) as List;
      if (latestAssetNames != null) {
        releaseData.first['assets'] = [
          for (final name in latestAssetNames)
            {
              'name': name,
              'browser_download_url': 'https://x/v29/$name',
              'size': 9
            },
        ];
      }
      if (fullOnly) {
        (releaseData.first['assets'] as List)
            .removeWhere((a) => (a['name'] as String).startsWith('patch-'));
      }
      if (withFullManifests) {
        final assets = releaseData.first['assets'] as List;
        for (final zdb in [
          for (final a in assets)
            if ((a['name'] as String).endsWith('.zdb')) a['name'] as String
        ]) {
          final name = '$zdb.manifest.json';
          assets.add({
            'name': name,
            'browser_download_url': 'https://x/v29/$name',
            'size': 9
          });
        }
      }
      final manifestData = jsonDecode(barrierJson);
      if (schemaSixDelta) {
        manifestData['fromSchemaVersion'] = 6;
        manifestData['patchFormatVersion'] = 4;
        manifestData['fullRebase'] = false;
      }
      final mock = MockClient((request) async {
        final url = request.url.toString();
        if (url.contains('/releases?') || url.endsWith('/releases')) {
          return http.Response(jsonEncode(releaseData), 200);
        }
        if (url.endsWith('patch-v28-v29.db.zst.manifest.json')) {
          return http.Response(jsonEncode(manifestData), manifestStatus);
        }
        if (url.endsWith('.zdb.manifest.json')) {
          final file = url.split('/').last.replaceAll('.manifest.json', '');
          final manifest = _fullManifest(file);
          editFullManifest?.call(manifest);
          return http.Response(jsonEncode(manifest), fullManifestStatus);
        }
        return http.Response('not found', 404);
      });
      final client = GithubLibraryReleaseClient(httpClient: mock);
      return supportedDbSchemaVersion == null
          ? LibraryUpdateDiscovery(client: client)
          : LibraryUpdateDiscovery(
              client: client,
              supportedDbSchemaVersion: supportedDbSchemaVersion,
            );
    }

    test('לקוח סכמה 6 מקבל את seforim-schema6.zdb של latest', () async {
      final result = await build(supportedDbSchemaVersion: 6)
          .discover(allowPrerelease: false);
      expect(result.latestVersion, 29);
      expect(result.edges.single.manifest.fullRebase, isTrue);
      expect(result.latestFullDbAsset?.name, 'seforim-schema6.zdb');
      expect(result.latestReleaseTag, 'v29');
    });

    // build של אפליקציה ישנה מול ref: main צף אינו מצהיר על סכמה.
    test('צרכן שאינו מצהיר נשאר בסכמה 5 — אין fallback מלא לסכמה 6', () async {
      final result = await build().discover(allowPrerelease: false);
      expect(result.latestVersion, 29);
      expect(result.latestFullDbAsset, isNull);
    });

    test('לקוח סכמה 5 — אין fallback מלא (latest לא נתמך, v28 ישן)', () async {
      final result = await build(supportedDbSchemaVersion: 5)
          .discover(allowPrerelease: false);
      expect(result.latestVersion, 29);
      expect(result.latestFullDbAsset, isNull);
      expect(result.latestReleaseTag, isNull);
    });

    for (final fullOnly in [false, true]) {
      test(
          fullOnly
              ? 'full-only schema 6 remains visible to schema 5'
              : 'manifest failure cannot hide a schema 6 release', () async {
        final result = await build(fullOnly: fullOnly, manifestStatus: 503)
            .discover(allowPrerelease: false);
        expect(result.latestVersion, 29);
        expect(result.latestDbSchemaVersion, 6);
        expect(result.edges, isEmpty);
        expect(result.latestFullDbAsset, isNull);
        expect(result.latestReleaseTag, isNull);

        for (final localVersion in [27, 28]) {
          final plan = const LibraryUpdatePlanner().plan(
            localVersion: localVersion,
            localSchemaVersion: 5,
            hasLocalVersionMeta: true,
            latestVersion: result.latestVersion,
            latestDbSchemaVersion: result.latestDbSchemaVersion,
            edges: result.edges,
            latestFullDbAsset: result.latestFullDbAsset,
            latestReleaseTag: result.latestReleaseTag,
          );
          expect(plan.kind, LibraryUpdatePlanKind.blocked);
          expect(plan.targetVersion, 29);
          expect(plan.reason, contains('עדכון אפליקציה'));
          expect(plan.fullDbAsset, isNull);
        }
      });
    }

    test('supported schema 6 uses the latest full DB after manifest failure',
        () async {
      final result =
          await build(supportedDbSchemaVersion: 6, manifestStatus: 503)
              .discover(allowPrerelease: false);
      final plan = const LibraryUpdatePlanner(supportedDbSchemaVersion: 6).plan(
        localVersion: 28,
        localSchemaVersion: 5,
        hasLocalVersionMeta: true,
        latestVersion: result.latestVersion,
        latestDbSchemaVersion: result.latestDbSchemaVersion,
        edges: result.edges,
        latestFullDbAsset: result.latestFullDbAsset,
        latestReleaseTag: result.latestReleaseTag,
      );
      expect(plan.kind, LibraryUpdatePlanKind.fullDownload);
      expect(plan.targetVersion, 29);
      expect(plan.fullDbAsset?.name, 'seforim-schema6.zdb');
    });

    for (final delta in [false, true]) {
      test(
          'schema 7 variant does not block a compatible schema 6 '
          '${delta ? 'delta' : 'full download'}', () async {
        final result = await build(
          supportedDbSchemaVersion: 6,
          schemaSixDelta: delta,
          latestAssetNames: [
            'seforim-schema7.zdb',
            'seforim-schema6.zdb',
            if (delta) ...[
              'patch-v28-v29.db.zst',
              'patch-v28-v29.db.zst.manifest.json',
            ],
          ],
        ).discover(allowPrerelease: false);
        expect(result.latestVersion, 29);
        expect(result.latestDbSchemaVersion, 6);
        final plan =
            const LibraryUpdatePlanner(supportedDbSchemaVersion: 6).plan(
          localVersion: 28,
          localSchemaVersion: 6,
          hasLocalVersionMeta: true,
          latestVersion: result.latestVersion,
          latestDbSchemaVersion: result.latestDbSchemaVersion,
          edges: result.edges,
          latestFullDbAsset: result.latestFullDbAsset,
          latestReleaseTag: result.latestReleaseTag,
        );
        expect(
            plan.kind,
            delta
                ? LibraryUpdatePlanKind.delta
                : LibraryUpdatePlanKind.fullDownload);
        expect(plan.fullDbAsset?.name, 'seforim-schema6.zdb');
      });
    }

    test('a release with only pipeline artifacts does not become latest',
        () async {
      final result = await build(latestAssetNames: [
        'catalog.pb',
        'release-info.json',
        'lucene-index.tar.zst',
        'patch-index.db.zst.manifest.json',
      ]).discover(allowPrerelease: false);
      expect(result.latestVersion, 28);
      expect(result.latestReleaseTag, 'v28');
      expect(result.latestDbSchemaVersion, 5);
      expect(result.latestFullDbAsset?.name, 'seforim.db.zst');
    });
    test('zdb נבחר: ה-manifest שלו מצורף לתוצאה', () async {
      final result = await build(supportedDbSchemaVersion: 6)
          .discover(allowPrerelease: false);
      final manifest = result.latestFullDbManifest;
      expect(manifest, isNotNull);
      expect(manifest!.file, 'seforim-schema6.zdb');
      expect(manifest.dbVersion, 29);
      expect(manifest.dbSchemaVersion, 6);
      expect(manifest.zdb.logicalSize, 36);
    });

    test('zdb שלא נבחר ו-DB מלא zst אינם דורשים manifest', () async {
      final result = await build(
        latestAssetNames: ['seforim-schema6.zdb'],
        withFullManifests: false,
      ).discover(allowPrerelease: false);
      expect(result.latestFullDbAsset, isNull);
      expect(result.latestFullDbManifest, isNull);

      final legacy = await build(
        supportedDbSchemaVersion: 6,
        latestAssetNames: ['catalog.pb'],
        withFullManifests: false,
      ).discover(allowPrerelease: false);
      expect(legacy.latestFullDbAsset?.name, 'seforim.db.zst');
      expect(legacy.latestFullDbManifest, isNull);
    });

    test('zdb ללא manifest — הגילוי נכשל במפורש', () async {
      await expectLater(
        build(supportedDbSchemaVersion: 6, withFullManifests: false)
            .discover(allowPrerelease: false),
        throwsA(isA<FullDbManifestException>().having((e) => e.message,
            'message', contains('seforim-schema6.zdb.manifest.json'))),
      );
    });

    test('manifest של zdb שלא ירד — הגילוי נכשל במפורש', () async {
      await expectLater(
        build(supportedDbSchemaVersion: 6, fullManifestStatus: 503)
            .discover(allowPrerelease: false),
        throwsA(isA<FullDbManifestException>()),
      );
    });

    for (final (field, value) in [
      ('file', 'seforim-schema7.zdb'),
      ('size', 10),
      ('dbVersion', 28),
      ('dbSchemaVersion', 7),
    ]) {
      test('manifest של zdb שסותר את ה-asset ב-$field — נכשל', () async {
        await expectLater(
          build(
            supportedDbSchemaVersion: 6,
            editFullManifest: (m) => m[field] = value,
          ).discover(allowPrerelease: false),
          throwsA(isA<FullDbManifestException>()
              .having((e) => e.message, 'message', contains(field))),
        );
      });
    }
  });
}
