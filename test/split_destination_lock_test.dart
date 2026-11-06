import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:test/test.dart';

String _sha(List<int> b) => sha256.convert(b).toString();

final _full = Uint8List.fromList(List.generate(40, (i) => i * 5));
final _parts = [_full.sublist(0, 20), _full.sublist(20)];

SplitAsset _split() => SplitAsset(
  archive: 'a.zst',
  size: 40,
  sha256: _sha(_full),
  manifestName: 'a.zst.manifest.json',
  parts: [
    for (var i = 0; i < 2; i++)
      SplitAssetPart(
        name: 'p$i',
        size: 20,
        sha256: _sha(_parts[i]),
        downloadUrl: 'https://x/p$i',
      ),
  ],
);

void main() {
  late Directory tmp;
  late String dest;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('split_destination_lock');
    dest = '${tmp.path}/a.zst';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  PatchDownloader downloader({Completer<void>? gate, List<String>? seen}) =>
      PatchDownloader(
        decompress: (c) async => c,
        networkRetryDelays: const [],
        httpClient: MockClient.streaming((request, _) async {
          seen?.add(request.url.path);
          await gate?.future;
          final i = int.parse(request.url.path.substring(2));
          return http.StreamedResponse(
            Stream.value(_parts[i]),
            200,
            contentLength: 20,
          );
        }),
      );

  test('second split download to the same dest fails clearly, first ok', () async {
    final gate = Completer<void>();
    final seen = <String>[];
    final first = downloader(gate: gate, seen: seen);
    final running = first.downloadSplitToFile(split: _split(), destPath: dest);
    while (seen.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final second = downloader(seen: seen);
    await expectLater(
      second.downloadSplitToFile(split: _split(), destPath: dest),
      throwsA(
        isA<PatchDownloadException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains(dest), isNot(contains('database is locked'))),
        ),
      ),
    );
    expect(seen, ['/p0']);
    gate.complete();
    await running;
    expect(File(dest).readAsBytesSync(), _full);
    // Lock released after success: a new download proceeds.
    await downloader().downloadSplitToFile(split: _split(), destPath: dest);
    expect(File(dest).readAsBytesSync(), _full);
  });

  test('lock is released after failure and after cancellation', () async {
    final failing = PatchDownloader(
      decompress: (c) async => c,
      networkRetryDelays: const [],
      httpClient: MockClient((_) async => http.Response('x', 500)),
    );
    await expectLater(
      failing.downloadSplitToFile(split: _split(), destPath: dest),
      throwsA(isA<PatchDownloadException>()),
    );
    var cancel = false;
    final cancelling = downloader();
    await expectLater(
      cancelling.downloadSplitToFile(
        split: _split(),
        destPath: dest,
        onPartProgress: (_, _, _) => cancel = true,
        isCancelled: () => cancel,
      ),
      throwsA(isA<PatchDownloadCancelled>()),
    );
    await downloader().downloadSplitToFile(split: _split(), destPath: dest);
    expect(File(dest).readAsBytesSync(), _full);
  });

  test('release asset single file reports per-part slot 0', () async {
    final single = ReleaseAsset(
      name: 'a.zst',
      downloadUrl: 'https://x/p0',
      size: 20,
      digest: 'sha256:${_sha(_parts[0])}',
    );
    final emits = <int>[];
    final existing = <int>[];
    await downloader().downloadReleaseAssetToFile(
      asset: single,
      destPath: dest,
      onPartProgress: (part, d, _) {
        expect(part, 0);
        emits.add(d);
      },
      onPartExisting: (part, b) => existing.add(b),
    );
    expect(emits, isNotEmpty);
    expect(emits.last, 20);
  });

  test('release asset split forwards per-part callbacks', () async {
    final asset = ReleaseAsset(
      name: 'a.zst',
      downloadUrl: 'https://x/m',
      size: 40,
      split: _split(),
    );
    final seenParts = <int>{};
    await downloader().downloadReleaseAssetToFile(
      asset: asset,
      destPath: dest,
      onPartProgress: (part, d, t) => seenParts.add(part),
    );
    expect(seenParts, {0, 1});
  });

  test('onProgress that throws fails the download (documented)', () async {
    final single = ReleaseAsset(
      name: 'a.zst',
      downloadUrl: 'https://x/p0',
      size: 20,
    );
    await expectLater(
      downloader().downloadReleaseAssetToFile(
        asset: single,
        destPath: dest,
        onProgress: (_, _) => throw StateError('boom'),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
