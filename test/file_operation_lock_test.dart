import 'dart:async';
import 'dart:io';

import 'package:seforim_library_updater/seforim_library_updater.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('operation_lock_'));
  tearDown(() => root.delete(recursive: true));

  test(
    'lock stays held through awaited cleanup and releases on failure',
    () async {
      final destination = '${root.path}/live.db';
      final started = Completer<void>();
      final finishCleanup = Completer<void>();
      var cleaned = false;
      final first = withFileOperationLock<void>(destination, () async {
        try {
          throw StateError('failed before installation');
        } finally {
          started.complete();
          await finishCleanup.future;
          cleaned = true;
        }
      });
      final expectedFailure = expectLater(first, throwsStateError);
      await started.future;
      expect(await File('$destination.lock').exists(), isTrue);
      await expectLater(
        withFileOperationLock(
          destination,
          () async => fail('lock was released early'),
        ),
        throwsA(isA<PatchDownloadException>()),
      );
      expect(cleaned, isFalse);
      finishCleanup.complete();
      await expectedFailure;
      expect(cleaned, isTrue);
      expect(await withFileOperationLock(destination, () async => 42), 42);
      expect(await File('$destination.lock').exists(), isTrue);
    },
  );

  test(
    'different destinations can run concurrently; the same key is not reentrant',
    () async {
      final a = '${root.path}/a';
      final b = '${root.path}/b';
      await withFileOperationLock(a, () async {
        expect(
          await withFileOperationLock(b, () async => 'independent'),
          'independent',
        );
        await expectLater(
          withFileOperationLock(a, () async => fail('nested lock must fail')),
          throwsA(isA<PatchDownloadException>()),
        );
      });
      expect(
        await withFileOperationLock(a, () async => 'released'),
        'released',
      );
    },
  );
}
