import 'dart:io';
import 'dart:isolate';

import 'package:seforim_library_updater/seforim_library_updater.dart';

Future<String> downloadForLockTest(String url, String dest) async {
  final downloader = PatchDownloader(
    decompress: (_) async => null,
    maxConnections: 1,
    networkRetryDelays: const [],
  );
  try {
    await downloader.downloadToFile(
      url: url,
      destPath: dest,
      expectedSize: 8,
      resumeToken: 'same-asset',
    );
    return 'success';
  } catch (error) {
    return error is PatchDownloadException ? 'locked' : '$error';
  } finally {
    downloader.dispose();
  }
}

Future<void> downloadInIsolate(List<Object> args) async {
  (args[0] as SendPort).send(
    await downloadForLockTest(args[1] as String, args[2] as String),
  );
}

Future<void> main(List<String> args) async {
  stdout.writeln(await downloadForLockTest(args[0], args[1]));
}
