import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seforim_library_updater/src/models/library_release.dart';
import 'package:seforim_library_updater/src/models/library_update_plan.dart';
import 'package:seforim_library_updater/src/models/patch_table_spec.dart';
import 'package:seforim_library_updater/src/services/github_library_release_client.dart';
import 'package:seforim_library_updater/src/services/library_mirror_exporter.dart';
import 'package:seforim_library_updater/src/services/local_mirror_library_release_client.dart';
import 'package:seforim_library_updater/src/services/offline_library_update_discovery.dart';
import 'package:seforim_library_updater/src/services/offline_library_update_planner.dart';
import 'package:test/test.dart';

typedef _ReleaseFixture = ({
  String tag,
  String publishedAt,
  bool prerelease,
  Map<String, List<int>> assets,
});

_ReleaseFixture _release(
  String tag,
  Map<String, List<int>> assets, {
  String publishedAt = '2026-11-01T10:00:00Z',
  bool prerelease = false,
}) => (
  tag: tag,
  publishedAt: publishedAt,
  prerelease: prerelease,
  assets: assets,
);

final _fullName = fullDbArchiveNameForSchema(kSupportedDbSchemaVersion);
final _fullAssets = {_fullName: List<int>.filled(1024, 7)};

Map<String, List<int>> _patch(int from, int to, {int size = 16}) {
  final name = 'patch-v$from-v$to.db.zst';
  final body = List<int>.filled(size, to);
  return {
    name: body,
    '$name.manifest.json': utf8.encode(
      jsonEncode({
        'fromVersion': from,
        'toVersion': to,
        'fromSchemaVersion': kSupportedDbSchemaVersion,
        'toSchemaVersion': kSupportedDbSchemaVersion,
        'patchFormatVersion': kSupportedPatchFormatVersion,
        'fromContentHash': 'from-$from',
        'toContentHash': 'to-$to-$size',
        'patchFiles': [
          {
            'file': name,
            'compression': 'zstd',
            'sha256': sha256.convert(body).toString(),
            'size': body.length,
            'uncompressedSha256': 'unused-by-export',
            'uncompressedSize': body.length * 10,
          },
        ],
      }),
    ),
  };
}

({LibraryMirrorExporter exporter, GithubLibraryReleaseClient source}) _fixture(
  List<_ReleaseFixture> releases,
) {
  final bodies = <String, List<int>>{};
  final releasesJson = [
    for (final release in releases)
      {
        'tag_name': release.tag,
        'prerelease': release.prerelease,
        'draft': false,
        'published_at': release.publishedAt,
        'assets': [
          for (final asset in release.assets.entries)
            {
              'name': asset.key,
              'browser_download_url':
                  'https://fixture/${release.tag}/${asset.key}',
              'size': asset.value.length,
              'digest': 'sha256:${sha256.convert(asset.value)}',
              'state': 'uploaded',
            },
        ],
      },
  ];
  for (final release in releases) {
    for (final asset in release.assets.entries) {
      bodies['/${release.tag}/${asset.key}'] = asset.value;
    }
  }
  final mock = MockClient((request) async {
    if (request.url.host == 'api.github.com') {
      return http.Response(jsonEncode(releasesJson), 200);
    }
    final body = bodies[request.url.path];
    return body == null
        ? http.Response('missing fixture', 404)
        : http.Response.bytes(body, 200);
  });
  final source = GithubLibraryReleaseClient(httpClient: mock);
  final exporter = LibraryMirrorExporter(
    supportedDbSchemaVersion: kSupportedDbSchemaVersion,
    client: source,
    httpClient: mock,
  );
  addTearDown(() {
    exporter.dispose();
    mock.close();
  });
  return (exporter: exporter, source: source);
}

Future<OfflineLibraryDiscoveryResult> _discover(
  String path, {
  bool allowPrerelease = false,
}) => OfflineLibraryUpdateDiscovery(
  client: LocalMirrorLibraryReleaseClient(mirrorDir: path),
  supportedDbSchemaVersion: kSupportedDbSchemaVersion,
).discover(allowPrerelease: allowPrerelease);

LibraryUpdatePlan _plan(
  OfflineLibraryDiscoveryResult discovery, {
  int localVersion = 0,
  String? localTag,
}) => const OfflineLibraryUpdatePlanner().plan(
  localVersion: localVersion,
  hasLocalVersionMeta: localVersion > 0,
  localReleaseTag: localTag,
  localReleaseTagVersion: localTag == null ? null : localVersion,
  latestVersion: discovery.latestVersion,
  edges: discovery.edges,
  latestFullDbAsset: discovery.latestFullDbAsset,
  latestFullDbVersion: discovery.latestFullDbVersion,
  latestContentTag: discovery.latestContentTag,
  fullDbReleaseTag: discovery.fullDbReleaseTag,
  blockingSchemaVersion: discovery.blockingSchemaVersion,
  blockingPatchFormatVersion: discovery.blockingPatchFormatVersion,
);

