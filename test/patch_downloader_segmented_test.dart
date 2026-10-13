import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/src/services/patch_downloader.dart';
import 'package:test/test.dart';

typedef _Request = ({String? range, String? ifRange, int status, int start});

/// שרת נכסים מקומי עם Range, If-Range ו-ETag, וניתוק יזום באמצע גוף.
class _AssetServer {
  _AssetServer(this.data);

  Uint8List data;
  String? etag = '"v1"';
  bool honorRange = true;
  Duration chunkDelay = Duration.zero;

  /// כמה בתים לשלוח לפני ניתוק; null — גוף מלא.
  int? Function(int start, int end, int requestIndex)? cutAfter;

  /// משנה את הגוף לפני השליחה (תוכן פגום).
  Uint8List Function(int start, Uint8List body)? mutate;

  final List<_Request> requests = [];
  int active = 0;
  int maxActive = 0;
  late HttpServer _server;

  String get url => 'http://127.0.0.1:${_server.port}/asset.bin';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final range = request.headers.value('range');
    final ifRange = request.headers.value('if-range');
    var start = 0;
    var end = data.length - 1;
    final match =
        range == null ? null : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
    final partial =
        match != null && honorRange && (ifRange == null || ifRange == etag);
    if (partial) {
      start = int.parse(match.group(1)!);
      if (match.group(2)!.isNotEmpty) {
        end = int.parse(match.group(2)!).clamp(0, data.length - 1);
      }
      response.statusCode = 206;
      response.headers.set('content-range', 'bytes $start-$end/${data.length}');
    }
    if (etag != null) response.headers.set('etag', etag!);
    var body = Uint8List.sublistView(data, start, end + 1);
    body = mutate?.call(start, Uint8List.fromList(body)) ?? body;
    response.contentLength = body.length;
    requests.add((
      range: range,
      ifRange: ifRange,
      status: partial ? 206 : 200,
      start: start,
    ));
    final cut = cutAfter?.call(start, end, requests.length - 1);
    if (cut != null) {
      final socket = await response.detachSocket();
      socket.add(body.sublist(0, cut));
      await socket.flush();
      socket.destroy();
      return;
    }
    active++;
    if (active > maxActive) maxActive = active;
    try {
      const chunk = 64 << 10;
      for (var offset = 0; offset < body.length; offset += chunk) {
        final next =
            offset + chunk < body.length ? offset + chunk : body.length;
        response.add(body.sublist(offset, next));
        await response.flush();
        if (chunkDelay > Duration.zero) await Future<void>.delayed(chunkDelay);
      }
      await response.close();
    } catch (_) {
    } finally {
      active--;
    }
  }
}

