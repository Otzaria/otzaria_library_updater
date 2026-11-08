import 'dart:convert';
import 'dart:io';

import 'package:http/testing.dart';
import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:seforim_library_updater/src/hashing/fast_sha256.dart';

// Independent QA probe. Fixtures and their hashes are prepared and
// checked by a separate Python process; no archive-sized buffer is used here.
Future<void> main(List<String> args) async {
  if (args.length != 2 || !{'cancel', 'retry'}.contains(args[0])) {
    throw ArgumentError('usage: join-probe cancel|retry manifest.json');
  }
  final mode = args[0];
  final data =
      jsonDecode(await File(args[1]).readAsString()) as Map<String, dynamic>;
  if (data['source_sha256'] is! String) {
    throw ArgumentError(
      'Prepare fixtures with split_assembly_probe_fixture.py',
    );
  }
  final destination = data['destination'] as String;
  final fixtureParts = (data['parts'] as List).cast<Map<String, dynamic>>();
  final split = SplitAsset(
    archive: data['archive'] as String,
    size: data['size'] as int,
    sha256: data['sha256'] as String,
    manifestName: 'probe.manifest.json',
    parts: [
      for (var i = 0; i < fixtureParts.length; i++)
        SplitAssetPart(
          name: fixtureParts[i]['name'] as String,
          size: fixtureParts[i]['size'] as int,
          sha256: fixtureParts[i]['sha256'] as String,
          downloadUrl: 'https://example.invalid/part-$i',
        ),
    ],
  );
  if (await File(destination).exists()) {
    throw StateError('probe requires an unpublished destination');
  }

  var requests = 0;
  final downloader = PatchDownloader(
    decompress: (bytes) async => bytes,
    networkRetryDelays: const [],
    httpClient: MockClient((request) async {
      requests++;
      throw StateError('unexpected HTTP request: ${request.url}');
    }),
  );
  final baselineRss = ProcessInfo.currentRss;
  final clock = Stopwatch()..start();
  var cancelled = false;
  var caughtCancellation = false;
  int? cancelAtUs;
  int? cancelledAtBytes;
  var assemblyCallbacks = 0;
  var progressAfterPublication = 0;
  var cancellationChecksAfterPublication = 0;
  Object? failure;
  try {
    await downloader.downloadSplitToFile(
      split: split,
      destPath: destination,
      resumeToken: data['token'] as String,
      onAssembleProgress: (done, total) {
        assemblyCallbacks++;
        if (File(destination).existsSync()) progressAfterPublication++;
        if (mode == 'cancel' && !cancelled && done > 0) {
          cancelled = true;
          cancelAtUs = clock.elapsedMicroseconds;
          cancelledAtBytes = done;
        }
      },
      isCancelled: () {
        if (File(destination).existsSync()) {
          cancellationChecksAfterPublication++;
        }
        return cancelled;
      },
    );
  } on PatchDownloadCancelled {
    caughtCancellation = true;
  } catch (error) {
    failure = error;
  }
  clock.stop();
  final completedAtUs = clock.elapsedMicroseconds;
  final peakRss = ProcessInfo.maxRss;
  final completionRss = ProcessInfo.currentRss;
  final callbacksAtCompletion = assemblyCallbacks;
  await Future<void>.delayed(const Duration(milliseconds: 20));
  downloader.dispose();

  final destinationExists = await File(destination).exists();
  final joiningExists = await File('$destination.joining').exists();
  var partCount = 0;
  var partSidecarCount = 0;
  var retainedPartBytes = 0;
  for (var i = 0; i < fixtureParts.length; i++) {
    final part = File(PatchDownloader.splitPartPath(destination, i));
    if (await part.exists()) {
      partCount++;
      retainedPartBytes += await part.length();
    }
    if (await File('${part.path}.resume').exists()) partSidecarCount++;
  }

  final passed =
      failure == null &&
      requests == 0 &&
      !joiningExists &&
      assemblyCallbacks == callbacksAtCompletion &&
      progressAfterPublication == 0 &&
      cancellationChecksAfterPublication == 0 &&
      (mode == 'cancel'
          ? caughtCancellation &&
                !destinationExists &&
                cancelledAtBytes == (4 << 20) &&
                partCount == split.parts.length &&
                partSidecarCount == split.parts.length &&
                retainedPartBytes == split.size
          : !caughtCancellation &&
                destinationExists &&
                partCount == 0 &&
                partSidecarCount == 0 &&
                await File(destination).length() == split.size);
  stdout.writeln(
    jsonEncode({
      'mode': mode,
      'passed': passed,
      'source_sha256': data['source_sha256'],
      'dart': Platform.version,
      'os': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'native_sha256': FastSha256.isNativeAvailable,
      'archive_bytes': split.size,
      'parts': split.parts.length,
      'first_cancel_progress_bytes': cancelledAtBytes,
      'cancel_latency_us': cancelAtUs == null
          ? null
          : completedAtUs - cancelAtUs!,
      'operation_us': completedAtUs,
      'baseline_rss_bytes': baselineRss,
      'peak_rss_bytes': peakRss,
      'completion_rss_bytes': completionRss,
      'http_requests': requests,
      'assembly_callbacks': assemblyCallbacks,
      'callbacks_after_completion': assemblyCallbacks - callbacksAtCompletion,
      'progress_after_publication': progressAfterPublication,
      'cancellation_checks_after_publication':
          cancellationChecksAfterPublication,
      'caught_cancellation': caughtCancellation,
      'destination_exists': destinationExists,
      'joining_exists': joiningExists,
      'retained_parts': partCount,
      'retained_sidecars': partSidecarCount,
      'retained_bytes': retainedPartBytes,
      if (failure != null) 'error': failure.toString(),
    }),
  );
  if (!passed) exitCode = 1;
}
