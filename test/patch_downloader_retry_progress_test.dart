import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/src/services/download_scheduler.dart';
import 'package:seforim_library_updater/src/services/patch_downloader.dart';
import 'package:test/test.dart';

const _fileSize = 40;

Uint8List _data(int seed) =>
    Uint8List.fromList(List.generate(_fileSize, (i) => (i * 7 + seed) & 0xff));

/// שרת בזיכרון: הניסיון הראשון נקטע אחרי [cutAfter] בתים, השאר מכבדים Range.
class _FlakyAsset {
  _FlakyAsset(this.data, {this.cutAfter = 10, this.cuts = 1});

  final Uint8List data;
  final int cutAfter;
  int cuts;
  final List<({String? range, String? ifRange})> requests = [];

  Future<http.StreamedResponse> handle(
    http.BaseRequest request,
    http.ByteStream _,
  ) async {
    final range = request.headers['Range'];
    final ifRange = request.headers['If-Range'];
    requests.add((range: range, ifRange: ifRange));
    final start = range == null
        ? 0
        : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
    final partial = range != null && ifRange == '"v1"';
    final from = partial ? start : 0;
    final body = data.sublist(from);
    final headers = <String, String>{'etag': '"v1"'};
    if (partial) {
      headers['content-range'] =
          'bytes $from-${data.length - 1}/${data.length}';
    }
    Stream<List<int>> stream;
    if (cuts > 0) {
      cuts--;
      stream = () async* {
        yield body.sublist(0, cutAfter);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw const SocketException('reset');
      }();
    } else {
      stream = Stream.value(body);
    }
    return http.StreamedResponse(
      stream,
      partial ? 206 : 200,
      contentLength: body.length,
      headers: headers,
    );
  }
}

typedef _Emit = (int, int?);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('retry_progress'));
  tearDown(() => tmp.deleteSync(recursive: true));

  PatchDownloader downloader(_FlakyAsset a) => PatchDownloader(
    decompress: (_) async => null,
    httpClient: MockClient.streaming(a.handle),
    networkRetryDelays: const [Duration(milliseconds: 5)],
    maxConnections: 1,
  );

  void expectSteady(List<_Emit> emits, int total, int finalSum) {
    expect(emits, isNotEmpty);
    for (var i = 0; i < emits.length; i++) {
      expect(emits[i].$2, total, reason: 'total at $i: $emits');
      if (i > 0) {
        expect(
          emits[i].$1,
          greaterThanOrEqualTo(emits[i - 1].$1),
          reason: 'sum regressed at $i: $emits',
        );
      }
    }
    expect(emits.last, (finalSum, total));
  }

  test('התחלה נקייה: קטיעה והמשך אינם מאפסים את המד', () async {
    final asset = _FlakyAsset(_data(1));
    final emits = <_Emit>[];
    final aggregator = ByteProgressAggregator(
      totalBytes: _fileSize,
      onProgress: (d, t) => emits.add((d, t)),
    );
    final slot = aggregator.slot();
    final dest = p.join(tmp.path, 'a.bin');

    await downloader(asset).downloadToFile(
      url: 'https://example.test/a.bin',
      destPath: dest,
      expectedSize: _fileSize,
      expectedSha256: sha256.convert(asset.data).toString(),
      resumeToken: 't1',
      onProgress: slot.report,
      onExistingBytes: slot.markExisting,
    );

    expect(File(dest).readAsBytesSync(), asset.data);
    expect(asset.requests[1].range, 'bytes=10-');
    expect(asset.requests[1].ifRange, '"v1"');
    expectSteady(emits, _fileSize, _fileSize);
  });

  test('חלקי מהריצה הקודמת: המד מתחיל ממנו וקטיעה אינה מאפסת', () async {
    final asset = _FlakyAsset(_data(2));
    final dest = p.join(tmp.path, 'b.bin');
    File(dest).writeAsBytesSync(asset.data.sublist(0, 10));
    File('$dest.resume').writeAsStringSync('t1\n"v1"');
    final emits = <_Emit>[];
    final aggregator = ByteProgressAggregator(
      totalBytes: _fileSize,
      onProgress: (d, t) => emits.add((d, t)),
    );
    final slot = aggregator.slot();

    await downloader(asset).downloadToFile(
      url: 'https://example.test/b.bin',
      destPath: dest,
      expectedSize: _fileSize,
      expectedSha256: sha256.convert(asset.data).toString(),
      resumeToken: 't1',
      onProgress: slot.report,
      onExistingBytes: slot.markExisting,
    );

    expect(File(dest).readAsBytesSync(), asset.data);
    expect(asset.requests.first.range, 'bytes=10-');
    expect(asset.requests[1].range, 'bytes=20-');
    expectSteady(emits.where((e) => e.$2 != null).toList(), 30, 30);
  });

  test('כמה קבצים במקביל: סכום מונוטוני וסך קבוע', () async {
    final assets = [_FlakyAsset(_data(3)), _FlakyAsset(_data(4), cutAfter: 25)];
    final emits = <_Emit>[];
    final aggregator = ByteProgressAggregator(
      totalBytes: _fileSize * 2,
      onProgress: (d, t) => emits.add((d, t)),
    );
    final slots = [aggregator.slot(), aggregator.slot()];

    await Future.wait([
      for (var i = 0; i < 2; i++)
        downloader(assets[i]).downloadToFile(
          url: 'https://example.test/$i.bin',
          destPath: p.join(tmp.path, '$i.bin'),
          expectedSize: _fileSize,
          expectedSha256: sha256.convert(assets[i].data).toString(),
          resumeToken: 't$i',
          onProgress: slots[i].report,
          onExistingBytes: slots[i].markExisting,
        ),
    ]);

    expectSteady(emits, _fileSize * 2, _fileSize * 2);
  });

  test('חלקי בלי validator נמחק: איפוס אמיתי של המד מותר', () async {
    final asset = _FlakyAsset(_data(5), cuts: 0);
    final dest = p.join(tmp.path, 'c.bin');
    File(dest).writeAsBytesSync(asset.data.sublist(0, 10));
    File('$dest.resume').writeAsStringSync('t1');
    final emits = <_Emit>[];
    final aggregator = ByteProgressAggregator(
      totalBytes: _fileSize,
      onProgress: (d, t) => emits.add((d, t)),
    );
    final slot = aggregator.slot(existingBytes: 10);

    await downloader(asset).downloadToFile(
      url: 'https://example.test/c.bin',
      destPath: dest,
      expectedSize: _fileSize,
      expectedSha256: sha256.convert(asset.data).toString(),
      resumeToken: 't1',
      onProgress: slot.report,
      onExistingBytes: slot.markExisting,
    );

    expect(File(dest).readAsBytesSync(), asset.data);
    expect(asset.requests.single.range, isNull);
    expect(emits.last, (_fileSize, _fileSize));
  });
}
