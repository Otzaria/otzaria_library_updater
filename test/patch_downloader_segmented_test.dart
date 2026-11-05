import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:seforim_library_updater/src/services/download_scheduler.dart';
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

  /// בקשות טווח שמתחילות כאן מקבלות 200 מלא (אחרי השהיה קצרה).
  bool Function(int start)? fullBodyFor;

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

  /// ממתין שבקשות מריצה קודמת שעוד בדרך יגיעו וייסגרו, לפני איפוס [requests].
  Future<void> settle() async {
    var seen = -1;
    while (seen != requests.length || active > 0) {
      seen = requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  // הלקוח סוגר בכוונה חיבורים מקבילים אחרי ניתוק/If-Range שלא תאם.
  // שגיאת הכתיבה נמסרת גם ב-done, מעבר ל-flush שממתינים לו ישירות.
  Future<void> _allowDisconnect(Future<dynamic> completion) async {
    try {
      await completion;
    } on SocketException {
      // ניתוק צפוי של לקוח הבדיקה.
    } on HttpException {
      // החיבור יכול להיסגר גם לפני שהתגובה נכתבה.
    }
  }

  Future<void> _handle(HttpRequest request) async {
    unawaited(_allowDisconnect(request.response.done));
    try {
      await _respond(request);
    } on SocketException {
      // הלקוח אינו חייב לקרוא גוף שננטש בעת ביטול טווחים אחרים.
    } on HttpException {
      // הלקוח יכול לנטוש גם לפני detachSocket/close.
    }
  }

  Future<void> _respond(HttpRequest request) async {
    final response = request.response;
    final range = request.headers.value('range');
    final ifRange = request.headers.value('if-range');
    var start = 0;
    var end = data.length - 1;
    final match = range == null
        ? null
        : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
    var partial =
        match != null && honorRange && (ifRange == null || ifRange == etag);
    if (partial && fullBodyFor?.call(int.parse(match.group(1)!)) == true) {
      partial = false;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (partial) {
      start = int.parse(match!.group(1)!);
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
      unawaited(_allowDisconnect(socket.done));
      try {
        socket.add(body.sublist(0, cut));
        await socket.flush();
      } finally {
        socket.destroy();
      }
      return;
    }
    active++;
    if (active > maxActive) maxActive = active;
    try {
      const chunk = 64 << 10;
      for (var offset = 0; offset < body.length; offset += chunk) {
        final next = offset + chunk < body.length
            ? offset + chunk
            : body.length;
        response.add(body.sublist(offset, next));
        await response.flush();
        if (chunkDelay > Duration.zero) await Future<void>.delayed(chunkDelay);
      }
      await response.close();
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

/// קובצי המצב (`.resume`, `.segments`) ב-isolate הראשי: כתיבה סינכרונית
/// נכשלת, וכל כתיבה אסינכרונית נרשמת יחד עם מספר הבקשות שכבר הגיעו לשרת.
final class _AsyncStateWritesOnly extends IOOverrides {
  _AsyncStateWritesOnly(this.requestsSoFar);

  final int Function() requestsSoFar;
  final List<({String name, String content, int requests})> writes = [];

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return RegExp(r'\.(resume|segments(\.tmp)?)$').hasMatch(path)
        ? _AsyncWritesFile(file, this)
        : file;
  }
}

class _AsyncWritesFile implements File {
  _AsyncWritesFile(this._real, this._owner);

  final File _real;
  final _AsyncStateWritesOnly _owner;

  @override
  String get path => _real.path;
  @override
  bool existsSync() => _real.existsSync();
  @override
  Future<bool> exists() => _real.exists();
  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      _real.readAsStringSync(encoding: encoding);
  @override
  void deleteSync({bool recursive = false}) => _real.deleteSync();
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    _owner.writes.add((
      name: p.basename(path),
      content: contents,
      requests: _owner.requestsSoFar(),
    ));
    return _real.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  Future<File> rename(String newPath) => _real.rename(newPath);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _real.delete(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('sync IO on state file: ${invocation.memberName}');
}

/// שאריות הטווחים נמחקות אסינכרונית בלבד: מחיקה סינכרונית של טווח בן כמה
/// GB הקפיאה את ה-UI (#4070). רושם את סדר המחיקות.
final class _AsyncDeletesOnly extends IOOverrides {
  final List<String> deleted = [];

  @override
  File createFile(String path) =>
      _AsyncDeleteFile(super.createFile(path), this);

  @override
  Directory createDirectory(String path) =>
      _AsyncListDirectory(super.createDirectory(path));
}

class _AsyncDeleteFile implements File {
  _AsyncDeleteFile(this._real, this._owner);

  final File _real;
  final _AsyncDeletesOnly _owner;

  @override
  String get path => _real.path;
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    final result = await _real.delete(recursive: recursive);
    _owner.deleted.add(p.basename(path));
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('sync IO: ${invocation.memberName}');
}

class _AsyncListDirectory implements Directory {
  _AsyncListDirectory(this._real);

  final Directory _real;

  @override
  String get path => _real.path;
  @override
  Stream<FileSystemEntity> list(
          {bool recursive = false, bool followLinks = true}) =>
      _real.list(recursive: recursive, followLinks: followLinks);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('sync IO: ${invocation.memberName}');
}

/// [dest] נמחק במסלולי שגיאה רק אסינכרונית; deleteSync עליו נכשל (#4070).
final class _NoSyncDestDelete extends IOOverrides {
  _NoSyncDestDelete(this.dest);

  final String dest;
  int syncDeletes = 0;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return p.equals(path, dest) ? _NoSyncDeleteFile(file, this) : file;
  }
}

class _NoSyncDeleteFile implements File {
  _NoSyncDeleteFile(this._real, this._owner);

  final File _real;
  final _NoSyncDestDelete _owner;

  @override
  String get path => _real.path;
  @override
  void deleteSync({bool recursive = false}) {
    _owner.syncDeletes++;
    throw UnsupportedError('deleteSync on dest');
  }
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _real.delete(recursive: recursive);
  @override
  bool existsSync() => _real.existsSync();
  @override
  Future<bool> exists() => _real.exists();
  @override
  int lengthSync() => _real.lengthSync();
  @override
  Future<int> length() => _real.length();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      _real.open(mode: mode);
  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      _real.openSync(mode: mode);
  @override
  IOSink openWrite(
          {FileMode mode = FileMode.write, Encoding encoding = utf8}) =>
      _real.openWrite(mode: mode, encoding: encoding);
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      _real.openRead(start, end);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unexpected: ${invocation.memberName}');
}

Uint8List _data(int length, [int seed = 0]) => Uint8List.fromList(
  List.generate(length, (i) => (i * 31 + i ~/ 251 + seed) & 0xff),
);

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
  }) => PatchDownloader(
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
    void Function(int)? onExistingBytes,
    int? connections,
    bool Function()? isCancelled,
  }) => d.downloadToFile(
    onExistingBytes: onExistingBytes,
    connections: connections,
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
      if (RegExp(r'\.(segments|seg-\d+)$').hasMatch(f.path)) p.basename(f.path),
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

  test(
    '206: ארבעה טווחים במקביל, קובץ תקין, בלי שאריות ובלי בית כפול',
    () async {
      server.chunkDelay = const Duration(milliseconds: 2);
      final progress = <(int, int?)>[];
      await download(
        downloader(),
        sha: _sha(server.data),
        onProgress: (d, t) => progress.add((d, t)),
      );

      expect(File(dest).readAsBytesSync(), server.data);
      expect(leftovers(), isEmpty);
      expect(server.requests, hasLength(4));
      expect(server.requests.every((r) => r.status == 206), isTrue);
      // הבדיקה המקדימה היא טווח 1, לא תחילת הקובץ.
      expect(server.requests.first.start, size ~/ 4);
      expect(server.requests.map((r) => r.start).toSet(), {
        0,
        size ~/ 4,
        size ~/ 2,
        3 * size ~/ 4,
      });
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
    },
  );

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
    expect(server.requests.skip(4).map((r) => r.start).toSet(), {
      for (var i = 0; i < 4; i++) i * quarter + quarter ~/ 2,
    });
    expect(client.received, size);
  });

  test(
    'הצירוף מדווח onAssembleProgress לאורך העבודה, והאימות על הקובץ כולו',
    () async {
      server.data = _data(16 << 20);
      final assembled = <(int, int)>[];
      final verified = <(int, int)>[];
      await downloader().downloadToFile(
        url: server.url,
        destPath: dest,
        expectedSize: server.data.length,
        expectedSha256: _sha(server.data),
        resumeToken: 'asset-1',
        onAssembleProgress: (d, t) => assembled.add((d, t)),
        onVerifyProgress: (d, t) => verified.add((d, t)),
      );

      final toCopy = server.data.length - server.data.length ~/ 4;
      expect(assembled.length, greaterThan(2));
      expect(assembled.every((e) => e.$2 == toCopy), isTrue);
      expect(assembled.last, (toCopy, toCopy));
      for (var i = 1; i < assembled.length; i++) {
        expect(assembled[i].$1, greaterThanOrEqualTo(assembled[i - 1].$1));
      }
      expect(verified.last.$1, server.data.length);
      expect(File(dest).readAsBytesSync(), server.data);
    },
  );

  test('נפילה לחיבור יחיד אחרי שטווח 0 כבר כתב: המד אינו יורד', () async {
    server.fullBodyFor = (start) => start >= size ~/ 2;
    final emits = <(int, int?)>[];
    final aggregator = ByteProgressAggregator(
      totalBytes: size,
      onProgress: (d, t) => emits.add((d, t)),
    );
    final slot = aggregator.slot();
    await download(
      downloader(),
      sha: _sha(server.data),
      onProgress: slot.report,
      onExistingBytes: slot.markExisting,
    );

    expect(File(dest).readAsBytesSync(), server.data);
    expect(server.requests.any((r) => r.status == 200), isTrue);
    for (var i = 0; i < emits.length; i++) {
      expect(emits[i].$2, size, reason: '$emits');
      if (i > 0) expect(emits[i].$1, greaterThanOrEqualTo(emits[i - 1].$1));
    }
    expect(emits.last, (size, size));
  });

  test('ניסיון שהביא בתים מאפס את המונה; רק רצף בלי בתים מפיל', () async {
    // טווח של 1MB נקטע אחרי 256KB בכל בקשה: ארבע בקשות עם התקדמות.
    server.cutAfter = (start, end, _) {
      final left = end - start + 1;
      return left > (256 << 10) ? 256 << 10 : null;
    };
    await download(
      downloader(retries: const [Duration(milliseconds: 5)]),
      sha: _sha(server.data),
    );
    expect(File(dest).readAsBytesSync(), server.data);

    File(dest).deleteSync();
    File('$dest.resume').deleteSync();
    await server.settle();
    server.requests.clear();
    // טווח 2 נקטע תמיד לפני הבית הראשון: נכשל אחרי 1+1 ניסיונות.
    server.cutAfter = (start, end, _) => start == size ~/ 2 ? 0 : null;
    await expectLater(
      download(
        downloader(retries: const [Duration(milliseconds: 5)]),
        sha: _sha(server.data),
      ),
      throwsA(isA<PatchNetworkException>()),
    );
    expect(server.requests.where((r) => r.start == size ~/ 2), hasLength(2));
    expect(File('$dest.segments').existsSync(), isTrue);
  });

  test('ETag שהתחלף → If-Range מקבל 200, כל הטווחים מתחילים מאפס', () async {
    server.cutAfter = (start, end, _) => (end - start + 1) ~/ 2;
    await expectLater(
      download(downloader(retries: const [])),
      throwsA(isA<PatchNetworkException>()),
    );
    expect(File('$dest.segments').existsSync(), isTrue);

    server.cutAfter = null;
    server.data = _data(size, 7);
    server.etag = '"v2"';
    await server.settle();
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
    // טווח שעוד לא שלח בקשה כשהראשון נקטע אין לו קובץ — גם טווח 0 (dest).
    final kept = [
      for (var i = 0; i < 4; i++)
        if (File(i == 0 ? dest : '$dest.seg-$i') case final f
            when f.existsSync())
          f.lengthSync()
        else
          0,
    ];
    final keptTotal = kept.fold<int>(0, (a, b) => a + b);
    expect(keptTotal, greaterThan(0));

    server.cutAfter = null;
    await server.settle();
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
  /// של צירוף שנקטע לפני שנרשם (אם נשאר עוד טווח לצרף).
  void writeCompleteSegments(int assembled) {
    final quarter = size ~/ 4;
    final bounds = [0, quarter, 2 * quarter, 3 * quarter, size];
    File(dest).writeAsBytesSync([
      ...server.data.sublist(0, bounds[assembled]),
      if (assembled < 4) ...List.filled(1000, 0xEE),
    ]);
    for (var i = assembled; i < 4; i++) {
      File(
        '$dest.seg-$i',
      ).writeAsBytesSync(server.data.sublist(bounds[i], bounds[i + 1]));
    }
    File('$dest.resume').writeAsStringSync('asset-1\n"v1"');
    File('$dest.segments').writeAsStringSync(
      jsonEncode({
        'v': 1,
        'token': 'asset-1',
        'url': server.url,
        'size': size,
        'sha256': _sha(server.data),
        'etag': '"v1"',
        'bounds': bounds,
        'assembled': assembled,
      }),
    );
  }

  for (final assembled in [1, 2, 3, 4]) {
    test(
      'חידוש checkpoint בצירוף (assembled: $assembled): קובץ תקין, בלי הורדה',
      () async {
        writeCompleteSegments(assembled);
        await download(downloader(), sha: _sha(server.data));

        expect(File(dest).readAsBytesSync(), server.data);
        expect(server.requests, isEmpty);
        expect(leftovers(), isEmpty);
      },
    );
  }

  test('ביטול בהתקדמות הצירוף משאיר מצב שניתן לחידוש בלי הורדה', () async {
    server.data = _data(64 << 20);
    final sha = _sha(server.data);
    var cancel = false;
    final verified = <int>[];
    await expectLater(
      downloader().downloadToFile(
        url: server.url,
        destPath: dest,
        expectedSize: server.data.length,
        expectedSha256: sha,
        resumeToken: 'asset-1',
        onVerifyProgress: (done, total) {
          expect(total, server.data.length);
          verified.add(done);
          cancel = true;
        },
        isCancelled: () => cancel,
      ),
      throwsA(isA<PatchDownloadCancelled>()),
    );
    final state = jsonDecode(File('$dest.segments').readAsStringSync()) as Map;
    expect(verified, isNotEmpty);
    expect(verified.first, inExclusiveRange(0, server.data.length));
    // העובד יכול לסיים לפני דגימת הביטול הבאה. כל checkpoint חוקי חייב
    // לשמור את הקידומת המחויבת ואת כל הטווחים שטרם צורפו, בלי אובדן בתים.
    final assembled = state['assembled'] as int;
    final bounds = (state['bounds'] as List).cast<int>();
    expect(assembled, inInclusiveRange(1, 4));
    final prefix = File(dest).readAsBytesSync();
    expect(prefix.length, greaterThanOrEqualTo(bounds[assembled]));
    expect(
      prefix.sublist(0, bounds[assembled]),
      server.data.sublist(0, bounds[assembled]),
    );
    for (var i = 1; i < 4; i++) {
      final segment = File('$dest.seg-$i');
      if (i < assembled) {
        expect(segment.existsSync(), isFalse);
      } else {
        expect(
          segment.readAsBytesSync(),
          server.data.sublist(bounds[i], bounds[i + 1]),
        );
      }
    }
    expect(File('$dest.resume').readAsStringSync(), 'asset-1\n"v1"');

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
      await expectLater(
        download(downloader(), sha: _sha(server.data)),
        throwsA(isA<PatchDownloadException>()),
      );
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
    await expectLater(
      download(downloader(), sha: _sha(server.data)),
      throwsA(isA<PatchDownloadException>()),
    );
    await first;
    expect(File(dest).readAsBytesSync(), server.data);
    // The zero-byte lock sidecar persists so a subsequent owner cannot hold a
    // different inode from another process that already opened this one.
    expect(File('$dest.lock').existsSync(), isTrue);
    expect(File('$dest.lock').lengthSync(), 0);

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
      isNot(
        anyOf(
          contains('seforim.db.zst.seg-2'),
          contains('seforim.db.zst.segments.tmp'),
        ),
      ),
    );
  });

  test('שאריות הטווחים נמחקות אסינכרונית, קובץ המצב אחרון (#4070)',
      () async {
    for (final name in ['seg-1', 'seg-2', 'segments.tmp', 'segments']) {
      File('$dest.$name').writeAsStringSync('x');
    }
    File(dest).writeAsStringSync('keep');
    File('$dest.resume').writeAsStringSync('keep');
    final io = _AsyncDeletesOnly();
    await IOOverrides.runWithIOOverrides(
        () => PatchDownloader.deleteSegmentFilesAsync(dest), io);

    expect(io.deleted, hasLength(4));
    expect(io.deleted.last, 'seforim.db.zst.segments');
    expect(tmp.listSync().map((f) => p.basename(f.path)),
        unorderedEquals(['seforim.db.zst', 'seforim.db.zst.resume']));
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
    await server.settle();
    server.requests.clear();
    server.mutate = (start, body) {
      if (start == size ~/ 2) body[10] ^= 0xFF;
      return body;
    };
    await expectLater(
      download(downloader(), sha: _sha(server.data)),
      throwsA(isA<PatchDownloadException>()),
    );
    expect(server.requests, hasLength(8));
    expect(File(dest).existsSync(), isFalse);
    expect(leftovers(), isEmpty);
  });

  test('sha256 שגוי פעמיים: dest נמחק אסינכרונית (#4070)', () async {
    server.mutate = (start, body) {
      if (start == size ~/ 2) body[10] ^= 0xFF;
      return body;
    };
    final io = _NoSyncDestDelete(dest);
    await IOOverrides.runWithIOOverrides(
        () => expectLater(download(downloader(), sha: _sha(server.data)),
            throwsA(isA<PatchDownloadException>())),
        io);
    expect(io.syncDeletes, 0);
    expect(File(dest).existsSync(), isFalse);
    expect(leftovers(), isEmpty);
  });

  test('ביטול עוצר את כל הטווחים ושומר את מה שירד', () async {
    server.chunkDelay = const Duration(milliseconds: 20);
    var cancel = false;
    await expectLater(
      download(
        downloader(),
        sha: _sha(server.data),
        onProgress: (d, _) => cancel = cancel || d >= 1 << 20,
        isCancelled: () => cancel,
      ),
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
    await server.settle();
    server.requests.clear();
    await download(downloader(maxConnections: 1), sha: _sha(server.data));
    expect(File(dest).readAsBytesSync(), server.data);
    expect(server.requests.single.range, isNull);
  });

  test(
    'קובצי המצב נכתבים אסינכרונית, ה-ETag נשמר לפני שאר הטווחים (#3780)',
    () async {
      final io = _AsyncStateWritesOnly(() => server.requests.length);
      await IOOverrides.runWithIOOverrides(
        () => download(downloader(), sha: _sha(server.data)),
        io,
      );

      expect(File(dest).readAsBytesSync(), server.data);
      expect(leftovers(), isEmpty);
      final sidecar = [
        for (final w in io.writes)
          if (w.name.endsWith('.resume')) w,
      ];
      // לפני הבדיקה המקדימה בלי ETag; אחריה עם ETag, לפני שאר שלושת הטווחים.
      expect(sidecar[0], (
        name: 'seforim.db.zst.resume',
        content: 'asset-1',
        requests: 0,
      ));
      expect(sidecar[1].content, 'asset-1\n"v1"');
      expect(sidecar[1].requests, 1);
      expect(sidecar.last.content, startsWith('asset-1\n"v1"\n'));
      final state = [
        for (final w in io.writes)
          if (w.name.endsWith('.segments.tmp')) jsonDecode(w.content) as Map,
      ];
      expect(state.first['etag'], isNull);
      expect(state[1]['etag'], '"v1"');
    },
  );

  test('בלי resumeToken: פיצול בתוך הריצה, בלי מצב שנשמר לדיסק', () async {
    server.cutAfter = (start, end, i) => i < 2 ? (end - start + 1) ~/ 2 : null;
    await download(downloader(), sha: _sha(server.data), token: null);
    expect(File(dest).readAsBytesSync(), server.data);
    expect(File('$dest.resume').existsSync(), isFalse);
    expect(leftovers(), isEmpty);
  });

  test('connections מפורש מעל התקרה נחתך ל-maxSegmentConnections', () async {
    await download(downloader(), sha: _sha(server.data), connections: 100);
    expect(File(dest).readAsBytesSync(), server.data);
    expect(server.requests, hasLength(PatchDownloader.maxSegmentConnections));
    expect(leftovers(), isEmpty);
  });

  test('maxConnections בבנאי נחתך לאותה תקרה גם בלי override', () async {
    await download(downloader(maxConnections: 100), sha: _sha(server.data));
    expect(File(dest).readAsBytesSync(), server.data);
    expect(server.requests, hasLength(PatchDownloader.maxSegmentConnections));
    expect(leftovers(), isEmpty);
  });

  test('תוכנית חיה וחיבור אחד: ממשיכה לפי התוכנית, לא נמחקת', () async {
    server.cutAfter = (start, end, _) => (end - start + 1) ~/ 3;
    await expectLater(
      download(downloader(retries: const []), sha: _sha(server.data)),
      throwsA(isA<PatchNetworkException>()),
    );
    final bounds =
        (jsonDecode(File('$dest.segments').readAsStringSync()) as Map)['bounds']
            as List;
    final kept = [
      for (var i = 0; i < 4; i++)
        if (File(i == 0 ? dest : '$dest.seg-$i') case final f
            when f.existsSync())
          f.lengthSync()
        else
          0,
    ];
    final keptTotal = kept.fold<int>(0, (a, b) => a + b);
    expect(keptTotal, greaterThan(0));

    server.cutAfter = null;
    await server.settle();
    server.requests.clear();
    client.received = 0;
    await download(downloader(), sha: _sha(server.data), connections: 1);

    expect(File(dest).readAsBytesSync(), server.data);
    expect(server.requests.map((r) => r.start).toSet(), {
      for (var i = 0; i < 4; i++)
        if (kept[i] < (bounds[i + 1] as int) - (bounds[i] as int))
          (bounds[i] as int) + kept[i],
    });
    expect(client.received, size - keptTotal);
    expect(leftovers(), isEmpty);
  });

  test('תוכנית חיה שלמה וחיבור אחד: מורכבת בלי הורדה', () async {
    writeCompleteSegments(1);
    await download(downloader(), sha: _sha(server.data), connections: 1);
    expect(File(dest).readAsBytesSync(), server.data);
    expect(server.requests, isEmpty);
    expect(leftovers(), isEmpty);
  });
}