/// סופר את הבתים שהגיעו בפועל לקוד ההורדה — השרת אינו יודע מתי הלקוח סגר.
class _CountingClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  int received = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    return http.StreamedResponse(
      response.stream.map((chunk) {
        received += chunk.length;
        return chunk;
      }),
      response.statusCode,
      contentLength: response.contentLength,
      headers: response.headers,
      request: response.request,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

Uint8List _data(int length, [int seed = 0]) => Uint8List.fromList(
    List.generate(length, (i) => (i * 31 + i ~/ 251 + seed) & 0xff));

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  const threshold = 1 << 20;
  const size = 4 << 20;
  late Directory tmp;
  late _AssetServer server;
  late String dest;
  late _CountingClient client;

  PatchDownloader downloader({
    List<Duration> retries = const [
      Duration(milliseconds: 10),
      Duration(milliseconds: 10),
    ],
    int maxConnections = 4,
  }) =>
      PatchDownloader(
        decompress: (_) async => null,
        httpClient: client,
        networkRetryDelays: retries,
        stallTimeout: const Duration(seconds: 10),
        maxConnections: maxConnections,
        segmentThresholdBytes: threshold,
      );

  Future<void> download(
    PatchDownloader d, {
    String? sha,
    String? token = 'asset-1',
    void Function(int, int?)? onProgress,
    bool Function()? isCancelled,
  }) =>
      d.downloadToFile(
        url: server.url,
        destPath: dest,
        expectedSize: server.data.length,
        expectedSha256: sha,
        resumeToken: token,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );

  List<String> leftovers() => [
        for (final f in tmp.listSync())
          if (RegExp(r'\.(segments|seg-\d+)$').hasMatch(f.path))
            p.basename(f.path),
      ];

  int bytesOnDisk() => [
        for (final f in tmp.listSync())
          if (f is File &&
              !f.path.endsWith('.resume') &&
              !f.path.endsWith('.segments'))
            f.lengthSync(),
      ].fold(0, (a, b) => a + b);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('segmented_test');
    dest = p.join(tmp.path, 'seforim.db.zst');
    server = _AssetServer(_data(size));
    client = _CountingClient();
    await server.start();
  });

  tearDown(() async {
    client.close();
    await server.close();
    tmp.deleteSync(recursive: true);
  });

  test('206: ארבעה טווחים במקביל, קובץ תקין, בלי שאריות ובלי בית כפול',
      () async {
    server.chunkDelay = const Duration(milliseconds: 2);
    final progress = <(int, int?)>[];
    await download(downloader(),
        sha: _sha(server.data), onProgress: (d, t) => progress.add((d, t)));

    expect(File(dest).readAsBytesSync(), server.data);
    expect(leftovers(), isEmpty);
    expect(server.requests, hasLength(4));
    expect(server.requests.every((r) => r.status == 206), isTrue);
    // הבדיקה המקדימה היא טווח 1, לא תחילת הקובץ.
    expect(server.requests.first.start, size ~/ 4);
    expect(server.requests.map((r) => r.start).toSet(),
        {0, size ~/ 4, size ~/ 2, 3 * size ~/ 4});
    expect(server.maxActive, 4);
    expect(client.received, size);

    // המד מסכם את כל הטווחים, מונוטוני, מוגבל בקצב ומסתיים ב-100%.
    expect(progress.last, (size, size));
    expect(progress.every((e) => e.$2 == size), isTrue);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i].$1, greaterThanOrEqualTo(progress[i - 1].$1));
    }
    expect(progress.length, lessThan(size ~/ (64 << 10)));
    // סימון האימות נשמר, כמו במסלול החיבור היחיד.
    final sidecar = File('$dest.resume').readAsStringSync().split('\n');
    expect(sidecar[0], 'asset-1');
    expect(sidecar[1], '"v1"');
    expect(sidecar[2], startsWith(_sha(server.data)));
  });

  test('שרת שמתעלם מ-Range (200) → חיבור אחד, הגוף לא יורד פי ארבעה', () async {
    server.data = _data(16 << 20);
    server.honorRange = false;
    server.chunkDelay = const Duration(milliseconds: 1);
    await download(downloader(), sha: _sha(server.data));

    expect(File(dest).readAsBytesSync(), server.data);
    expect(server.requests, hasLength(2));
    expect(server.requests[0].range, isNotNull);
    expect(server.requests[1].range, isNull);
    expect(client.received, lessThan(server.data.length * 3 ~/ 2));
    expect(leftovers(), isEmpty);
  });

  test('ניתוק באמצע כל טווח → כל טווח ממשיך מהבית שבו נקטע', () async {
    final seen = <int>{};
    server.cutAfter = (start, end, _) {
      if (!seen.add(end)) return null;
      return (end - start + 1) ~/ 2;
    };
    await download(downloader(), sha: _sha(server.data));

    expect(File(dest).readAsBytesSync(), server.data);
    expect(server.requests, hasLength(8));
    final quarter = size ~/ 4;
    expect(
      server.requests.skip(4).map((r) => r.start).toSet(),
      {for (var i = 0; i < 4; i++) i * quarter + quarter ~/ 2},
    );
    expect(client.received, size);
  });

  test('ניסיון שהביא בתים מאפס את המונה; רק רצף בלי בתים מפיל', () async {
    // טווח של 1MB נקטע אחרי 256KB בכל בקשה: ארבע בקשות עם התקדמות.
    server.cutAfter = (start, end, _) {
      final left = end - start + 1;
      return left > (256 << 10) ? 256 << 10 : null;
    };
    await download(downloader(retries: const [Duration(milliseconds: 5)]),
        sha: _sha(server.data));
    expect(File(dest).readAsBytesSync(), server.data);

    File(dest).deleteSync();
    File('$dest.resume').deleteSync();
    server.requests.clear();
    // טווח 2 נקטע תמיד לפני הבית הראשון: נכשל אחרי 1+1 ניסיונות.
    server.cutAfter = (start, end, _) => start == size ~/ 2 ? 0 : null;
    await expectLater(
      download(downloader(retries: const [Duration(milliseconds: 5)]),
          sha: _sha(server.data)),
      throwsA(isA<PatchNetworkException>()),
    );
    expect(server.requests.where((r) => r.start == size ~/ 2), hasLength(2));
    expect(File('$dest.segments').existsSync(), isTrue);
  });

  test('ETag שהתחלף → If-Range מקבל 200, כל הטווחים מתחילים מאפס', () async {
    server.cutAfter = (start, end, _) => (end - start + 1) ~/ 2;
    await expectLater(download(downloader(retries: const [])),
        throwsA(isA<PatchNetworkException>()));
    expect(File('$dest.segments').existsSync(), isTrue);

    server.cutAfter = null;
    server.data = _data(size, 7);
    server.etag = '"v2"';
    server.requests.clear();
    await download(downloader());

    expect(File(dest).readAsBytesSync(), server.data);
    expect(server.requests.first.ifRange, '"v1"');
    expect(server.requests.first.status, 200);
    expect(server.requests.skip(1).every((r) => r.ifRange != '"v1"'), isTrue);
    expect(leftovers(), isEmpty);
  });

  test('הפעלה מחדש אחרי קריסה ממשיכה מהמצב השמור של כל טווח', () async {
    server.cutAfter = (start, end, _) => (end - start + 1) ~/ 3;
    await expectLater(
      download(downloader(retries: const []), sha: _sha(server.data)),
      throwsA(isA<PatchNetworkException>()),
    );
    final state = jsonDecode(File('$dest.segments').readAsStringSync()) as Map;
    final bounds = (state['bounds'] as List).cast<int>();
    final kept = [
      File(dest).lengthSync(),
      for (var i = 1; i < 4; i++)
        File('$dest.seg-$i').existsSync()
            ? File('$dest.seg-$i').lengthSync()
            : 0,
    ];
    final keptTotal = kept.fold<int>(0, (a, b) => a + b);
    expect(keptTotal, greaterThan(0));

    server.cutAfter = null;
    server.requests.clear();
    client.received = 0;
    // מופע חדש: רק מה שעל הדיסק עובר בין הריצות.
    await download(downloader(), sha: _sha(server.data));

    expect(File(dest).readAsBytesSync(), server.data);
    expect(server.requests.map((r) => r.start).toSet(), {
      for (var i = 0; i < 4; i++)
        if (kept[i] < bounds[i + 1] - bounds[i]) bounds[i] + kept[i],
    });
    expect(server.requests.every((r) => r.ifRange == '"v1"'), isTrue);
    expect(client.received, size - keptTotal);
    expect(leftovers(), isEmpty);
  });

  /// מצב של כל הטווחים שלמים, כש-[assembled] מהם כבר ב-dest ואחריהם זנב
  /// של צירוף שנקטע לפני שנרשם.
  void writeCompleteSegments(int assembled) {
    final quarter = size ~/ 4;
    final bounds = [0, quarter, 2 * quarter, 3 * quarter, size];
    File(dest).writeAsBytesSync([
      ...server.data.sublist(0, bounds[assembled]),
      ...List.filled(1000, 0xEE),
    ]);
    for (var i = assembled; i < 4; i++) {
      File('$dest.seg-$i')
          .writeAsBytesSync(server.data.sublist(bounds[i], bounds[i + 1]));
    }
    File('$dest.resume').writeAsStringSync('asset-1\n"v1"');
    File('$dest.segments').writeAsStringSync(jsonEncode({
      'v': 1,
      'token': 'asset-1',
      'url': server.url,
      'size': size,
      'sha256': _sha(server.data),
      'etag': '"v1"',
      'bounds': bounds,
      'assembled': assembled,
    }));
  }

  for (final assembled in [1, 2]) {
    test('קריסה באמצע הצירוף (assembled: $assembled): הזנב נחתך, בלי הורדה',
        () async {
      writeCompleteSegments(assembled);
      await download(downloader(), sha: _sha(server.data));

      expect(File(dest).readAsBytesSync(), server.data);
      expect(server.requests, isEmpty);
      expect(leftovers(), isEmpty);
    });
  }

  test('ביטול באמצע הצירוף נתפס ושומר את הטווחים שטרם צורפו', () async {
    server.data = _data(64 << 20);
    final sha = _sha(server.data);
    var cancel = false;
    await expectLater(
      downloader().downloadToFile(
        url: server.url,
        destPath: dest,
        expectedSize: server.data.length,
        expectedSha256: sha,
        resumeToken: 'asset-1',
        onVerifyProgress: (_, __) => cancel = true,
        isCancelled: () => cancel,
      ),
      throwsA(isA<PatchDownloadCancelled>()),
    );
    final state = jsonDecode(File('$dest.segments').readAsStringSync()) as Map;
    expect(state['assembled'], lessThan(4));
    expect(File('$dest.seg-3').existsSync(), isTrue);

    client.received = 0;
    await download(downloader(), sha: sha);
    expect(client.received, 0);
    expect(File(dest).readAsBytesSync(), server.data);
    expect(leftovers(), isEmpty);
  });

  test('כשל דיסק בצירוף → PatchDownloadException, הטווחים נשמרים', () async {
    writeCompleteSegments(1);
    // dest לקריאה בלבד: הגיבוב קורא אותו, והפתיחה לכתיבה נכשלת.
    await Process.run('attrib', ['+r', dest]);
    try {
      await expectLater(download(downloader(), sha: _sha(server.data)),
          throwsA(isA<PatchDownloadException>()));
    } finally {
      await Process.run('attrib', ['-r', dest]);
    }
    expect(File('$dest.segments').existsSync(), isTrue);
    expect(File('$dest.seg-3').existsSync(), isTrue);
  }, testOn: 'windows');

  test('הורדה שנייה לאותו יעד נכשלת מיד ואינה נוגעת בקבצים', () async {
    server.chunkDelay = const Duration(milliseconds: 5);
    final first = download(downloader(), sha: _sha(server.data));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await expectLater(download(downloader(), sha: _sha(server.data)),
        throwsA(isA<PatchDownloadException>()));
    await first;
    expect(File(dest).readAsBytesSync(), server.data);
    expect(File('$dest.lock').existsSync(), isFalse);

    // אחרי שהראשונה סיימה, אותו יעד פנוי שוב ונשאר שלם.
    await download(downloader(), sha: _sha(server.data));
    expect(File(dest).readAsBytesSync(), server.data);
  });

  test('שאריות טווחים בלי קובץ מצב נמחקות בתחילת ההורדה', () async {
    // קובץ קטן: הורדה בחיבור יחיד, שלא כותבת קובץ מצב משלה.
    server.data = _data(threshold - 1);
    File('$dest.seg-2').writeAsStringSync('stale');
    File('$dest.segments.tmp').writeAsStringSync('stale');
    await download(downloader(), sha: _sha(server.data));
    expect(File(dest).readAsBytesSync(), server.data);
    expect(
        tmp.listSync().map((f) => p.basename(f.path)),
        isNot(anyOf(contains('seforim.db.zst.seg-2'),
            contains('seforim.db.zst.segments.tmp'))));
  });

  test('sha256 שגוי → ניסיון נקי אחד; שגוי שוב → כשל ומחיקה', () async {
    var corrupted = 0;
    server.mutate = (start, body) {
      if (start == size ~/ 2 && corrupted++ == 0) body[10] ^= 0xFF;
      return body;
    };
    await download(downloader(), sha: _sha(server.data));
    expect(File(dest).readAsBytesSync(), server.data);
    expect(server.requests, hasLength(8));

    File(dest).deleteSync();
    File('$dest.resume').deleteSync();
    server.requests.clear();
    server.mutate = (start, body) {
      if (start == size ~/ 2) body[10] ^= 0xFF;
      return body;
    };
    await expectLater(download(downloader(), sha: _sha(server.data)),
        throwsA(isA<PatchDownloadException>()));
    expect(server.requests, hasLength(8));
    expect(File(dest).existsSync(), isFalse);
    expect(leftovers(), isEmpty);
  });

  test('ביטול עוצר את כל הטווחים ושומר את מה שירד', () async {
    server.chunkDelay = const Duration(milliseconds: 20);
    var cancel = false;
    await expectLater(
      download(downloader(),
          sha: _sha(server.data),
          onProgress: (d, _) => cancel = cancel || d >= 1 << 20,
          isCancelled: () => cancel),
      throwsA(isA<PatchDownloadCancelled>()),
    );
    final requestsAtCancel = server.requests.length;
    final kept = bytesOnDisk();
    expect(kept, greaterThan(0));
    expect(kept, lessThan(size));
    expect(File('$dest.segments').existsSync(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.requests.length, requestsAtCancel);

    server.chunkDelay = Duration.zero;
    client.received = 0;
    await download(downloader(), sha: _sha(server.data));
    expect(File(dest).readAsBytesSync(), server.data);
    expect(client.received, size - kept);
  });

  test('קובץ קטן מהסף, או maxConnections: 1 → חיבור יחיד בלי Range', () async {
    server.data = _data(threshold - 1);
    await download(downloader(), sha: _sha(server.data));
    expect(File(dest).readAsBytesSync(), server.data);
    expect(server.requests, hasLength(1));
    expect(server.requests.single.range, isNull);

    File(dest).deleteSync();
    File('$dest.resume').deleteSync();
    server.data = _data(size);
    server.requests.clear();
    await download(downloader(maxConnections: 1), sha: _sha(server.data));
    expect(File(dest).readAsBytesSync(), server.data);
    expect(server.requests.single.range, isNull);
  });

  test('בלי resumeToken: פיצול בתוך הריצה, בלי מצב שנשמר לדיסק', () async {
    server.cutAfter = (start, end, i) => i < 2 ? (end - start + 1) ~/ 2 : null;
    await download(downloader(), sha: _sha(server.data), token: null);
    expect(File(dest).readAsBytesSync(), server.data);
    expect(File('$dest.resume').existsSync(), isFalse);
    expect(leftovers(), isEmpty);
  });
}
