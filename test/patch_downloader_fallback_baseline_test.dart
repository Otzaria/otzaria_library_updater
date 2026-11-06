import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/src/services/download_scheduler.dart';
import 'package:seforim_library_updater/src/services/patch_downloader.dart';
import 'package:test/test.dart';

const _size = 40;
const _url = 'https://example.test/a.bin';

final _full = Uint8List.fromList(List.generate(_size, (i) => i));
final _sha = sha256.convert(_full).toString();

/// [overrun]: טווח היעד מחזיר גוף ארוך מהמוצהר אחרי [firstChunk] בתים.
class _Run {
  _Run(this.tmp);

  final Directory tmp;
  final baselines = <int>[];
  final meter = <(int, int?)>[];
  final ranges = <String?>[];
  late final dest = p.join(tmp.path, 'a.bin');

  void seed({required int head, int? seg1Len}) {
    File(dest).writeAsBytesSync(_full.sublist(0, head));
    if (seg1Len != null) {
      File('$dest.seg-1').writeAsBytesSync(_full.sublist(20, 20 + seg1Len));
    }
    File('$dest.resume').writeAsStringSync('t1\n"same"');
    File('$dest.segments').writeAsStringSync(
      jsonEncode({
        'v': 1,
        'token': 't1',
        'url': _url,
        'size': _size,
        'sha256': _sha,
        'etag': '"same"',
        'bounds': [0, 20, 40],
        'assembled': 1,
      }),
    );
  }

  Future<void> run({
    required Future<http.StreamedResponse> Function(
      http.BaseRequest,
      int start,
      int end,
    )
    serve,
    bool Function()? isCancelled,
  }) async {
    final aggregator = ByteProgressAggregator(
      totalBytes: _size,
      onProgress: (d, t) => meter.add((d, t)),
    );
    final slot = aggregator.slot();
    final client = MockClient.streaming((request, _) {
      ranges.add(request.headers['Range']);
      final m = RegExp(
        r'bytes=(\d+)-(\d*)',
      ).firstMatch(request.headers['Range']!)!;
      return serve(
        request,
        int.parse(m.group(1)!),
        int.tryParse(m.group(2)!) ?? _size - 1,
      );
    });
    final d = PatchDownloader(
      decompress: (_) async => null,
      httpClient: client,
      maxConnections: 2,
      segmentThresholdBytes: 16,
      networkRetryDelays: const [],
    );
    try {
      await d.downloadToFile(
        url: _url,
        destPath: dest,
        expectedSize: _size,
        expectedSha256: _sha,
        resumeToken: 't1',
        onProgress: slot.report,
        onExistingBytes: (n) {
          baselines.add(n);
          slot.markExisting(n);
        },
        isCancelled: isCancelled,
      );
    } finally {
      d.dispose();
      client.close();
    }
  }
}

http.StreamedResponse _partial(int start, int end, Stream<List<int>> body) =>
    http.StreamedResponse(
      body,
      206,
      contentLength: end - start + 1,
      headers: {'etag': '"same"', 'content-range': 'bytes $start-$end/$_size'},
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('fallback_baseline'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // טווח היעד כותב 5 בתים ואז גוף עודף מכשיל את ההורדה המפוצלת.
  Future<http.StreamedResponse> overrun(
    http.BaseRequest r,
    int start,
    int end,
  ) async {
    if (start == 10 && end == 19) {
      return _partial(start, end, () async* {
        yield _full.sublist(10, 15);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        yield List<int>.filled(6, 255);
      }());
    }
    return _partial(start, end, Stream.value(_full.sublist(start, end + 1)));
  }

  test(
    'נפילה אחרי כתיבה חלקית: הבסיס אינו כולל בתים חדשים או טווחים שנמחקו',
    () async {
      final run = _Run(tmp)..seed(head: 10, seg1Len: 10);

      await run.run(serve: overrun);

      expect(run.baselines.first, 10);
      expect(run.baselines.reduce((a, b) => a > b ? a : b), 20);
      // אחרי הנפילה רק 10 הבתים מתחילת הפעולה שרדו.
      expect(run.baselines.last, 10);
      expect(run.baselines, isNot(contains(15)));
      expect(File(run.dest).readAsBytesSync(), _full);
      expect(run.meter.last, (30, 30));
    },
  );

  test('נפילה בלי בתים ישנים ביעד: הבסיס יורד ל-0', () async {
    final run = _Run(tmp)..seed(head: 0, seg1Len: 10);
    File(run.dest).deleteSync();

    await run.run(
      serve: (r, start, end) async {
        if (start == 0 && end == 19) {
          return _partial(start, end, () async* {
            yield _full.sublist(0, 5);
            await Future<void>.delayed(const Duration(milliseconds: 50));
            yield List<int>.filled(20, 255);
          }());
        }
        return _partial(
          start,
          end,
          Stream.value(_full.sublist(start, end + 1)),
        );
      },
    );

    expect(run.baselines.last, 0);
    expect(run.baselines.where((b) => b > 10), isEmpty);
    expect(File(run.dest).readAsBytesSync(), _full);
    expect(run.meter.last, (_size, _size));
  });

  test(
    'הבסיס שדווח אינו עולה על הבתים הישנים שבדיסק גם בנפילה חוזרת',
    () async {
      final run = _Run(tmp)..seed(head: 10);

      await run.run(serve: overrun);

      expect(run.baselines.last, lessThanOrEqualTo(10));
      expect(File(run.dest).readAsBytesSync(), _full);
      for (var i = 1; i < run.meter.length; i++) {
        expect(run.meter[i].$1, greaterThanOrEqualTo(0));
      }
    },
  );

  test('ביטול באמצע: נזרקת שגיאת ביטול והבסיס לא עולה', () async {
    final run = _Run(tmp)..seed(head: 10, seg1Len: 10);
    var cancel = false;

    await expectLater(
      run.run(
        isCancelled: () => cancel,
        serve: (r, start, end) async {
          cancel = true;
          return overrun(r, start, end);
        },
      ),
      throwsA(isA<Exception>()),
    );

    expect(run.baselines.where((b) => b > 20), isEmpty);
    expect(run.baselines, isNot(contains(15)));
  });
}
