import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:test/test.dart';

import 'support/destination_lock_worker.dart';

/// Requests stay open until explicitly released, so lock contention is proven
/// without racing a download against a timer.
class _BlockedServer {
  final requests = <HttpRequest>[];
  final _requestSignals = StreamController<int>.broadcast(sync: true);
  final _release = Completer<void>();
  late final HttpServer server;
  int get count => requests.length;
  String get url => 'http://127.0.0.1:${server.port}/file';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request);
      _requestSignals.add(count);
      await _release.future;
      try {
        request.response.contentLength = 8;
        request.response.add(List.filled(8, 65));
        await request.response.close();
      } catch (_) {
        // The crash-recovery test intentionally kills a connected worker.
      }
    });
  }

  Future<void> waitFor(int n) => count >= n
      ? Future.value()
      : _requestSignals.stream.firstWhere((i) => i >= n);

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  Future<void> close() async {
    release();
    await server.close(force: true);
    await _requestSignals.close();
  }
}

Future<String> _isolatedDownload(String url, String dest) async {
  final port = ReceivePort();
  try {
    await Isolate.spawn(downloadInIsolate, [port.sendPort, url, dest]);
    return await port.first as String;
  } finally {
    port.close();
  }
}

class _Worker {
  _Worker(this.process, this.result);
  final Process process;
  final Future<String> result;
}

Future<_Worker> _processDownload(String url, String dest) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    'test/support/destination_lock_worker.dart',
    url,
    dest,
  ]);
  final errors = process.stderr.transform(utf8.decoder).join();
  final output = process.stdout.transform(utf8.decoder).join();
  return _Worker(process, () async {
    final code = await process.exitCode;
    final stderr = await errors;
    if (code != 0) throw StateError('worker exited $code: $stderr');
    return (await output).trim().split('\n').last;
  }());
}

void main() {
  late Directory dir;
  late _BlockedServer server;
  late String dest;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('download-lock-test');
    dest = '${dir.path}/asset';
    server = _BlockedServer();
    await server.start();
  });

  tearDown(() async {
    await server.close();
    dir.deleteSync(recursive: true);
  });

  test('separate isolates exclude contenders and preserve the owner lock',
      () async {
    final first = _isolatedDownload(server.url, dest);
    await server.waitFor(1);
    // This also accepts the zero-byte sidecar left by the old implementation.
    expect(File('$dest.lock').lengthSync(), 0);
    final second = _isolatedDownload(server.url, dest);
    final outcome = await Future.any([
      second,
      server.waitFor(2).then((_) => 'second HTTP request'),
    ]);
    server.release();
    expect(await first, 'success');
    expect(await second, 'locked');
    expect(outcome, 'locked');
    expect(server.count, 1);
    expect(File(dest).readAsBytesSync(), List.filled(8, 65));
    expect(File('$dest.lock').existsSync(), isTrue);
  });

  test('failed contenders do not release another isolate lock', () async {
    final first = _isolatedDownload(server.url, dest);
    await server.waitFor(1);
    final results = <String>[];
    for (var i = 0; i < 3; i++) {
      final next = _isolatedDownload(server.url, dest);
      results.add(await Future.any([
        next,
        server.waitFor(2).then((_) => 'contender HTTP request'),
      ]));
      if (results.last != 'locked') break;
    }
    server.release();
    expect(await first, 'success');
    expect(results, ['locked', 'locked', 'locked']);
    expect(server.count, 1);
    // A new owner can acquire the same persistent inode after release.
    expect(await _isolatedDownload(server.url, dest), 'success');
    expect(File('$dest.lock').lengthSync(), 0);
  });

  test('separate processes exclude contenders and release after success',
      () async {
    final first = await _processDownload(server.url, dest);
    await server.waitFor(1);
    final second = await _processDownload(server.url, dest);
    final outcome = await Future.any([
      second.result,
      server.waitFor(2).then((_) => 'second HTTP request'),
    ]);
    server.release();
    expect(await first.result, 'success');
    expect(await second.result, 'locked');
    expect(outcome, 'locked');
    expect(server.count, 1);
    expect(await (await _processDownload(server.url, dest)).result, 'success');
    expect(File('$dest.lock').existsSync(), isTrue);
  });

  test('an abruptly terminated owner leaves no stale lock', () async {
    final first = await _processDownload(server.url, dest);
    // Do not await its success-result wrapper: this worker is killed on purpose.
    unawaited(first.result.then<void>((_) {}, onError: (Object _) {}));
    await server.waitFor(1);
    first.process.kill(ProcessSignal.sigkill);
    await first.process.exitCode;
    server.release();
    expect(await (await _processDownload(server.url, dest)).result, 'success');
    expect(File(dest).readAsBytesSync(), List.filled(8, 65));
  }, testOn: '!windows');

  test('a failed download closes the lock connection before retry', () async {
    final downloader = PatchDownloader(
      decompress: (_) async => null,
      networkRetryDelays: const [],
      connectTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(downloader.dispose);
    // An invalid URL fails after acquiring the lock and before HTTP.
    await expectLater(
      downloader.downloadToFile(url: 'http://[invalid', destPath: dest),
      throwsA(isA<FormatException>()),
    );
    server.release();
    expect(await _isolatedDownload(server.url, dest), 'success');
  });
}