void main() {
  late Directory mirror;
  setUp(() async {
    mirror = await Directory.systemTemp.createTemp('mirror-pruning-test-');
  });
  tearDown(() async {
    await mirror.delete(recursive: true);
  });

  test(
    'same-version content identity prevents replacing corrected DB with old DB',
    () async {
      final fixture = _fixture([
        _release(
          'v3-b',
          _patch(1, 3, size: 32),
          publishedAt: '2026-11-02T10:00:00Z',
        ),
        _release('v3-a', {..._fullAssets, ..._patch(1, 3)}),
      ]);
      final before = await OfflineLibraryUpdateDiscovery(
        client: fixture.source,
        supportedDbSchemaVersion: kSupportedDbSchemaVersion,
      ).discover(allowPrerelease: false);
      expect(before.latestContentTag, 'v3-b');
      expect(
        _plan(before, localVersion: 3, localTag: 'v3-b').kind,
        LibraryUpdatePlanKind.none,
      );

      await fixture.exporter.export(destDir: mirror.path);
      final after = await _discover(mirror.path);
      expect(after.latestContentTag, before.latestContentTag);
      expect(after.newestReleaseTag, before.newestReleaseTag);
      expect(after.fullDbReleaseTag, 'v3-a');
      expect(
        _plan(after, localVersion: 3, localTag: 'v3-b').kind,
        LibraryUpdatePlanKind.none,
      );
    },
  );

  test(
    'shared patch remains available for full DB follow-up after alias pruning',
    () async {
      final patch = _patch(2, 3);
      final fixture = _fixture([
        _release('v3', {
          ...patch,
          'patch-v02-v3.db.zst.manifest.json':
              patch['patch-v2-v3.db.zst.manifest.json']!,
        }),
        _release('v2', _fullAssets),
      ]);
      await fixture.exporter.export(destDir: mirror.path);
      final after = await _discover(mirror.path);
      expect(after.latestVersion, 3);
      expect(after.edges, hasLength(1));
      expect(
        File('${mirror.path}/assets/v3/patch-v2-v3.db.zst').existsSync(),
        isTrue,
      );
      final localPlan = _plan(after, localVersion: 2);
      expect(localPlan.kind, LibraryUpdatePlanKind.delta);
      expect(localPlan.finalTargetVersion, 3);
      final installPlan = _plan(after);
      expect(installPlan.kind, LibraryUpdatePlanKind.fullDownload);
      expect(installPlan.targetVersion, 2);
      expect(installPlan.followUpDelta?.targetVersion, 3);
      expect(installPlan.finalTargetVersion, 3);
    },
  );

  test(
    'full DB version inferred from manifests survives a nonnumeric carrier tag',
    () async {
      final fixture = _fixture([
        _release('rolling', {
          ..._fullAssets,
          ..._patch(1, 3, size: 32),
        }, publishedAt: '2026-11-02T10:00:00Z'),
        _release('v3-a', _patch(1, 3)),
      ]);
      await fixture.exporter.export(destDir: mirror.path);
      final after = await _discover(mirror.path);
      expect(after.latestVersion, 3);
      expect(after.latestFullDbVersion, 3);
      expect(after.fullDbReleaseTag, 'rolling');
      expect(after.latestContentTag, 'rolling');
      expect(_plan(after).targetVersion, 3);
      expect(_plan(after).finalTargetVersion, 3);
    },
  );

  for (final stableFull in [false, true]) {
    test(
      'stable-only discovery keeps its route with a prerelease alternative (stable full: $stableFull)',
      () async {
        final fixture = _fixture([
          _release(
            'v3-preview',
            {if (!stableFull) ..._fullAssets, ..._patch(1, 3), ..._patch(2, 3)},
            prerelease: true,
            publishedAt: '2026-11-02T10:00:00Z',
          ),
          _release(stableFull ? 'v3-stable' : 'v2', {
            if (stableFull) ..._fullAssets,
            ..._patch(1, stableFull ? 3 : 2, size: 32),
          }),
        ]);
        await fixture.exporter.export(
          destDir: mirror.path,
          allowPrerelease: true,
        );
        final stable = await _discover(mirror.path);
        expect(stable.latestVersion, stableFull ? 3 : 2);
        expect(stable.edges, hasLength(1));
        expect(
          _plan(stable, localVersion: 1).kind,
          LibraryUpdatePlanKind.delta,
        );
        expect(
          _plan(stable, localVersion: 1).finalTargetVersion,
          stableFull ? 3 : 2,
        );
      },
    );
  }

  test(
    'normal pruning preserves unreadable manifests and future-schema markers',
    () async {
      final futureSchema = kSupportedDbSchemaVersion + 1;
      final fixture = _fixture([
        _release('v6', {
          fullDbArchiveNameForSchema(futureSchema): [8],
        }),
        _release('v5', {
          'patch-v4-v5.db.zst.manifest.json': utf8.encode('invalid JSON'),
        }),
        _release('v3', {..._fullAssets, ..._patch(1, 3), ..._patch(2, 3)}),
        _release('v2', _patch(1, 2)),
      ]);
      await fixture.exporter.export(destDir: mirror.path);
      final after = await _discover(mirror.path);
      expect(after.latestVersion, 6);
      expect(after.latestFullDbVersion, 3);
      expect(after.latestContentTag, 'v6');
      expect(after.newestReleaseTag, 'v5');
      expect(after.blockingSchemaVersion, futureSchema);
      expect(after.unreadableManifests, ['patch-v4-v5.db.zst.manifest.json']);
      expect(after.edges.map((e) => (e.fromVersion, e.toVersion)), [
        (1, 3),
        (2, 3),
      ]);
      expect(
        File('${mirror.path}/assets/v2/patch-v1-v2.db.zst').existsSync(),
        isFalse,
      );
    },
  );
}
