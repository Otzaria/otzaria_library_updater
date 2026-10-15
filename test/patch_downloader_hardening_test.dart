import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:seforim_library_updater/src/models/delta_manifest.dart';
import 'package:seforim_library_updater/src/services/download_scheduler.dart';
import 'package:seforim_library_updater/src/services/patch_downloader.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('downloader_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  // "patch" מדומה: compressed=הבייטים שמוגשים; decompress=זהות (מחזיר אותם).
  final uncompressed = Uint8List.fromList(List.generate(64, (i) => i));
  final compressed = Uint8List.fromList(List.generate(32, (i) => 255 - i));

  // שתי השורות הראשונות של קובץ הצד (טוקן + ETag), בלי שורת סימון האימות —
  // שהיא זמן-תלויה ונבדקת בנפרד בקבוצה שלה.
  String sidecarIdentity(String dest) => File('$dest.resume')
      .readAsStringSync()
      .split('\n')
      .take(2)
      .where((line) => line.isNotEmpty)
      .join('\n');

  PatchFileEntry entry({String? badCompressedHash, int? badSize}) =>
      PatchFileEntry(
        file: 'patch-v1-v2.db.zst',
        compression: 'zstd',
        sha256: badCompressedHash ?? sha256.convert(compressed).toString(),
        size: badSize ?? compressed.length,
        uncompressedSha256: sha256.convert(uncompressed).toString(),
        uncompressedSize: uncompressed.length,
      );

  test('sha256 מחולץ שגוי → נכשל', () async {
    // decompress מחזיר בייטים שלא תואמים ל-uncompressedSha256
    final mock = MockClient.streaming((request, bodyStream) async =>
        http.StreamedResponse(Stream.value(compressed), 200,
            contentLength: compressed.length));
    final downloader = PatchDownloader(
      networkRetryDelays: const [],
      httpClient: mock,
      decompress: (c) async => Uint8List.fromList([9, 9, 9]),
    );
    expect(
      () => downloader.downloadAndExtract(
        patchFile: entry(),
        downloadUrl: 'https://x/p',
        destDir: tmp,
      ),
      throwsA(isA<PatchDownloadException>()),
    );
  });

  for (final name in ['../seforim.db.zst', '..zst', '...zst']) {
    test('שם patch שיוצא מתיקיית היעד נדחה בלי לגעת בקובץ שמחוץ לה: $name',
        () async {
      final live = File('${tmp.path}/seforim.db')..writeAsStringSync('LIVE');
      var requests = 0;
      final downloader = PatchDownloader(
        networkRetryDelays: const [],
        httpClient: MockClient.streaming((request, bodyStream) async {
          requests++;
          return http.StreamedResponse(Stream.value(compressed), 200,
              contentLength: compressed.length);
        }),
        decompress: (c) async => uncompressed,
      );

      await expectLater(
        downloader.downloadAndExtract(
          patchFile: PatchFileEntry(
            file: name,
            compression: 'zstd',
            sha256: 'deadbeef',
            size: compressed.length,
            uncompressedSha256: sha256.convert(uncompressed).toString(),
            uncompressedSize: uncompressed.length,
          ),
          downloadUrl: 'https://x/p',
          destDir: Directory('${tmp.path}/.seforim-update-tmp'),
        ),
        throwsA(isA<PatchDownloadException>()),
      );
      expect(requests, 0);
      expect(live.readAsStringSync(), 'LIVE');
      expect(Directory(tmp.path).existsSync(), isTrue);
    });
  }

  test('בקשה שחרגה מזמן ההתחברות מבוטלת, ותגובה מאוחרת ננטשת', () async {
    final pending = Completer<http.StreamedResponse>();
    final aborted = Completer<void>();
    var lateBodyCancelled = false;
    final downloader = PatchDownloader(
      networkRetryDelays: const [],
      httpClient: MockClient.streaming((request, bodyStream) {
        unawaited((request as http.AbortableRequest)
            .abortTrigger!
            .then((_) => aborted.complete()));
        return pending.future;
      }),
      decompress: (c) async => uncompressed,
      connectTimeout: const Duration(milliseconds: 20),
    );

    await expectLater(
      downloader.downloadAndExtract(
        patchFile: entry(),
        downloadUrl: 'https://x/patch-v1-v2.db.zst',
        destDir: tmp,
      ),
      throwsA(isA<PatchNetworkException>()
          .having((e) => e.cause, 'cause', isA<TimeoutException>())),
    );
    await aborted.future.timeout(const Duration(seconds: 5));

    final late = StreamController<List<int>>(
      onCancel: () => lateBodyCancelled = true,
    );
    pending.complete(http.StreamedResponse(late.stream, 200));
    await pumpEventQueue();
    expect(lateBodyCancelled, isTrue);
  });

  group('downloadToFile (DB מלא)', () {
    // downloadToFile אינו מחלץ, אך ה-constructor דורש decompress (חובה כעת).
    PatchDownloader fullDownloader() => PatchDownloader(
          networkRetryDelays: const [],
          httpClient: MockClient.streaming((request, bodyStream) async =>
              http.StreamedResponse(Stream.value(compressed), 200,
                  contentLength: compressed.length)),
          decompress: (c) async => uncompressed,
        );

    // הכתיבה לדיסק נעצרת לצורך flush כל כמה מגה־בייטים (לחץ-נגד מול כונן
    // איטי). הבדיקה מוודאת שהחצייה של הגבול הזה אינה מאבדת או מערבבת בייטים.
    test('גוף שחוצה את גבול ה-flush נכתב שלם ובסדר הנכון', () async {
      final dest = '${tmp.path}/seforim.db.zst';
      // 12MB בצ׳אנקים של 1MB — שלוש חציות של גבול ה-4MB.
      const chunkSize = 1 << 20;
      const chunkCount = 12;
      final body = Uint8List(chunkSize * chunkCount);
      for (var i = 0; i < body.length; i++) {
        body[i] = i % 251;
      }
      final chunks = [
        for (var i = 0; i < chunkCount; i++)
          Uint8List.sublistView(body, i * chunkSize, (i + 1) * chunkSize),
      ];

      final downloader = PatchDownloader(
        networkRetryDelays: const [],
        httpClient: MockClient.streaming(
          (request, bodyStream) async => http.StreamedResponse(
            Stream.fromIterable(chunks),
            200,
            contentLength: body.length,
          ),
        ),
        decompress: (c) async => uncompressed,
      );

      await downloader.downloadToFile(
        url: 'https://x/seforim.db.zst',
        destPath: dest,
        expectedSize: body.length,
        expectedSha256: sha256.convert(body).toString(),
      );
      expect(File(dest).lengthSync(), body.length);
      expect(File(dest).readAsBytesSync(), body);
    });

    // קובץ שכבר יושב שלם על הדיסק מדלג על ההורדה ורק מאומת. האימות של 1.1GB
    // נמשך דקה, ובלי דיווח הוא נראה למשתמש כמו תקיעה.
    test('נכס שכבר שלם: האימות מדווח התקדמות ולא רק קופץ ל-100%', () async {
      final dest = '${tmp.path}/seforim.db.zst';
      File(dest).writeAsBytesSync(compressed);
      File('$dest.resume').writeAsStringSync('v-1\n"e1"');

      final verifyReports = <(int, int)>[];
      await fullDownloader().downloadToFile(
        url: 'https://x/seforim.db.zst',
        destPath: dest,
        expectedSize: compressed.length,
        expectedSha256: sha256.convert(compressed).toString(),
        resumeToken: 'v-1',
        onVerifyProgress: (verified, total) =>
            verifyReports.add((verified, total)),
      );

      expect(verifyReports, isNotEmpty);
      expect(verifyReports.last, (compressed.length, compressed.length));
    });

    // onProgress מדווח פר-צ'אנק (עשרות אלפי קריאות ב-1GB) — זה החוזה שבגללו
    // הצרכן חייב לקהות אותו דרך ProgressNotifier ולא לקרוא ל-setState ישירות.
    test('onProgress נקרא פעם אחת לכל צ׳אנק, מצטבר, עם total קבוע', () async {
      final chunks = [
        Uint8List.fromList(List.filled(10, 1)),
        Uint8List.fromList(List.filled(20, 2)),
        Uint8List.fromList(List.filled(5, 3)),
      ];
      final total = chunks.fold<int>(0, (n, c) => n + c.length);
      final downloader = PatchDownloader(
        networkRetryDelays: const [],
        httpClient: MockClient.streaming((request, _) async =>
            http.StreamedResponse(Stream.fromIterable(chunks), 200,
                contentLength: total)),
        decompress: (c) async => uncompressed,
      );

      final reports = <(int, int?)>[];
      await downloader.downloadToFile(
        url: 'https://x/seforim.db.zst',
        destPath: '${tmp.path}/seforim.db.zst',
        expectedSize: total,
        onProgress: (downloaded, t) => reports.add((downloaded, t)),
      );

      expect(reports, [(10, total), (30, total), (35, total)]);
    });
  });

  group('downloadToFile — חידוש הורדה (resume)', () {
    // קובץ מלא = 40 בייטים; מחולק ל-15 ראשונים (partial) + 25 המשך.
    final full = Uint8List.fromList(List.generate(40, (i) => i));
    final fullHash = sha256.convert(full).toString();

    PatchDownloader downloaderThatCaptures(
      List<http.BaseRequest> captured, {
      required Future<http.StreamedResponse> Function(http.BaseRequest req)
          handler,
    }) {
      final mock = MockClient.streaming((request, bodyStream) async {
        captured.add(request);
        return handler(request);
      });
      return PatchDownloader(
        networkRetryDelays: const [],
        httpClient: mock,
        decompress: (c) async => full,
      );
    }

    // finding P1: 416 עם Content-Range תואם ל-offset (בלי expectedSize) — הקובץ
    // אכן שלם בצד השרת, נשמר לאימות.

    // finding P1: 416 עם total קטן מה-offset (חלקי מקומי גדול מהנכס המרוחק) —
    // אינו הוכחת שלמות; מוחקים ומורידים מחדש מאפס.

    // finding P1: 416 בלי Content-Range אינו הוכחת שלמות → GET מלא מאפס.

    group('קובץ שלם על הכונן שאינו הנכס', () {
      Future<(List<http.BaseRequest>, int)> runPreCredited(
        String dest, {
        required String? resumeToken,
        List<int>? served,
      }) async {
        final captured = <http.BaseRequest>[];
        var lastReceived = -1;
        final bytes = ByteProgressAggregator(
          totalBytes: full.length,
          onProgress: (received, _) => lastReceived = received,
        );
        final slot = bytes.slot(existingBytes: full.length);
        await downloaderThatCaptures(
          captured,
          handler: (req) async => http.StreamedResponse(
            Stream.value(served ?? full),
            200,
            contentLength: (served ?? full).length,
          ),
        ).downloadToFile(
          url: 'https://x/seforim.db.zst',
          destPath: dest,
          expectedSize: full.length,
          expectedSha256: fullHash,
          resumeToken: resumeToken,
          onProgress: slot.report,
          onExistingBytes: slot.markExisting,
        );
        return (captured, lastReceived);
      }

      test('נמחק בכניסה (טוקן אחר, תוכן אחר) → ההורדה המלאה נספרת במד',
          () async {
        final dest = '${tmp.path}/seforim.db.zst';
        File(dest).writeAsBytesSync(List.filled(full.length, 7));
        File('$dest.resume').writeAsStringSync('v-old');
        final (captured, received) =
            await runPreCredited(dest, resumeToken: 'v-new');
        expect(captured, hasLength(1));
        expect(received, full.length);
        expect(File(dest).readAsBytesSync(), full);
      });

      test('נמחק בכניסה (בלי טוקן) → ההורדה המלאה נספרת במד', () async {
        final dest = '${tmp.path}/seforim.db.zst';
        File(dest).writeAsBytesSync(full);
        final (captured, received) =
            await runPreCredited(dest, resumeToken: null);
        expect(captured, hasLength(1));
        expect(received, full.length);
      });

      test('אותו טוקן, תוכן פגום → יורד מחדש מאפס ולא נכשל', () async {
        final dest = '${tmp.path}/seforim.db.zst';
        File(dest).writeAsBytesSync(List.filled(full.length, 7));
        File('$dest.resume').writeAsStringSync('v-1\n"e1"');
        final (captured, received) =
            await runPreCredited(dest, resumeToken: 'v-1');
        expect(captured, hasLength(1));
        expect(captured.single.headers.containsKey('Range'), isFalse);
        expect(received, full.length);
        expect(File(dest).readAsBytesSync(), full);
        expect(sidecarIdentity(dest), 'v-1');
      });

      test('אותו טוקן, קובץ גדול מהצפוי → יורד מחדש מאפס ולא נכשל', () async {
        final dest = '${tmp.path}/seforim.db.zst';
        File(dest).writeAsBytesSync([...full, 1]);
        File('$dest.resume').writeAsStringSync('v-1\n"e1"');
        final (captured, received) =
            await runPreCredited(dest, resumeToken: 'v-1');
        expect(captured, hasLength(1));
        expect(received, full.length);
        expect(File(dest).readAsBytesSync(), full);
      });

      test('אותו טוקן, תוכן פגום וגם ההורדה החדשה פגומה → נזרק והקובץ נמחק',
          () async {
        final dest = '${tmp.path}/seforim.db.zst';
        File(dest).writeAsBytesSync(List.filled(full.length, 7));
        File('$dest.resume').writeAsStringSync('v-1\n"e1"');
        await expectLater(
          runPreCredited(
            dest,
            resumeToken: 'v-1',
            served: List.filled(full.length, 9),
          ),
          throwsA(isA<PatchDownloadException>()),
        );
        expect(File(dest).existsSync(), isFalse);
        expect(File('$dest.resume').existsSync(), isFalse);
      });

      test('קובץ שאי אפשר לסנכרן לדיסק אינו מקבל סימון אימות', () async {
        final dest = '${tmp.path}/seforim.db.zst';
        File(dest).writeAsBytesSync(full);
        File('$dest.resume').writeAsStringSync('v-1\n"e1"');
        Process.runSync('chmod', ['444', dest]);
        addTearDown(() => Process.runSync('chmod', ['644', dest]));
        final reports = <(int, int)>[];
        await downloaderThatCaptures(
          [],
          handler: (req) async =>
              http.StreamedResponse(const Stream.empty(), 416),
        ).downloadToFile(
          url: 'https://x/seforim.db.zst',
          destPath: dest,
          expectedSize: full.length,
          expectedSha256: fullHash,
          resumeToken: 'v-1',
          onVerifyProgress: (v, t) => reports.add((v, t)),
        );
        expect(reports, isNotEmpty);
        expect(File('$dest.resume').readAsStringSync(), 'v-1\n"e1"');
      }, skip: Platform.isWindows);
    });

    // P2: 206 עם Content-Range שלא מתחיל ב-offset → בקשה שנייה בלי Range מאפס.

    // P1: כבילת החלקי ל-resumeToken דרך קובץ הצד <destPath>.resume.
    group('resumeToken (כבילת גרסה)', () {
      // סימון האימות: מה שמונע קריאה חוזרת של ~1.5GB מכונן נייד בכל לחיצה על
      // "הורדה", על נכס שלם שלא נגעו בו מאז שאומת.
      group('סימון אימות בקובץ הצד', () {
        String markFor(String dest, String digest) {
          final stat = File(dest).statSync();
          return '$digest|${stat.size}|${stat.modified.microsecondsSinceEpoch}';
        }

        /// מוריד נכס שלם עם קובץ הצד ש-[sidecar] בונה **אחרי** כתיבת הקובץ
        /// (סימון תלוי בזמן-השינוי שלו), ומחזיר את דיווחי האימות: רשימה ריקה
        /// = ה-hash כלל לא חושב, כלומר הסימון חסך את הקריאה.
        Future<List<(int, int)>> runComplete(
            String dest, String Function(String dest) sidecar) async {
          File(dest).writeAsBytesSync(full);
          File('$dest.resume').writeAsStringSync(sidecar(dest));
          final reports = <(int, int)>[];
          await downloaderThatCaptures(
            [],
            handler: (req) async =>
                http.StreamedResponse(const Stream.empty(), 416),
          ).downloadToFile(
            url: 'https://x/seforim.db.zst',
            destPath: dest,
            expectedSize: full.length,
            expectedSha256: fullHash,
            resumeToken: 'v-1',
            onVerifyProgress: (verified, total) =>
                reports.add((verified, total)),
          );
          return reports;
        }

        test('סימון תואם → מדלגים על קריאת הקובץ כולו', () async {
          final dest = '${tmp.path}/seforim.db.zst';
          final reports = await runComplete(
              dest, (d) => 'v-1\n"e1"\n${markFor(d, fullHash)}');
          expect(reports, isEmpty);
          expect(File(dest).readAsBytesSync(), full);
        });

        test('סימון של digest אחר → אימות מלא', () async {
          final dest = '${tmp.path}/seforim.db.zst';
          final reports = await runComplete(
              dest, (d) => 'v-1\n"e1"\n${markFor(d, 'deadbeef')}');
          expect(reports, isNotEmpty);
        });

        test('הקובץ שונה מאז הסימון → אימות מלא', () async {
          final dest = '${tmp.path}/seforim.db.zst';
          // אותו digest ואותו גודל, זמן-שינוי אחר — בדיוק המצב של קובץ שנכתב
          // מחדש (העתקה גרועה, resume שנקטע) אחרי שאומת.
          final reports = await runComplete(dest, (d) {
            final stat = File(d).statSync();
            final stale = stat.modified.subtract(const Duration(days: 1));
            return 'v-1\n"e1"\n'
                '$fullHash|${stat.size}|${stale.microsecondsSinceEpoch}';
          });
          expect(reports, isNotEmpty);
        });

        test('קובץ צד דו-שורות (מריצה לפני הסימון) → אימות מלא', () async {
          final dest = '${tmp.path}/seforim.db.zst';
          final reports = await runComplete(dest, (_) => 'v-1\n"e1"');
          expect(reports, isNotEmpty);
        });

        test('האימות במסלול alreadyComplete רושם סימון לריצה הבאה', () async {
          final dest = '${tmp.path}/seforim.db.zst';
          expect(await runComplete(dest, (_) => 'v-1\n"e1"'), isNotEmpty);
          // אותו קובץ, אותו קובץ צד — הפעם בלי קריאה נוספת.
          final reports = <(int, int)>[];
          await downloaderThatCaptures(
            [],
            handler: (req) async =>
                http.StreamedResponse(const Stream.empty(), 416),
          ).downloadToFile(
            url: 'https://x/seforim.db.zst',
            destPath: dest,
            expectedSize: full.length,
            expectedSha256: fullHash,
            resumeToken: 'v-1',
            onVerifyProgress: (v, t) => reports.add((v, t)),
          );
          expect(reports, isEmpty);
          // ה-ETag לא נדרס בדרך.
          expect(sidecarIdentity(dest), 'v-1\n"e1"');
        });

        /// נכס שלם תחת טוקן ישן, מול טוקן חדש — מה שפרסום מחדש של אותו
        /// תוכן (תג חדש) מייצר. מחזיר את הבקשות ואת דיווחי האימות.
        Future<(List<http.BaseRequest>, List<(int, int)>)> runRetagged(
          String dest,
          List<int> onDisk,
          String Function(String dest) sidecar,
        ) async {
          File(dest).writeAsBytesSync(onDisk);
          File('$dest.resume').writeAsStringSync(sidecar(dest));
          final captured = <http.BaseRequest>[];
          final reports = <(int, int)>[];
          await downloaderThatCaptures(
            captured,
            handler: (req) async => http.StreamedResponse(
              Stream.value(full),
              200,
              contentLength: full.length,
            ),
          ).downloadToFile(
            url: 'https://x/seforim.db.zst',
            destPath: dest,
            expectedSize: full.length,
            expectedSha256: fullHash,
            resumeToken: 'v-new',
            onVerifyProgress: (v, t) => reports.add((v, t)),
          );
          return (captured, reports);
        }

        test('טוקן שונה, אותו תוכן מסומן → נקשר לטוקן החדש בלי רשת ובלי hash',
            () async {
          final dest = '${tmp.path}/seforim.db.zst';
          final (captured, reports) = await runRetagged(
              dest, full, (d) => 'v-old\n"e1"\n${markFor(d, fullHash)}');
          expect(captured, isEmpty);
          expect(reports, isEmpty);
          expect(File(dest).readAsBytesSync(), full);
          expect(sidecarIdentity(dest), 'v-new');
        });

        test('טוקן שונה, אותו תוכן בלי סימון → hash אחד, בלי רשת', () async {
          final dest = '${tmp.path}/seforim.db.zst';
          final (captured, reports) =
              await runRetagged(dest, full, (_) => 'v-old');
          expect(captured, isEmpty);
          expect(reports, isNotEmpty);
          expect(sidecarIdentity(dest), 'v-new');
        });

        test('ביטול באמצע ה-hash של האימוץ אינו מוחק את הקובץ', () async {
          final dest = '${tmp.path}/seforim.db.zst';
          File(dest).writeAsBytesSync(full);
          File('$dest.resume').writeAsStringSync('v-old');
          // הבדיקה הראשונה היא בכניסה; השנייה כבר בתוך ה-hash של האימוץ.
          var checks = 0;
          final captured = <http.BaseRequest>[];
          await expectLater(
            downloaderThatCaptures(
              captured,
              handler: (req) async =>
                  http.StreamedResponse(const Stream.empty(), 500),
            ).downloadToFile(
              url: 'https://x/seforim.db.zst',
              destPath: dest,
              expectedSize: full.length,
              expectedSha256: fullHash,
              resumeToken: 'v-new',
              isCancelled: () => ++checks > 1,
            ),
            throwsA(isA<PatchDownloadCancelled>()),
          );
          expect(checks, 2);
          expect(captured, isEmpty);
          expect(File(dest).readAsBytesSync(), full);
          expect(sidecarIdentity(dest), 'v-old');
        });

        test('טוקן שונה, קובץ גדול מהצפוי → אינו מאומץ ויורד מחדש', () async {
          final dest = '${tmp.path}/seforim.db.zst';
          final (captured, reports) =
              await runRetagged(dest, [...full, 1], (_) => 'v-old');
          expect(reports, isEmpty);
          expect(captured, hasLength(1));
          expect(File(dest).readAsBytesSync(), full);
        });

        test('טוקן שונה, תוכן אחר באותו אורך → יורד מחדש', () async {
          final dest = '${tmp.path}/seforim.db.zst';
          final other = List<int>.filled(full.length, 7);
          final (captured, _) = await runRetagged(dest, other, (_) => 'v-old');
          expect(captured, hasLength(1));
          expect(captured.single.headers.containsKey('Range'), isFalse);
          expect(File(dest).readAsBytesSync(), full);
        });

        test('טוקן שונה, סימון ישן לקובץ שהוחלף → hash מלא ואז הורדה',
            () async {
          final dest = '${tmp.path}/seforim.db.zst';
          // אותו digest ואורך, זמן-שינוי אחר: הקובץ נכתב מחדש אחרי הסימון.
          final staleMark = '$fullHash|${full.length}|1';
          final other = List<int>.filled(full.length, 7);
          final (captured, reports) =
              await runRetagged(dest, other, (_) => 'v-old\n"e1"\n$staleMark');
          expect(reports, isNotEmpty);
          expect(captured, hasLength(1));
          expect(File(dest).readAsBytesSync(), full);
        });
      });
    });

    // P3: sha256 מחושב בזרימה (בלי קריאה חוזרת של הקובץ מהדיסק).

    // finding 1: גוף תגובת שגיאה של הנכס נזנח מיד (המנוי מבוטל) — שרת שבור
    // שאינו סוגר את הזרם אינו תולה את הפעולה.

    // finding 1: במסלול שגיאה של הנכס הגוף נזנח מיד ולא נצרך עד הסוף — שרת
    // ש"מדבר" 1.5GB לא יזרים הכל רק כדי לדווח כשל. כאן 500 עם גנרטור מונה
    // ארוך: המנוי מבוטל, ורק מעט chunks (אם בכלל) נמשכים.

    // finding P1: 206 קצר חוקי (subset לפי RFC 9110) אינו סיום — ממשיכים עם
    // Range נוסף עד ה-total הידוע, ולא מכריזים הצלחה על קובץ קטוע.

    // finding P3: בדיקות ביטול בגבולות הפעולה.

    // finding P4: כותרת 416 עם זבל נלווה אינה הוכחת שלמות (פענוח מעוגן).

    // finding P2: ה-sink נסגר ב-finally גם כשהזרם זורק — ה-handle משוחרר
    // ומחיקת/פתיחת הקובץ החלקי מצליחה מיד (ב-Windows handle פתוח חוסם מחיקה).

    // finding 1: כשל flush/close במסלול ההצלחה חייב להיכשל (לא הצלחה שקטה) —
    // קובץ שאורכו מלא אך תוכנו לא נכתב לדיסק היה עובר alreadyComplete בריצה
    // הבאה. תיקיה במקום הקובץ מכשילה את openWrite בסגירה בצורה דטרמיניסטית.

    // finding 2: total לא-עקבי בין סבבי 206 ('/40' ואז '/31') אינו הצלחה —
    // מתחילים מאפס. בלי הבדיקה, 31 בייט היו מתקבלים כהורדה שלמה.

    // finding 3: שרת ששולח בייט אחד בכל 206 חסום ב-_maxContinuationRounds —
    // נכשל, אך החלקי (בייטים תקינים) וקובץ הצד נשמרים להמשך בריצה הבאה.

    // finding 4: מד ההתקדמות בהורדה רב-סבבית לא מדווח 100% מוקדם — ה-total הכולל
    // (מ-Content-Range) גובר על אומדן-הסבב, ואינו קטן בין סבבים.

    // finding P2: כבילת ה-resume לייצוג בצד השרת דרך If-Range/ETag.
  });

  test('toString של חריג ההורדה מחזיר את ההודעה בלבד', () {
    expect(const PatchDownloadException('שגיאה').toString(), 'שגיאה');
  });
}
