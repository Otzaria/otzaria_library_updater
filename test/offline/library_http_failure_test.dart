import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:test/test.dart';

void main() {
  test('418 stops manifest retries and preserves the previous mirror',
      () async {
    final dir = await Directory.systemTemp.createTemp('blocked-mirror-');
    addTearDown(() => dir.delete(recursive: true));
    final index = File('${dir.path}/releases.json');
    final asset = File('${dir.path}/assets/previous/seforim.db.zst');
    await index.writeAsString('previous index');
    await asset.parent.create(recursive: true);
    await asset.writeAsString('previous asset');
    var attempts = 0;
    final client = MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        return http.Response(
          jsonEncode([
            {
              'tag_name': 'v22-20260821152805',
              'assets': [
                {
                  'name': 'patch-v18-v22.db.zst.manifest.json',
                  'browser_download_url':
                      'https://github.com/Otzaria/SeforimLibrary/releases/download/'
                          'v22-20260821152805/patch-v18-v22.db.zst.manifest.json',
                  'size': 611,
                },
              ],
            },
          ]),
          200,
        );
      }
      attempts++;
      return http.Response(
        'blocked by filter',
        418,
        headers: {'server': 'filter-proxy'},
      );
    });
    addTearDown(client.close);
    final source = GithubLibraryReleaseClient(httpClient: client);
    final exporter = LibraryMirrorExporter(
      client: source,
      httpClient: client,
      supportedDbSchemaVersion: 7,
    );
    addTearDown(exporter.dispose);
    Object? failure;
    try {
      await exporter.export(destDir: dir.path);
    } catch (error) {
      failure = error;
    }
    expect(
      failure,
      isA<LibraryHttpException>()
          .having((e) => e.statusCode, 'status', 418)
          .having((e) => e.responseHeaders['server'], 'server', 'filter-proxy')
          .having((e) => e.responseSnippet, 'body', 'blocked by filter'),
    );
    expect(await index.readAsString(), 'previous index');
    expect(await asset.readAsString(), 'previous asset');
    expect(attempts, 1);
    expect('$failure', isNot(contains('נסה שוב כשהחיבור יציב')));
  });

  for (final operation in ['releases', 'delta', 'split']) {
    test('$operation preserves HTTP status and bounded diagnostics', () async {
      final body = 'blocked\n\t${'א' * 2000}';
      final client = MockClient((_) async => http.Response(body, 418, headers: {
            'content-type': 'text/html; charset=utf-8',
            'server': 'filter-proxy',
            'set-cookie': 'private-cookie',
            'authorization': 'private-token',
          }));
      addTearDown(client.close);
      final source = GithubLibraryReleaseClient(httpClient: client);
      const url = 'https://github.com/file.manifest.json';
      final action = switch (operation) {
        'releases' => source.fetchReleases(),
        'delta' => source.fetchManifest(url),
        _ => source.resolveSplitAsset(
            const LibraryRelease(
                tag: 'v35',
                isPrerelease: false,
                isDraft: false,
                publishedAt: null,
                assets: []),
            const ReleaseAsset(
                name: 'seforim-schema7.db.zst.manifest.json',
                downloadUrl: url,
                size: 1)),
      };
      await expectLater(
          action,
          throwsA(isA<LibraryHttpException>()
              .having((e) => e.isBlockedByFilter, 'filter', isTrue)
              .having((e) => e.uri.host, 'host',
                  operation == 'releases' ? 'api.github.com' : 'github.com')
              .having((e) => e.responseHeaders.keys, 'headers',
                  unorderedEquals(['content-type', 'server']))
              .having((e) => e.responseSnippet.length, 'body length',
                  lessThanOrEqualTo(512))
              .having((e) => e.responseSnippet, 'normalized UTF-8 body',
                  startsWith('blocked א'))
              .having((e) => '$e', 'user message',
                  isNot(contains('filter-proxy')))));
    });
  }

  test('403 and 429 are not classified as filter blocks', () async {
    for (final status in [403, 429]) {
      final client = MockClient((_) async => http.Response('denied', status));
      addTearDown(client.close);
      await expectLater(
          GithubLibraryReleaseClient(httpClient: client)
              .fetchManifest('https://github.com/m.json'),
          throwsA(isA<LibraryHttpException>()
              .having((e) => e.statusCode, 'status', status)
              .having((e) => e.isBlockedByFilter, 'filter', isFalse)));
    }
  });
}
