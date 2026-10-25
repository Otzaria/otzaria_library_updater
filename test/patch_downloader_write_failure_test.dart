import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seforim_library_updater/src/services/download_scheduler.dart';
import 'package:seforim_library_updater/src/services/patch_downloader.dart';
import 'package:test/test.dart';

/// כשל הכתיבה של Otzaria_Offline_update#124: הכונן "הוחלף" מתחת לקובץ הפתוח.
FileSystemException _volumeAltered(String path) => FileSystemException(
  'writeFrom failed',
  path,
  const OSError(
    'The volume for a file has been externally altered so that the '
    'opened file is no longer valid',
    1006,
  ),
);

/// כל כתיבה לקובץ [target] נכשלת אסינכרונית, אחרי שהקריאה עצמה כבר חזרה —
/// כמו `writeFrom` אמיתי. [sources] מגישים את תוכן הקבצים שנקראים מהם.
final class _FailingDiskOverrides extends IOOverrides {
  _FailingDiskOverrides(this.target, {this.sources = const {}});

  final String target;
  final Map<String, Stream<List<int>>> sources;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    if (path == target) return _FailingWriteFile(file);
    final source = sources[path];
    if (source != null) return _StreamedSourceFile(file, source);
    return file;
  }
}

class _FailingWriteFile implements File {
  _FailingWriteFile(this._real);

  final File _real;

  @override
  String get path => _real.path;
  @override
  bool existsSync() => _real.existsSync();
  @override
  int lengthSync() => _real.lengthSync();
  @override
  void deleteSync({bool recursive = false}) => _real.deleteSync();

