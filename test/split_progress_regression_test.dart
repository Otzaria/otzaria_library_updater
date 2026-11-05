import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seforim_library_updater/src/models/split_asset.dart';
import 'package:seforim_library_updater/src/services/download_scheduler.dart';
import 'package:seforim_library_updater/src/services/patch_downloader.dart';
import 'package:test/test.dart';

String _sha(List<int> b) => sha256.convert(b).toString();

final _full = Uint8List.fromList(List.generate(60, (i) => i * 3));
final _parts = [_full.sublist(0, 20), _full.sublist(20, 40), _full.sublist(40)];

String _name(int i) => 'a.zst.part-${i.toString().padLeft(3, '0')}';

SplitAsset _split() => SplitAsset.fromManifestJson(
  {
    'schemaVersion': 1,
    'archive': 'a.zst',
    'size': 60,
    'sha256': _sha(_full),
    'partSizeLimit': 20,
    'githubAssetLimit': kGithubAssetLimit,
    'parts': [
      for (var i = 0; i < 3; i++)
        {'name': _name(i), 'size': 20, 'sha256': _sha(_parts[i])},
    ],
  },
  manifestName: 'a.zst.manifest.json',
  partUrls: {for (var i = 0; i < 3; i++) _name(i): 'https://x/${_name(i)}'},
);

void main() {
  late Directory tmp;
  late String dest;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('split_progress_regression');
    dest = '${tmp.path}/a.zst';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  PatchDownloader downloader({required bool honor206}) => PatchDownloader(
    decompress: (c) async => c,
    networkRetryDelays: const [],
    httpClient: MockClient.streaming((request, _) async {
      final i = int.parse(request.url.path.split('part-').last);
      final range = request.headers['Range'];
      if (range != null && honor206 && i == 1) {
        final start = int.parse(
          RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
        );
        return http.StreamedResponse(
          Stream.value(_parts[i].sublist(start)),
          206,
          contentLength: 20 - start,
          headers: {'etag': '"p1"', 'content-range': 'bytes $start-19/20'},
        );
      }
      return http.StreamedResponse(
        Stream.value(_parts[i]),
        200,
        contentLength: 20,
        headers: {'etag': '"p$i"'},
      );
    }),
  );

  void seedPartialPart1() {
    final path = PatchDownloader.splitPartPath(dest, 1);
    File(path).writeAsBytesSync(_parts[1].sublist(0, 8));
    File(
      '$path.resume',
    ).writeAsStringSync('v1|${_name(1)}|${_sha(_parts[1])}\n"p1"');
  }

  Future<List<(int, int?)>> run({required bool honor206}) async {
    seedPartialPart1();
    final emits = <(int, int?)>[];
    final aggregator = ByteProgressAggregator(
      totalBytes: 60,
      onProgress: (d, t) => emits.add((d, t)),
    );
    final slots = [for (var i = 0; i < 3; i++) aggregator.slot()];
    await downloader(honor206: honor206).downloadSplitToFile(
      split: _split(),
      destPath: dest,
      resumeToken: 'v1',
      onPartProgress: (part, d, total) => slots[part].report(d, total),
      onPartExisting: (part, bytes) => slots[part].markExisting(bytes),
    );
    expect(File(dest).readAsBytesSync(), _full);
    return emits;
  }

  void expectNeverBelow(List<(int, int?)> emits, int floor, int fromIndex) {
    for (var i = fromIndex; i < emits.length; i++) {
      expect(emits[i].$1, greaterThanOrEqualTo(floor), reason: '$emits');
    }
  }

  group('מונה מאחד להורדה מפוצלת עם חלק מאוחר חלקי על הדיסק', () {
    test('206: בתי החלק הראשון שירדו ברשת אינם נחתכים', () async {
      final emits = await run(honor206: true);
      final afterPart0 = emits.indexWhere((e) => e.$1 >= 20);
      expect(afterPart0, isNonNegative, reason: '$emits');
      expectNeverBelow(emits, 20, afterPart0);
      // 8 הבתים שכבר על הדיסק אינם בתי רשת.
      expect(emits.last, (52, 52));
    });

    test('200 לבקשת Range: הבסיס יורד ל-0 וחלק 0 נשמר', () async {
      final emits = await run(honor206: false);
      final afterPart0 = emits.indexWhere((e) => e.$1 >= 20);
      expect(afterPart0, isNonNegative, reason: '$emits');
      expectNeverBelow(emits, 20, afterPart0);
      expect(emits.last, (60, 60));
    });
  });

  test(
    'fuzz דטרמיניסטי: ירידת בסיס חותכת רק את החלק שלה, בלי חריגה מ-100%',
    () {
      for (var seed = 0; seed < 200; seed++) {
        final random = Random(seed);
        const size = 20;
        final emits = <(int, int?)>[];
        final aggregator = ByteProgressAggregator(
          totalBytes: 60,
          onProgress: (d, t) => emits.add((d, t)),
        );
        final slots = [for (var i = 0; i < 3; i++) aggregator.slot()];
        final received = [0, 0, 0];
        final base = [0, 0, 0];
        int net(int i) => max(0, received[i] - base[i]);
        int sum() => net(0) + net(1) + net(2);

        for (var step = 0; step < 40; step++) {
          final part = random.nextInt(3);
          final before = [net(0), net(1), net(2)];
          final sumBefore = sum();
          if (random.nextBool()) {
            final value = min(received[part] + random.nextInt(6), size);
            received[part] = max(received[part], value);
            slots[part].report(value, size);
          } else {
            final value = random.nextInt(size + 1);
            if (value < base[part] && received[part] > value) {
              received[part] = value;
            }
            base[part] = value;
            slots[part].markExisting(value);
          }
          for (var other = 0; other < 3; other++) {
            if (other != part) {
              expect(net(other), before[other], reason: 'seed $seed');
            }
          }
          final (reported, total) = emits.isEmpty ? (0, 60) : emits.last;
          expect(reported, sum(), reason: 'seed $seed step $step');
          expect(reported, lessThanOrEqualTo(total!), reason: 'seed $seed');
          expect(total, lessThanOrEqualTo(60), reason: 'seed $seed');
          // נסיגה מותרת רק עד הבתים של החלק שנגע בו עצמו.
          expect(
            sumBefore - reported,
            lessThanOrEqualTo(before[part]),
            reason: 'seed $seed step $step',
          );
        }
      }
    },
  );

  group('callback התקדמות שזורק', () {
    test('onAssembleProgress שזורק אינו מפיל הורדה תקינה', () async {
      var calls = 0;
      await downloader(honor206: true).downloadSplitToFile(
        split: _split(),
        destPath: dest,
        resumeToken: 'v1',
        onAssembleProgress: (_, _) {
          calls++;
          throw StateError('ui callback failed');
        },
      );
      expect(calls, greaterThan(0));
      expect(File(dest).readAsBytesSync(), _full);
    });

    test('onVerifyProgress שזורק אינו מפיל אימות של ארכיון קיים', () async {
      final d = downloader(honor206: true);
      await d.downloadSplitToFile(
        split: _split(),
        destPath: dest,
        resumeToken: 'v1',
      );
      var calls = 0;
      await d.downloadSplitToFile(
        split: _split(),
        destPath: dest,
        resumeToken: 'v1',
        onVerifyProgress: (_, _) {
          calls++;
          throw StateError('ui callback failed');
        },
      );
      expect(calls, greaterThan(0));
      expect(File(dest).readAsBytesSync(), _full);
    });
  });
}