  void _truncateOrCreate(FileMode mode) => _real.writeAsBytesSync(
    const [],
    mode: mode == FileMode.append ? FileMode.append : FileMode.write,
  );

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding? encoding}) {
    _truncateOrCreate(mode);
    return IOSink(_FailingConsumer(path));
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    _truncateOrCreate(mode);
    return _FailingRandomAccessFile(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// כמו `_FileStreamConsumer` של dart:io: עוצר את הזרם, כותב, ונכשל.
class _FailingConsumer implements StreamConsumer<List<int>> {
  _FailingConsumer(this.path);

  final String path;

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    final done = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = stream.listen(
      (_) {
        subscription.pause();
        Timer.run(() {
          subscription.cancel();
          if (!done.isCompleted) done.completeError(_volumeAltered(path));
        });
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    return done.future;
  }

  @override
  Future<void> close() async {}
}

class _FailingRandomAccessFile implements RandomAccessFile {
  _FailingRandomAccessFile(this.path);

  @override
  final String path;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) => Future.delayed(Duration.zero, () => throw _volumeAltered(path));

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StreamedSourceFile implements File {
  _StreamedSourceFile(this._real, this._content);

  final File _real;
  final Stream<List<int>> _content;

  @override
  String get path => _real.path;
  @override
  Future<bool> exists() => _real.exists();
  @override
  Future<int> length() => _real.length();
  @override
  Stream<List<int>> openRead([int? start, int? end]) => _content;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// מריץ את [body] תחת [overrides] ומחזיר את התוצאה יחד עם כל שגיאה שלא טופלה
/// ב-zone. הורדה שנתקעת נכשלת ב-[TimeoutException] ולא ממתינה ל-stall timeout.
Future<({Object? error, List<Object> uncaught})> _runCapturing(
  IOOverrides overrides,
  Future<void> Function() body,
) async {
  final uncaught = <Object>[];
  final outcome = Completer<Object?>();
  runZonedGuarded(
    () => IOOverrides.runWithIOOverrides(body, overrides).then(
      (_) => outcome.complete(null),
      onError: (Object error) => outcome.complete(error),
    ),
    (error, _) => uncaught.add(error),
  );
  final error = await outcome.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => TimeoutException('the download did not finish'),
  );
  return (error: error, uncaught: uncaught);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('write_failure'));
  tearDown(() => tmp.deleteSync(recursive: true));

  final body = Uint8List.fromList(List.generate(1000, (i) => i % 251));
  final bodyHash = sha256.convert(body).toString();

  // המקור מוסר צ'אנק אחד ונשאר פתוח: בלי טיפול מיידי בכשל הכתיבה ההורדה
  // ממתינה לנתון הבא (או ל-stall timeout של שעה).
  ({PatchDownloader downloader, Future<void> cancelled}) openSource() {
    final cancelled = Completer<void>();
    final source = StreamController<List<int>>(
      onCancel: () {
        if (!cancelled.isCompleted) cancelled.complete();
      },
    );
    source.add(Uint8List.sublistView(body, 0, 100));
    final downloader = PatchDownloader(
      networkRetryDelays: const [],
      stallTimeout: const Duration(hours: 1),
      httpClient: MockClient.streaming(
        (request, _) async => http.StreamedResponse(
          source.stream,
          200,
          contentLength: body.length,
          headers: {'etag': '"e1"'},
        ),
      ),
      decompress: (_) async => null,
    );
    return (downloader: downloader, cancelled: cancelled.future);
  }

  test('כשל כתיבה אסינכרוני כשהמקור ממתין לנתונים: ההורדה נכשלת מיד, '
      'בלי שגיאה ב-zone, והרשת נעצרת', () async {
    final dest = '${tmp.path}${Platform.pathSeparator}model.onnx';
    final source = openSource();

    final result = await _runCapturing(
      _FailingDiskOverrides(dest),
      () => source.downloader.downloadToFile(
        url: 'https://x/model.onnx',
        destPath: dest,
        expectedSize: body.length,
        expectedSha256: bodyHash,
        resumeToken: bodyHash,
      ),
    );

    expect(result.uncaught, isEmpty);
    expect(
      result.error,
      isA<PatchDownloadException>().having(
        (e) => e.message,
        'message',
        contains('1006'),
      ),
    );
    await source.cancelled.timeout(const Duration(seconds: 1));
    // תוכן אחרי כשל כתיבה אינו ודאי: לא נשאר חלקי ולא קובץ צד שימשיך ממנו.
    expect(File(dest).existsSync(), isFalse);
    expect(File(PatchDownloader.resumeSidecarPath(dest)).existsSync(), isFalse);
  });

  test(
    'כשל כתיבה בהעתקה מקומית כשהמקור ממתין: נכשלת מיד ומוחקת את היעד',
    () async {
      final from = '${tmp.path}${Platform.pathSeparator}mirror.onnx';
      final dest = '${tmp.path}${Platform.pathSeparator}model.onnx';
      File(from).writeAsBytesSync(body);
      final content = StreamController<List<int>>()
        ..add(Uint8List.sublistView(body, 0, 100));

      final result = await _runCapturing(
        _FailingDiskOverrides(dest, sources: {from: content.stream}),
        () => openSource().downloader.downloadToFile(
          url: from,
          destPath: dest,
          expectedSize: body.length,
        ),
      );

      expect(result.uncaught, isEmpty);
      expect(
        result.error,
        isA<FileSystemException>().having(
          (e) => e.osError?.errorCode,
          'errno',
          1006,
        ),
      );
      expect(content.hasListener, isFalse);
      expect(File(dest).existsSync(), isFalse);
    },
  );

  test(
    'DownloadScheduler: כשל כתיבה ממתין להורדה שכבר רצה לפני שהוא זורק',
    () async {
      final dest = '${tmp.path}${Platform.pathSeparator}model.onnx';
      final source = openSource();
      final slow = Completer<void>();
      var slowFinished = false;

      final run = _runCapturing(
        _FailingDiskOverrides(dest),
        () => DownloadScheduler(maxConcurrent: 2).run<void>([
          () => source.downloader.downloadToFile(
            url: 'https://x/model.onnx',
            destPath: dest,
            expectedSize: body.length,
            resumeToken: bodyHash,
          ),
          () async {
            await slow.future;
            slowFinished = true;
          },
        ]),
      );

      await source.cancelled.timeout(const Duration(seconds: 1));
      await pumpEventQueue();
      expect(slowFinished, isFalse);
      slow.complete();

      final result = await run;
      expect(slowFinished, isTrue);
      expect(result.uncaught, isEmpty);
      expect(result.error, isA<PatchDownloadException>());
    },
  );

  test(
    'כשל כתיבה בטווח של הורדה מפוצלת כשהמקור ממתין: נכשלת מיד ועוצרת אותו',
    () async {
      final dest = '${tmp.path}${Platform.pathSeparator}model.onnx';
      final cancelled = Completer<void>();
      final downloader = PatchDownloader(
        networkRetryDelays: const [],
        stallTimeout: const Duration(hours: 1),
        maxConnections: 2,
        segmentThresholdBytes: 100,
        httpClient: MockClient.streaming((request, _) async {
          final range = RegExp(
            r'bytes=(\d+)-(\d+)',
          ).firstMatch(request.headers['Range']!)!;
          final start = int.parse(range.group(1)!);
          final end = int.parse(range.group(2)!);
          final segment = Uint8List.sublistView(body, start, end + 1);
          // טווח 0 מגיע שלם; טווח 1 שולח צ'אנק אחד ונשאר פתוח.
          final stream = start == 0
              ? Stream<List<int>>.value(segment)
              : (StreamController<List<int>>(
                  onCancel: () {
                    if (!cancelled.isCompleted) cancelled.complete();
                  },
                )..add(Uint8List.sublistView(segment, 0, 100))).stream;
          return http.StreamedResponse(
            stream,
            206,
            contentLength: segment.length,
            headers: {
              'etag': '"e1"',
              'content-range': 'bytes $start-$end/${body.length}',
            },
          );
        }),
        decompress: (_) async => null,
      );

      final result = await _runCapturing(
        _FailingDiskOverrides('$dest.seg-1'),
        () => downloader.downloadToFile(
          url: 'https://x/model.onnx',
          destPath: dest,
          expectedSize: body.length,
          expectedSha256: bodyHash,
          resumeToken: bodyHash,
        ),
      );

      expect(result.uncaught, isEmpty);
      expect(
        result.error,
        isA<FileSystemException>().having(
          (e) => e.osError?.errorCode,
          'errno',
          1006,
        ),
      );
      await cancelled.future.timeout(const Duration(seconds: 1));
    },
  );
}
