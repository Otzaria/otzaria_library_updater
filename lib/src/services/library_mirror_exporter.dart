import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../hashing/fast_sha256.dart';
import '../messages/library_updater_messages.dart';
import '../models/delta_manifest.dart';
import '../models/library_release.dart';
import '../models/library_update_plan.dart';
import '../models/patch_table_spec.dart';
import '../models/split_asset.dart';
import 'apply_time_estimate.dart';
import 'disk_space_probe.dart';
import 'download_scheduler.dart';
import 'github_library_release_client.dart';
import 'library_update_discovery.dart';
import 'local_mirror_library_release_client.dart';
import 'patch_downloader.dart';

/// נתיב יחסי עם `/`, כדי שמראה שנוצרה ב-Windows תיקרא גם ב-macOS.
String mirrorRelativePath(String path,
    {required String from, p.Context? context}) {
  final ctx = context ?? p.context;
  return p.posix.joinAll(ctx.split(ctx.relative(path, from: from)));
}

/// בונה "מראה" (mirror) מקומית מלאה של כל עדכוני הספרייה מ-GitHub,
/// לתיקייה על הדיסק (USB / תיקייה משותפת) — כדי שמחשבים **בלי אינטרנט
/// בכלל** יוכלו לעדכן את ה-DB אחר-כך דרך [LocalMirrorLibraryReleaseClient],
/// בלי לגעת ב-GitHub בכלל.
///
/// מריצים את [export] פעם אחת במחשב **עם** אינטרנט; אחר-כך מעתיקים את
/// התיקייה שנוצרה (USB וכו') ופותחים אותה במחשבים האחרים דרך "עדכן מתיקייה
/// מקומית" בלאנצ'ר.
///
/// **הערה על גודל:** המראה נושאת **עותק אחד** של ה-DB המלא (~1.5GB דחוס) ואת
/// ה-patches של [historyDepth] ה-releases האחרונים (עשרות MB כל אחד), לא את
/// כל ההיסטוריה. ראו [recentReleases]. המסד המלא הזה אינו בהכרח של הגרסה
/// האחרונה: מסד שכבר יושב במראה נשמר כל עוד יש ממנו מסלול patches ל-latest,
/// כדי שעדכון שוטף יעלה עשרות MB ולא ~1.1GB — ראו [_chooseFullDbCarrier].
/// שינוי סכמה שובר את החישוב הזה: קובצי ה-patch שחוצים אותו אינם ניתנים
/// להחלה, ולכן הם אינם נכנסים למראה והמסד המלא **החדש** מורד במקומם.
/// גם קובץ עדכון שהחלתו ארוכה מהחלפת המסד המלא שובר אותו — קשת כזו אינה
/// נכנסת למראה כלל, גם לא בהורדה הבאה שאחרי שנפסלה. ראו [_dropSlowPatches]
/// ו-[ApplyTimeEstimate].
///
/// `fromVersion` ב-[export] מחליף את שני אלה במצב "עדכון אישי": patches
/// מהגרסה שמותקנת אצל המשתמש ומעלה בלבד, בלי המסד המלא — ראו
/// [personalReleases]. **גם שם אותו כלל זמן חל:** כששרשרת ה-patches של
/// המשתמש ארוכה בהרבה מהמסד המלא, או שאינה קיימת כלל, המסד המלא כן יורד.
/// המצב הזה נועד לחסוך אותו, לא להשאיר את המשתמש עם העדכון היקר מבין
/// השניים.
///
/// **הנכסים יורדים במקביל, הגדול ראשון** — ראו [DownloadScheduler]: קובצי
/// ה-patch רצים לצד המסד הגדול במקום לחכות לו. קובץ גדול יורד גם בכמה
/// טווחים כשהשרת מכבד `Range` — ראו [PatchDownloader.maxConnections].
class LibraryMirrorExporter {
  LibraryMirrorExporter({
    GithubLibraryReleaseClient? client,
    http.Client? httpClient,
    this.historyDepth = defaultHistoryDepth,
    this.applyTime = const ApplyTimeEstimate(),
    required this.supportedDbSchemaVersion,
    DownloadScheduler? scheduler,
    int? Function(String path)? freeBytesFor,
    int maxConnections = PatchDownloader.defaultMaxConnections,
    int segmentThresholdBytes = PatchDownloader.defaultSegmentThresholdBytes,
  })  : _scheduler = scheduler ?? DownloadScheduler(),
        _freeBytesFor = freeBytesFor ?? DiskSpaceProbe.freeBytesFor,
        _client = client ?? GithubLibraryReleaseClient(),
        _ownsClient = client == null,
        _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null {
    _downloader = PatchDownloader(
      httpClient: _httpClient,
      // הייצוא רק מוריד לדיסק ואינו מחלץ דבר — `downloadAndExtract` לא נקרא
      // כאן, ולכן אין למי לספק פונקציית חילוץ.
      decompress: _neverDecompress,
      maxConnections:
          _connectionsPerFile(maxConnections, _scheduler.maxConcurrent),
      segmentThresholdBytes: segmentThresholdBytes,
    );
  }

  /// תקרת החיבורים של כל הייצוא. כל משבצת של ה-scheduler מקבלת חלק שווה,
  /// כך שגם כשכל המשבצות מורידות קבצים גדולים הסכום אינו עובר אותה.
  static const int maxTotalConnections = 8;

  static int _connectionsPerFile(int requested, int maxConcurrent) {
    final share = maxTotalConnections ~/ maxConcurrent;
    final cap = share < 1 ? 1 : share;
    if (requested < 1) return 1;
    return requested < cap ? requested : cap;
  }

  /// כמה חיבורים פותח קובץ גדול אחד בייצוא הזה.
  int get connectionsPerFile => _downloader.maxConnections;

  /// כמה releases אחרונים נשמרים במראה — ראו [recentReleases]. עשרה מכסים
  /// בפועל מחשב שלא עודכן כמה חודשים, בעלות של כמה עשרות MB.
  static const int defaultHistoryDepth = 10;

  /// עומק היסטוריית ה-patches שנשמרת במראה.
  final int historyDepth;

  /// אומדן זמן העדכון אצל המשתמש, שלפיו נבחר בין היסטוריית patches לבין מסד
  /// מלא — ראו [_dropSlowPatches]. ניתן להזרקה כדי שהבדיקות לא יידרשו
  /// לייצר גיגה-בייטים אמיתיים.
  final ApplyTimeEstimate applyTime;

  /// הסכמה הגבוהה ביותר של DB מלא שהמראה נושאת.
  final int supportedDbSchemaVersion;

  final GithubLibraryReleaseClient _client;
  final bool _ownsClient;
  final http.Client _httpClient;
  final bool _ownsHttpClient;

  /// מה שמריץ את הנכסים במקביל — ראו [DownloadScheduler]. ניתן להזרקה כדי
  /// שהקבצים הנלווים יחלקו את אותה תקרת חיבורים ולא יפתחו תקרה משלהם.
  final DownloadScheduler _scheduler;

  final int? Function(String path) _freeBytesFor;

  /// ההורדה עוברת דרך [PatchDownloader] ולא דרך `http` ישר. זה לא ניקיון קוד:
  /// המוריד הזה כבר מביא זמן קצוב, אימות גודל ו-sha256, חידוש הורדה (Range +
  /// If-Range) ומחיקה של קובץ חלקי שאינו ניתן לחידוש. בלעדיו הורדת ה-DB המלא
  /// (~1GB) על חיבור שנפל התחילה מאפס בכל פעם, ושרת שנשתק תלה את הייצוא בלי
  /// גבול — וזה בדיוק המסלול שהמשתמש מריץ פעם אחת על מחשב מקוון.
  late final PatchDownloader _downloader;

  static const String rejectedSplitsFileName = 'rejected-split-archives.json';

  final Set<String> _rejectedSplits = {};

  /// בונה מראה מלאה תחת [destDir] (נוצרת אם חסרה). מוריד את כל ה-releases
  /// הרלוונטיים (כאלה עם delta manifests ו/או DB מלא), כולל כל קובצי ה-patch
  /// שכל manifest מצביע עליהם, וכותב `releases.json` בסוף.
  ///
  /// [fromVersion] — מצב "עדכון אישי": מורידים רק patches מהגרסה הזו ומעלה,
  /// **בלי** המסד המלא. ראו [personalReleases].
  ///
  /// מחזיר `false` במצב אישי שבו אין גרסה חדשה מ-[fromVersion] — ואז המראה
  /// הקיימת אינה נגעת בכלל: היא עדיין תקפה, ומחיקת נכסיה הייתה מוחקת מראה
  /// שלמה רק בגלל שהמחשב הזה מעודכן.
  Future<bool> export({
    required String destDir,
    bool allowPrerelease = true,
    int? fromVersion,
    void Function(String stage)? onStage,
    void Function(int doneAssets, int totalAssets)? onAssetProgress,
    void Function(int downloaded, int? total)? onBytesProgress,
    void Function(String warning)? onWarning,
    bool Function()? isCancelled,
  }) async {
    final strings = LibraryUpdaterMessages.current;
    _rejectedSplits.addAll(_readRejectedSplits(destDir));

    onStage?.call(strings.exportLoadingReleases);
    final all = await _client.fetchReleases();
    var eligible = LibraryUpdateDiscovery.eligibleReleases(
      all,
      allowPrerelease: allowPrerelease,
    );
    final personal = fromVersion != null;
    List<LibraryRelease> relevant;
    int latestEligible;
    LibraryRelease? personalCarrier;
    // מניפסטי הפיצול נשלפים רק למועמדים לנשא, לפני בחירתו. מסד מפוצל פגום
    // נחשב כאילו אינו קיים — ואז המועמדים מחושבים מחדש, עד שאין מה לפסול.
    while (true) {
      relevant = personal
          ? personalReleases(eligible, fromVersion)
          : recentReleases(eligible);
      // נגזרים מ-[eligible]: במצב אישי `relevant` מסנן releases בלי קובצי
      // עדכון, וגרסה שיצאה עם מסד מלא בלבד הייתה נעלמת.
      latestEligible = _latestVersionOf(eligible);
      personalCarrier =
          personal ? _newestFullDbCarrier(eligible, latestEligible) : null;
      final unresolved = {
        ...relevant,
        ?personalCarrier,
      }.where((r) => _fullDb(r)?.isSplitFullDbManifest ?? false).toList();
      if (unresolved.isEmpty) break;
      _throwIfCancelled(isCancelled);
      final replaced = await _resolveSplitFullDbs(
        unresolved,
        onWarning: onWarning,
      );
      if (replaced.isEmpty) break;
      eligible = [for (final r in eligible) replaced[r] ?? r];
    }

    if (relevant.isEmpty) {
      if (!personal) throw StateError(strings.exportNoReleases);
      // release שיצא בלי קובצי עדכון כלל אינו "אין גרסה חדשה": המסד המלא
      // הוא כל המסלול אליו, וזה בדיוק המקרה שבו גם מצב אישי מוריד אותו.
      if (personalCarrier == null || latestEligible <= fromVersion) {
        onStage?.call(strings.exportPersonalUpToDate(fromVersion));
        return false;
      }
    }

    final root = Directory(destDir);
    await root.create(recursive: true);
    final assetsRoot = Directory(p.join(destDir, 'assets'));
    await assetsRoot.create(recursive: true);

    if (personal) onStage?.call(strings.exportPersonalFrom(fromVersion));

    // ה-manifests וקובצי ה-patch לכל release, לפי שם (בלי כפילויות). ה-DB
    // המלא נוסף אחר כך, כי בחירת הנשא שלו תלויה ב-edges שנאספים כאן.
    final neededByRelease = <LibraryRelease, Map<String, ReleaseAsset>>{};
    final edges = <({int from, int to})>[];
    // הסכמה הגבוהה שנראתה ואיננו יודעים להחיל, 0 אם אין כזו. [blockingFormat]
    // הוא אותו דבר על ציר פורמט ה-`patch.db`.
    var blockingSchema = 0;
    var blockingFormat = 0;
    // נכסי כל קשת קבילה, להסרת קשת חסרת תועלת ([_dropUselessPatches]).
    // manifests של קשתות שנפסלו אינם כאן, ולכן נשארים במראה כהסבר.
    final mirroredEdges = <MirroredEdge>[];
    final prefetched = await _prefetchDeltaManifests(
      relevant,
      isCancelled: isCancelled,
    );
    for (final release in relevant) {
      _throwIfCancelled(isCancelled);
      final needed = <String, ReleaseAsset>{};
      for (final manifestAsset in release.deltaManifestAssets) {
        needed[manifestAsset.name] = manifestAsset;
        final manifest = _manifestOrNull(
          manifestAsset,
          prefetched[manifestAsset]!,
          onWarning: onWarning,
        );
        if (manifest == null) continue;
        // מחסום סכמה: אין מה להעתיק ואין מה להזהיר עליו, ה-manifest נשמר.
        if (manifest.fullRebase) continue;
        // קובצי patch בסכמה לא מוכרת אינם נכנסים למראה, אבל ה-manifest נשמר —
        // בלעדיו הגרסה החדשה נעלמת ונראית באופליין כ"מעודכן".
        if (!_schemaAppliable(manifest)) {
          final schema = _unsupportedSchemaOf(manifest);
          if (schema > blockingSchema) blockingSchema = schema;
          onWarning?.call(strings.exportSkippingUnappliablePatch(
            release.tag,
            manifest.patchFiles.first.file,
            schema,
          ));
          continue;
        }
        // הציר השני: הסכמה מוכרת אבל פורמט ה-`patch.db` אינו.
        if (!_patchFormatAppliable(manifest)) {
          final format = manifest.patchFormatVersion!;
          if (format > blockingFormat) blockingFormat = format;
          onWarning?.call(strings.exportSkippingUnsupportedPatchFormat(
            release.tag,
            manifest.patchFiles.first.file,
            format,
          ));
          continue;
        }
        // הציר השלישי: דחיסה שאיננו יודעים לחלץ. ה-manifest נשמר (והגרסה
        // נספרת ל-latest), הקבצים לא.
        if (!manifest.hasSupportedCompression) {
          final unknown = manifest.patchFiles
              .map((f) => f.compression)
              .firstWhere(
                  (c) => !PatchFileEntry.supportedCompressions.contains(c));
          onWarning?.call(strings.unsupportedPatchCompression(unknown));
          continue;
        }
        var complete = true;
        final fileNames = <String>[];
        for (final patchFile in manifest.patchFiles) {
          final asset = release.assetByName(patchFile.file);
          if (asset != null) {
            needed[asset.name] = asset;
            fileNames.add(asset.name);
          } else {
            complete = false;
            // קובץ שעוד עולה או שהוסר: ה-edge ייעלם באופליין, ולכן אומרים זאת
            // במקום להיעלם בשקט.
            onWarning?.call(strings.exportPatchAssetMissing(
              release.tag,
              patchFile.file,
            ));
          }
        }
        // רק edge שכל קבציו יורדים נבנה באופליין; edge חסר היה משאיר את המסד
        // המלא הישן על סמך מסלול שאינו קיים.
        if (complete) {
          edges.add((from: manifest.fromVersion, to: manifest.toVersion));
          mirroredEdges.add((
            release: release,
            from: manifest.fromVersion,
            to: manifest.toVersion,
            assetNames: [manifestAsset.name, ...fileNames],
          ));
        }
      }
      neededByRelease[release] = needed;
    }

    // ה-DB המלא נדרש פעם אחת לכל המראה — באופליין נבחר תמיד הגבוה ביותר.
    // במצב אישי הוא נשמט לגמרי; זה כל החיסכון שבמצב הזה.
    final latestVersion = _latestVersionOf(relevant.where(_hasDbContent));
    if (blockingSchema > 0 || blockingFormat > 0) {
      if (personal) {
        if (personalCarrier == null) {
          onWarning?.call(
              strings.exportPersonalNoFullDbEither(fromVersion, latestVersion));
        }
      } else if (blockingSchema > 0) {
        onStage?.call(strings.exportFullDbRequiredBySchema(
            blockingSchema, latestVersion));
      } else {
        onStage?.call(strings.exportFullDbRequiredByPatchFormat(
          blockingFormat,
          latestVersion,
        ));
      }
    }

    if (!personal) {
      _dropSlowPatches(
        neededByRelease: neededByRelease,
        mirroredEdges: mirroredEdges,
        edges: edges,
        relevant: relevant,
        onStage: onStage,
      );
    }

    final fullDbCarrier = personal
        ? null
        : _chooseFullDbCarrier(relevant, edges, assetsRoot.path, onStage);
    if (fullDbCarrier != null) {
      _dropSlowPatches(
        neededByRelease: neededByRelease,
        mirroredEdges: mirroredEdges,
        edges: edges,
        relevant: relevant,
        onStage: onStage,
        noCreditUpTo: LibraryUpdateDiscovery.releaseVersionOf(fullDbCarrier),
      );
    }
    if (fullDbCarrier != null) {
      final full = _fullDb(fullDbCarrier)!;
      neededByRelease[fullDbCarrier]![full.name] = full;

      final dropped = _dropUselessPatches(
        neededByRelease: neededByRelease,
        mirroredEdges: mirroredEdges,
        edges: edges,
        carrier: fullDbCarrier,
      );
      if (dropped > 0) {
        onStage?.call(strings.exportSkippingPatchesFullDbWins(
          dropped,
          LibraryUpdateDiscovery.releaseVersionOf(fullDbCarrier),
        ));
      }
    }

    // אותו כלל זמן במצב אישי: שרשרת ארוכה בהרבה מהמסד המלא, או חסרה, מורידה
    // אותו. הנשא מ-[eligible], כי `personalReleases` מסנן release בלי patches.
    if (personal && personalCarrier != null) {
      final beaten = _fullDbBeatsPatches(
        [personalCarrier],
        neededByRelease,
        mirroredEdges,
        latestVersion: latestEligible,
        fromVersion: fromVersion,
      );
      if (beaten != null) {
        _switchToFullDbOnly(
          beaten,
          neededByRelease: neededByRelease,
          onStage: onStage,
        );
      }
    }

    // release בלי נכסים נשאר ברשימה: גרסתו נספרת ל-latest באופליין לפי ה-tag,
    // והסרתו הייתה מעלימה גרסה שקיימת.
    final plannedByRelease = <LibraryRelease, List<ReleaseAsset>>{
      for (final entry in neededByRelease.entries)
        entry.key: entry.value.values.toList(growable: false),
    };

    final totalAssets =
        plannedByRelease.values.fold<int>(0, (n, l) => n + l.length);

    final schemaMarkers = <LibraryRelease, ReleaseAsset>{};
    for (final release in plannedByRelease.keys) {
      final schema = _unsupportedFullDbSchema(release);
      if (schema == null) continue;
      schemaMarkers[release] = _fullDbSchemaMarker(
        release,
        schema,
        assetsRootPath: assetsRoot.path,
        destDir: destDir,
      );
      onWarning
          ?.call(strings.exportFullDbSchemaUnsupported(release.tag, schema));
    }

    // DB מפוצל: המניפסט הוא מקור ה-sha256 של כל חלק ושל הקובץ המורכב.
    final splits = <_SplitJob>[];
    for (final entry in plannedByRelease.entries) {
      for (final asset in entry.value) {
        final split = asset.split;
        if (split == null) continue;
        final dest =
            p.join(assetsRoot.path, _safeDirName(entry.key.tag), asset.name);
        splits.add((
          release: entry.key,
          asset: asset,
          manifest: split,
          dest: dest,
          partsDir: splitPartsDir(dest),
        ));
      }
    }

    var doneAssets = 0;
    // מסד מפוצל שכבר הורכב ואומת בריצה קודמת אינו יורד שוב.
    final assembled = <_SplitJob>{};
    for (final split in splits) {
      _throwIfCancelled(isCancelled);
      if (await _downloader.verifyExistingFile(
        destPath: split.dest,
        expectedSize: split.manifest.size,
        expectedSha256: split.manifest.sha256,
        resumeToken: _assembledToken(split.manifest),
        onVerifyProgress: (verified, total) => onStage?.call(
          strings.exportVerifying(
            split.release.tag,
            split.asset.name,
            total > 0 ? (verified * 100 ~/ total).clamp(0, 100) : 0,
          ),
        ),
        isCancelled: isCancelled,
      )) {
        assembled.add(split);
        doneAssets++;
      } else {
        // שארית שאינה התוכן הנכון רק תופסת מקום עד ההרכבה.
        _deleteQuietly(split.dest);
        _deleteQuietly(PatchDownloader.resumeSidecarPath(split.dest));
      }
    }

    // המקום נבדק לפי מה שנשאר להוריד, אחרי אימות המפוצלים (מורכב פגום נמחק);
    // ה-prune רץ רק בסוף, ולכן בדרך יש על הכונן שני עותקים של המסד.
    _ensureSpaceForPlan(destDir, assetsRoot, plannedByRelease);

    // מדווחים את היעד עוד לפני הנכס הראשון: אחרת מד ההתקדמות אינו יודע לכמה
    // נכסים לחכות עד שהראשון (המסד המלא, ~1GB) מסתיים.
    onAssetProgress?.call(doneAssets, totalAssets);

    // הגדולה ראשונה, כדי שקובצי ה-patch ירוצו לצד המסד המלא ולא אחריו. חלקי
    // מסד מפוצל הם ג'ובים נפרדים, ולכן יורדים במקביל זה לזה.
    final jobs = <_DownloadJob>[];
    for (final entry in plannedByRelease.entries) {
      final tagDir =
          Directory(p.join(assetsRoot.path, _safeDirName(entry.key.tag)));
      await tagDir.create(recursive: true);
      for (final asset in entry.value) {
        if (asset.split == null) {
          jobs.add((
            release: entry.key,
            asset: asset,
            dest: p.join(tagDir.path, asset.name),
            sha256: _sha256FromDigest(asset.digest),
            resumeToken: asset.id?.toString(),
            countsAsAsset: true,
          ));
          continue;
        }
        final split = splits.firstWhere((s) => identical(s.asset, asset));
        if (assembled.contains(split)) continue;
        await Directory(split.partsDir).create(recursive: true);
        for (final part in split.manifest.parts) {
          jobs.add((
            release: entry.key,
            asset: ReleaseAsset(
              name: part.name,
              downloadUrl: part.downloadUrl,
              size: part.size,
            ),
            dest: p.join(split.partsDir, part.name),
            sha256: part.sha256,
            // זהות התוכן: לחלק אין מזהה נכס משלו במודל.
            resumeToken: 'part:${part.sha256}',
            countsAsAsset: false,
          ));
        }
      }
    }
    jobs.sort((a, b) => b.asset.size.compareTo(a.asset.size));

    // מונה אחד לכל התוכנית; נכס שכבר שלם על הכונן מנוכה מהיעד, אחרת המד
    // מבטיח הורדה גדולה ממה שעובר ברשת.
    final bytes = ByteProgressAggregator(
      totalBytes: jobs.fold<int>(
        0,
        (sum, job) => sum + (job.asset.size > 0 ? job.asset.size : 0),
      ),
      onProgress: onBytesProgress,
    );

    // הניכוי נקבע לפני ההורדה הראשונה, כדי שהיעד לא יקפוץ באמצע. רק נכס שלם
    // מנוכה כאן; תחילית חלקית מנכה ההורדה עצמה.
    final slots = <ByteProgressSlot>[
      for (final job in jobs)
        bytes.slot(existingBytes: _completeOnDisk(job.dest, job.asset.size)),
    ];
    bytes.announce();

    await _scheduler.run<void>([
      for (final (index, job) in jobs.indexed)
        () async {
          _throwIfCancelled(isCancelled);
          onStage?.call(
              strings.exportDownloading(job.release.tag, job.asset.name));
          final progress = slots[index];
          await _downloader.downloadToFile(
            url: job.asset.downloadUrl,
            destPath: job.dest,
            // ה-manifests נכתבים ע"י GitHub ללא `size` אמין בכל המקרים; `size`
            // של asset אמיתי כן מדויק, ואי-התאמה שלו היא הורדה שנקטעה.
            expectedSize: job.asset.size > 0 ? job.asset.size : null,
            expectedSha256: job.sha256,
            // מזהה ה-asset הוא הזהות היציבה שמאפשרת לחדש הורדה שנקטעה במקום
            // להתחיל מאפס — ראו PatchDownloader.downloadToFile.
            resumeToken: job.resumeToken,
            onProgress: progress.report,
            // נכס שכבר על הכונן אינו יורד — ולכן גם אינו נספר במד.
            onExistingBytes: progress.markExisting,
            // אימות אינו הורדה: האחוז נמסר בכיתוב השלב, לא במד הבייטים, שהיה
            // נשאר קפוא בזמן קריאת הנכס מהכונן.
            onVerifyProgress: (verified, total) => onStage?.call(
              strings.exportVerifying(
                job.release.tag,
                job.asset.name,
                total > 0 ? (verified * 100 ~/ total).clamp(0, 100) : 0,
              ),
            ),
            isCancelled: isCancelled,
          );
          if (job.countsAsAsset) {
            doneAssets++;
            onAssetProgress?.call(doneAssets, totalAssets);
          }
        },
    ]);

    var rejectedSplit = false;
    for (final split in splits) {
      if (assembled.contains(split)) continue;
      if (!await _assembleSplit(
        split,
        destDir: destDir,
        onStage: onStage,
        isCancelled: isCancelled,
      )) {
        rejectedSplit = true;
        continue;
      }
      doneAssets++;
      onAssetProgress?.call(doneAssets, totalAssets);
    }
    if (rejectedSplit) {
      return export(
        destDir: destDir,
        allowPrerelease: allowPrerelease,
        fromVersion: fromVersion,
        onStage: onStage,
        onAssetProgress: onAssetProgress,
        onBytesProgress: onBytesProgress,
        onWarning: onWarning,
        isCancelled: isCancelled,
      );
    }
    // נבנה רק אחרי שכל ההורדות הצליחו — כשל של אחת זורק, ולכן כל נכס
    // שברשימה אכן יושב שלם בדיסק.
    final mirroredReleases = <LibraryRelease>[
      for (final entry in plannedByRelease.entries)
        LibraryRelease(
          tag: entry.key.tag,
          isPrerelease: entry.key.isPrerelease,
          isDraft: entry.key.isDraft,
          publishedAt: entry.key.publishedAt,
          assets: [
            for (final asset in entry.value)
              ReleaseAsset(
                name: asset.name,
                downloadUrl: mirrorRelativePath(
                  p.join(
                    assetsRoot.path,
                    _safeDirName(entry.key.tag),
                    asset.name,
                  ),
                  from: destDir,
                ),
                size: asset.size,
                id: asset.id,
                updatedAt: asset.updatedAt,
                digest: asset.digest,
              ),
            ?schemaMarkers[entry.key],
          ],
        ),
    ];
    for (final entry in schemaMarkers.entries) {
      await File(p.join(
        assetsRoot.path,
        _safeDirName(entry.key.tag),
        entry.value.name,
      )).writeAsBytes(const [], flush: true);
    }

    onStage?.call(
      strings.exportWritingManifest(
        LocalMirrorLibraryReleaseClient.manifestFileName,
      ),
    );
    // כתיבה אטומית: שליפת הכונן באמצע כתיבה ישירה הייתה משאירה JSON פגום,
    // והמחשב הלא-מקוון היה רואה מראה שבורה.
    final manifestPath =
        p.join(destDir, LocalMirrorLibraryReleaseClient.manifestFileName);
    final manifestTmp = File('$manifestPath.tmp');
    await manifestTmp.writeAsString(
      jsonEncode({
        'formatVersion': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'releases': mirroredReleases.map((r) => r.toMirrorJson()).toList(),
      }),
      flush: true,
    );
    await manifestTmp.rename(manifestPath);

    await _pruneStaleAssets(assetsRoot, {
      for (final entry in plannedByRelease.entries)
        entry.key: [
          ...entry.value,
          ?schemaMarkers[entry.key],
        ],
    });

    onStage?.call(strings.exportDone);
    return true;
  }

  /// זורק כשידוע בוודאות שאין מקום להורדה שנותרה. מדידה שנכשלה אינה חוסמת —
  /// ראו [DiskSpaceProbe]. נכס שכבר על הדיסק נספר לפי מה שחסר בו בלבד.
  void _ensureSpaceForPlan(
    String destDir,
    Directory assetsRoot,
    Map<LibraryRelease, List<ReleaseAsset>> planned,
  ) {
    var needed = 0;
    for (final entry in planned.entries) {
      final tagDir = p.join(assetsRoot.path, _safeDirName(entry.key.tag));
      for (final asset in entry.value) {
        if (asset.size <= 0) continue;
        final existing = File(p.join(tagDir, asset.name));
        final have = existing.existsSync() ? existing.lengthSync() : 0;
        final missing = asset.size - have;
        if (missing <= 0) continue;
        needed += missing;
        final split = asset.split;
        if (split == null) {
          needed += _segmentAssemblyOverhead(asset.size);
        } else {
          final partsDir = splitPartsDir(existing.path);
          for (final part in split.parts) {
            final file = File(p.join(partsDir, part.name));
            final partHave = file.existsSync() ? file.lengthSync() : 0;
            if (part.size > partHave) {
              needed +=
                  part.size - partHave + _segmentAssemblyOverhead(part.size);
            }
          }
        }
      }
    }
    if (needed == 0) return;
    final free = _freeBytesFor(destDir);
    if (free == null || !DiskSpaceProbe.lacksSpace(free, needed)) return;
    throw StateError(LibraryUpdaterMessages.current.mirrorNotEnoughDiskSpace(
      destDir,
      DiskSpaceProbe.formatBytes(needed),
      DiskSpaceProbe.formatBytes(free),
    ));
  }

  /// קובץ שיורד בטווחים מחזיק בזמן הצירוף עותק נוסף של הטווח הגדול ביותר.
  int _segmentAssemblyOverhead(int size) {
    final connections = _downloader.maxConnections;
    if (connections < 2 || size < _downloader.segmentThresholdBytes) return 0;
    return (size + connections - 1) ~/ connections;
  }

  /// כמה מהנכס כבר יושב על הדיסק שלם, כלומר לא יעבור ברשת. התנאי זהה לזה
  /// שבו [PatchDownloader] מדלג על ההורדה; תחילית חלקית מוחזרת כ-0, כי היא
  /// עשויה להימחק ולרדת מאפס — את זה מנכה ההורדה עצמה.
  int _completeOnDisk(String path, int size) {
    if (size <= 0) return 0;
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() < size) return 0;
    return size;
  }

  /// מספר הניסיונות לשליפת manifest. הם קבצים של מאות בתים, ולכן ניסיון חוזר
  /// זול — ובלעדיו בקשה אחת רועדת מתוך ~13 מוחקת edge שלם מהמראה.
  static const int _manifestAttempts = 3;

  Future<T> _fetchWithRetry<T>(
    ReleaseAsset manifestAsset,
    Future<T> Function(String url) fetch,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _manifestAttempts; attempt++) {
      try {
        return await fetch(manifestAsset.downloadUrl);
      } on FormatException {
        rethrow;
      } catch (e) {
        lastError = e;
        if (attempt < _manifestAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        }
      }
    }
    throw StateError(LibraryUpdaterMessages.current
        .exportManifestFetchFailed(manifestAsset.name, '$lastError'));
  }

  Future<Map<ReleaseAsset, _ManifestFetch>> _prefetchDeltaManifests(
    List<LibraryRelease> releases, {
    bool Function()? isCancelled,
  }) async {
    final assets = [
      for (final release in releases) ...release.deltaManifestAssets,
    ];
    final fetched = await _scheduler.run<_ManifestFetch>([
      for (final asset in assets)
        () async {
          _throwIfCancelled(isCancelled);
          try {
            final manifest =
                await _fetchWithRetry(asset, _client.fetchManifest);
            return (manifest: manifest, error: null, stack: null);
          } catch (error, stack) {
            return (manifest: null, error: error, stack: stack);
          }
        },
    ]);
    return {
      for (final (index, asset) in assets.indexed) asset: fetched[index],
    };
  }

  DeltaManifest? _manifestOrNull(
    ReleaseAsset manifestAsset,
    _ManifestFetch fetched, {
    void Function(String warning)? onWarning,
  }) {
    final error = fetched.error;
    if (error is FormatException) {
      onWarning?.call(LibraryUpdaterMessages.current
          .exportManifestUnreadable(manifestAsset.name, error.message));
      return null;
    }
    if (error != null) Error.throwWithStackTrace(error, fetched.stack!);
    return fetched.manifest;
  }

  /// מוחק מתוך [assetsRoot] כל תיקיית tag ונכס שאינם בתוכנית — best-effort:
  /// כשל מחיקה (קובץ נעול) אינו מפיל ייצוא שכבר הצליח.
  Future<void> _pruneStaleAssets(
    Directory assetsRoot,
    Map<LibraryRelease, List<ReleaseAsset>> planned,
  ) async {
    final keepByDir = <String, Set<String>>{};
    for (final entry in planned.entries) {
      keepByDir[_safeDirName(entry.key.tag)] = {
        for (final asset in entry.value) ...[
          asset.name,
          // קובץ הצד הוא חלק מזהות הנכס: בלעדיו הריצה הבאה מוחקת נכס שלם
          // ומורידה 1.5GB מחדש. ראו PatchDownloader.resumeSidecarPath.
          p.basename(PatchDownloader.resumeSidecarPath(asset.name)),
        ],
      };
    }

    await for (final entity in assetsRoot.list(followLinks: false)) {
      try {
        final name = p.basename(entity.path);
        final keep = keepByDir[name];
        if (entity is Directory) {
          await for (final file in entity.list(followLinks: false)) {
            if (keep == null || !keep.contains(p.basename(file.path))) {
              await _deletePreservingLocks(file);
            }
          }
          if (keep == null) {
            // Non-recursive removal is safe if a concurrent download created
            // a new sidecar after the listing; the directory then stays put.
            try {
              await entity.delete();
            } catch (_) {}
          }
        } else {
          // קובץ ישר תחת assets/ — לא נוצר על ידי הייצוא הזה.
          await _deletePreservingLocks(entity);
        }
      } catch (_) {
        // מקום מבוזבז בלבד; לא סיבה להכשיל את ההורדה.
      }
    }
  }

  /// [historyDepth] ה-releases האחרונים שנושאים תוכן מסד, ואיתם — אם אף אחד
  /// מהם לא נושא `seforim.db.zst` — האחרון שכן נושא כזה, כדי שתמיד יהיה
  /// מסלול הורדה מלאה במראה.
  ///
  /// **למה לא כל ההיסטוריה:** אוצריא המקוונת בוחרת מסלול patches מתוך הגרף
  /// המלא, אבל מראה מלאה הגיעה לכמה ג'יגה-בייט והיעד הוא כונן נייד. עומק של
  /// כמה גרסאות מכסה בפועל את מי שמעדכן מדי פעם — קובצי patch הם עשרות MB
  /// לעומת ~1.1GB של המסד המלא — ומי שרחוק יותר נופל להורדה המלאה, שקיימת
  /// במראה תמיד.
  List<LibraryRelease> recentReleases(List<LibraryRelease> eligible) {
    final withDbContent = eligible
        .where((r) => _hasDbContent(r) || _unsupportedFullDbSchema(r) != null)
        .toList()
      ..sort((a, b) => LibraryUpdateDiscovery.releaseVersionOf(b)
          .compareTo(LibraryUpdateDiscovery.releaseVersionOf(a)));
    if (withDbContent.isEmpty) return const [];

    final kept = <LibraryRelease>{
      ...withDbContent.take(historyDepth < 1 ? 1 : historyDepth),
    };
    if (!kept.any((r) => _fullDb(r) != null)) {
      for (final release in withDbContent) {
        if (_fullDb(release) != null) {
          kept.add(release);
          break;
        }
      }
    }
    return kept.toList(growable: false);
  }

  /// מצב "עדכון אישי": כל ה-releases שגרסתם **גבוהה** מ-[fromVersion], בלי
  /// חסימת עומק ובלי המסד המלא. ריק פירושו "המחשב הזה מעודכן", לא שגיאה.
  ///
  /// ה-edge `patch-vN-vM` יושב ב-release שגרסתו M, ולכן "גבוה מ-[fromVersion]"
  /// שומר בדיוק את השרשרת מהגרסה המקומית ולמעלה — עשרות MB לכל צעד, לעומת
  /// ~1.5GB של המסד המלא. אין כאן מרווח ביטחון: גרסה מקומית שאינה מה שנרשם
  /// תיתקל ב-`blocked` מנומק במחשב היעד, ולא בעדכון שקט של הקובץ הלא נכון.
  List<LibraryRelease> personalReleases(
    List<LibraryRelease> eligible,
    int fromVersion,
  ) {
    return eligible
        .where((r) =>
            (r.deltaManifestAssets.isNotEmpty ||
                _unsupportedFullDbSchema(r) != null) &&
            LibraryUpdateDiscovery.releaseVersionOf(r) > fromVersion)
        .toList(growable: false);
  }

  bool _hasDbContent(LibraryRelease release) =>
      release.deltaManifestAssets.isNotEmpty || _fullDb(release) != null;

  ReleaseAsset? _fullDb(LibraryRelease release) =>
      release.fullDbAssetFor(maxSchemaVersion: supportedDbSchemaVersion);

  int? _unsupportedFullDbSchema(LibraryRelease release) => release
      .unsupportedFullDbSchemaFor(maxSchemaVersion: supportedDbSchemaVersion);

  ReleaseAsset _fullDbSchemaMarker(
    LibraryRelease release,
    int schema, {
    required String assetsRootPath,
    required String destDir,
  }) {
    final advertised = release.assets.firstWhere((a) =>
        (a.isFullDbArchive || a.isSplitFullDbManifest) &&
        a.advertisedFullDbSchemaVersion == schema);
    final name = advertised.splitArchiveName ?? advertised.name;
    return ReleaseAsset(
      name: name,
      downloadUrl: mirrorRelativePath(
        p.join(assetsRootPath, _safeDirName(release.tag), name),
        from: destDir,
      ),
      size: 0,
    );
  }

  /// ה-release שממנו מורידים את ה-DB המלא. ברירת המחדל היא הגרסה הגבוהה
  /// שנושאת `seforim.db.zst`, אבל **מסד מלא ישן שכבר יושב במראה מנצח אותה**
  /// כל עוד יש ממנו מסלול patches לגרסה האחרונה: כל release ב-SeforimLibrary
  /// נושא מסד מלא משלו, ולכן בלי ההעדפה הזו כל עדכון היה מוריד ~1.1GB מחדש
  /// בשביל תוצאה שקובצי עדכון של עשרות MB מגיעים אליה בדיוק באותה מידה.
  ///
  /// המחיר: התקנה על מחשב ריק מקבלת את המסד הישן ואז את שרשרת ה-patches —
  /// ראו `LibraryUpdatePlanner.plan` ו-`LibraryManager.applyUpdate`, שמריצים
  /// את שני הצעדים ברצף.
  ///
  /// [edges] מגיע **מסונן** מ-patches שסכמתם אינה מוכרת, ולכן מסד ישן שהמסלול
  /// ממנו חוצה שינוי סכמה אינו "מגיע" ל-latest ומפנה את מקומו למסד המלא החדש.
  /// זה מה שמונע את המצב שבו מסד v21 נשמר בשביל שרשרת שנפסלת בהחלה.
  LibraryRelease? _chooseFullDbCarrier(
    List<LibraryRelease> releases,
    List<({int from, int to})> edges,
    String assetsRootPath,
    void Function(String stage)? onStage,
  ) {
    final carriers = releases.where((r) => _fullDb(r) != null).toList()
      ..sort((a, b) => LibraryUpdateDiscovery.releaseVersionOf(b)
          .compareTo(LibraryUpdateDiscovery.releaseVersionOf(a)));
    if (carriers.isEmpty) return null;

    final newest = carriers.first;
    // כבר על הדיסק — אין מה לחסוך, וגם אין טעם לרדת לגרסה ישנה יותר.
    if (_isCompleteOnDisk(assetsRootPath, newest)) return newest;

    var latest = LibraryUpdateDiscovery.releaseVersionOf(newest);
    for (final edge in edges) {
      if (edge.to > latest) latest = edge.to;
    }

    for (final candidate in carriers.skip(1)) {
      if (!_isCompleteOnDisk(assetsRootPath, candidate)) continue;
      final version = LibraryUpdateDiscovery.releaseVersionOf(candidate);
      // אותה גרסה ב-tag אחר = פרסום מחדש עם תיקון; המסד הישן אינו התוכן הנכון.
      if (version == latest && candidate.tag != newest.tag) continue;
      if (!_reaches(edges, version, latest)) continue;
      onStage?.call(LibraryUpdaterMessages.current
          .exportReusingFullDb(version, candidate.tag));
      return candidate;
    }
    return newest;
  }

  /// האם שני קצות ה-patch בסכמות שאפשר להחיל — אותו כלל בדיוק שמסנן קשתות
  /// ב-`LibraryUpdateDiscovery`, כדי שהמראה לא תישא patch שהמחשב הלא-מקוון
  /// יפסול. ראו [PatchEdge.hasSupportedSchema].
  bool _schemaAppliable(DeltaManifest manifest) =>
      isSupportedSchemaVersion(manifest.fromSchemaVersion) &&
      isSupportedSchemaVersion(manifest.toSchemaVersion);

  /// הציר השני של אותה פסילה — ראו [PatchEdge.hasSupportedPatchFormat].
  bool _patchFormatAppliable(DeltaManifest manifest) {
    final format = manifest.patchFormatVersion;
    return format == null || isSupportedPatchFormatVersion(format);
  }

  /// הסכמה שבגללה ה-patch נפסל — היעד קודם, כי הוא החדשה מהשתיים.
  int _unsupportedSchemaOf(DeltaManifest manifest) =>
      isSupportedSchemaVersion(manifest.toSchemaVersion)
          ? manifest.fromSchemaVersion
          : manifest.toSchemaVersion;

  /// מוציא מהתוכנית קשתות שאין בהן תועלת מול המסד המלא, ומחזיר כמה נכסים
  /// הוסרו. 0 = לא נגענו בכלום.
  ///
  /// **הכלל:** אחרי שמחילים קשת, חייבת להישאר דרך להגיע לפחות לאן שהמסלול
  /// המלא מגיע — אחרת `LibraryUpdatePlanner` יבחר במסד המלא ממילא, והקשת
  /// היא מאות MB מתים על הכונן. לכן קשת נשמרת רק כש-`maxReach(edge.to)`
  /// מגיע ליעד ההוא.
  ///
  /// שני מצבים שהכלל תופס, ושניהם קרו בשטח (ספטמבר 2026, latest=26):
  /// כשאין קשתות אל 26 כלל — כל 411MB של v15–v23 מיותרים; וכשיש — הקשתות
  /// שנכנסות ל-23 הן עדיין מבוי סתום, כי מ-23 אין המשך.
  int _dropUselessPatches({
    required Map<LibraryRelease, Map<String, ReleaseAsset>> neededByRelease,
    required List<MirroredEdge> mirroredEdges,
    required List<({int from, int to})> edges,
    required LibraryRelease carrier,
  }) {
    final carrierVersion = LibraryUpdateDiscovery.releaseVersionOf(carrier);
    final reach = _maxReachByVersion(edges);
    final fullRouteTarget = reach[carrierVersion] ?? carrierVersion;

    var dropped = 0;
    for (final edge in mirroredEdges) {
      if ((reach[edge.to] ?? edge.to) >= fullRouteTarget) continue;
      final needed = neededByRelease[edge.release];
      if (needed == null) continue;
      for (final name in edge.assetNames) {
        if (needed.remove(name) != null) dropped++;
      }
    }
    return dropped;
  }

  int _dropSlowPatches({
    required Map<LibraryRelease, Map<String, ReleaseAsset>> neededByRelease,
    required List<MirroredEdge> mirroredEdges,
    required List<({int from, int to})> edges,
    required List<LibraryRelease> relevant,
    required void Function(String stage)? onStage,
    int? noCreditUpTo,
  }) {
    final strings = LibraryUpdaterMessages.current;
    var dropped = 0;
    for (final edge in mirroredEdges) {
      final carrier = _newestFullDbCarrier(relevant, edge.to);
      final fullBytes = carrier == null ? 0 : _fullDb(carrier)?.size ?? 0;
      if (fullBytes <= 0) continue;
      final fullSeconds = applyTime.fullRouteSeconds(fullBytes);
      final bytes = _plannedEdgeBytes(edge, neededByRelease);
      if (bytes == null) continue;
      final stepSeconds = applyTime.deltaRouteSeconds([bytes]);
      if (!applyTime.isOutOfRange(
        stepSeconds,
        fullSeconds,
        savedDownloadBytes: noCreditUpTo != null && edge.to <= noCreditUpTo
            ? 0
            : fullBytes - bytes,
      )) {
        continue;
      }
      final needed = neededByRelease[edge.release]!;
      var files = 0;
      for (final name in edge.assetNames) {
        if (needed.remove(name) != null) files++;
      }
      dropped += files;
      onStage?.call(strings.exportFullDbInsteadOfSlowPatches(
        files,
        ApplyTimeEstimate.minutesOf(stepSeconds),
        ApplyTimeEstimate.minutesOf(fullSeconds),
        edge.to,
      ));
    }
    if (dropped == 0) return 0;

    edges
      ..clear()
      ..addAll(mirroredEdges
          .where((e) => _plannedEdgeBytes(e, neededByRelease) != null)
          .map((e) => (from: e.from, to: e.to)));
    return dropped;
  }

  /// האם עדיף לוותר על היסטוריית ה-patches ולהחזיק מסד מלא בלבד — ואם כן,
  /// מאיזה release להוריד אותו. `null` = לא נוגעים בכלום.
  ///
  /// **הכלל הוא זמן, לא גודל:** מה שהמשתמש משלם אינו הבייטים שבמראה אלא
  /// כמה זמן העדכון רץ אצלו, ושני המסלולים אינם מתומחרים לפי אותו דבר —
  /// החלת patch משלמת סריקת-hash של **כל** המסד בכל צעד, בנוסף להחלה עצמה.
  /// ראו [ApplyTimeEstimate], שהקבועים בו מכוילים על מדידות אמיתיות.
  ///
  /// **מצב אישי בלבד.** במראה רגילה הפסילה נמדדת על כל קשת בנפרד
  /// ([_dropSlowPatches]); כאן ידועה הגרסה שממנה המשתמש מתחיל, ולכן נמדדת
  /// **השרשרת שלו** על כל צעדיה — היא זו שתרוץ אצלו.
  ///
  /// **הטווח:** מסלול הדלתא אינו חייב להיות מהיר יותר — הוא חוסך ~1.3GB
  /// בהורדה במחשב המקוון, ולכן מותר לו להיות איטי במקצת. הוא מפסיד רק
  /// כשהוא יוצא מהטווח של [ApplyTimeEstimate.isOutOfRange] — גם ביחס וגם
  /// בהפרש מוחלט. בהרחבה שכתבה את המסד מקצה לקצה (ספטמבר 2026, v27) ההחלה
  /// ארכה **64 דקות** מול כשתי דקות של החלפת מסד מלא.
  ///
  /// **אין מסלול קובצי עדכון בכלל** (`routeSeconds: null`) הוא בדיוק הסיבה
  /// להוריד את המסד המלא, למרות שהמצב הזה נבנה כדי לדלג עליו.
  ///
  /// דרישה: המסד המלא חייב להגיע **לבדו** ל-latest, אחרת מחיקת הקשתות
  /// הייתה עוצרת את המראה מתחת לגרסה האחרונה.
  ({LibraryRelease carrier, double? routeSeconds, int fromVersion})?
      _fullDbBeatsPatches(
    List<LibraryRelease> candidates,
    Map<LibraryRelease, Map<String, ReleaseAsset>> neededByRelease,
    List<MirroredEdge> mirroredEdges, {
    required int latestVersion,
    required int fromVersion,
  }) {
    final carrier = _newestFullDbCarrier(candidates, latestVersion);
    if (carrier == null) return null;
    final fullBytes = _fullDb(carrier)!.size;
    if (fullBytes <= 0) return null;

    final route = _cheapestRoute(
      to: latestVersion,
      from: fromVersion,
      neededByRelease: neededByRelease,
      mirroredEdges: mirroredEdges,
    );
    if (route == null) {
      return (carrier: carrier, routeSeconds: null, fromVersion: fromVersion);
    }
    if (!applyTime.isOutOfRange(
      route.seconds,
      applyTime.fullRouteSeconds(fullBytes),
      savedDownloadBytes: fullBytes - route.bytes,
    )) {
      return null;
    }
    return (
      carrier: carrier,
      routeSeconds: route.seconds,
      fromVersion: fromVersion,
    );
  }

  /// מחליף את התוכנית ל**מסד מלא בלבד** ומכריז על כך. `routeSeconds` ריק
  /// פירושו "אין מסלול קובצי עדכון כלל", ואז אין זמן לדווח עליו.
  void _switchToFullDbOnly(
    ({
      LibraryRelease carrier,
      double? routeSeconds,
      int fromVersion
    }) decision, {
    required Map<LibraryRelease, Map<String, ReleaseAsset>> neededByRelease,
    required void Function(String stage)? onStage,
  }) {
    final strings = LibraryUpdaterMessages.current;
    final carrier = decision.carrier;
    final version = LibraryUpdateDiscovery.releaseVersionOf(carrier);
    final route = decision.routeSeconds;
    final files = _keepOnlyFullDb(neededByRelease, carrier);
    onStage?.call(route == null
        ? strings.exportPersonalNeedsFullDb(decision.fromVersion, version)
        : strings.exportFullDbInsteadOfSlowPatches(
            files,
            ApplyTimeEstimate.minutesOf(route),
            ApplyTimeEstimate.minutesOf(
                applyTime.fullRouteSeconds(_fullDb(carrier)!.size)),
            version,
          ));
  }

  /// הגרסה הגבוהה ביותר מבין [releases], 0 כשאין אף אחת.
  int _latestVersionOf(Iterable<LibraryRelease> releases) {
    var latest = 0;
    for (final release in releases) {
      final version = LibraryUpdateDiscovery.releaseVersionOf(release);
      if (version > latest) latest = version;
    }
    return latest;
  }

  /// ה-release הגבוה ביותר מבין [candidates] שנושא מסד מלא — ורק אם הוא
  /// עצמו בגרסה [latestVersion]. מסד שאינו שם היה משאיר את המשתמש מתחתיה
  /// בלי שרשרת שתשלים, אחרי שהקשתות נמחקו.
  LibraryRelease? _newestFullDbCarrier(
    List<LibraryRelease> candidates,
    int latestVersion,
  ) {
    LibraryRelease? newest;
    var newestVersion = -1;
    for (final release in candidates) {
      if (_fullDb(release) == null) continue;
      final version = LibraryUpdateDiscovery.releaseVersionOf(release);
      if (version > newestVersion) {
        newestVersion = version;
        newest = release;
      }
    }
    return newestVersion < latestVersion ? null : newest;
  }

  /// השרשרת הזולה ביותר בקובצי עדכון מ-[from] ל-[to]: זמן בשניות וגודל
  /// הורדה בבייטים. `null` = אין מסלול כזה בתוכנית.
  ({double seconds, int bytes})? _cheapestRoute({
    required int to,
    required int from,
    required Map<LibraryRelease, Map<String, ReleaseAsset>> neededByRelease,
    required List<MirroredEdge> mirroredEdges,
  }) {
    final steps = <({int from, int to, int bytes})>[];
    for (final edge in mirroredEdges) {
      if (edge.to <= edge.from) continue; // רק קדימה
      final bytes = _plannedEdgeBytes(edge, neededByRelease);
      if (bytes == null) continue; // קשת שהוסרה מהתוכנית אינה מסלול
      steps.add((from: edge.from, to: edge.to, bytes: bytes));
    }

    // הקשתות מתקדמות תמיד קדימה, ולכן מעבר על הגרסאות בסדר עולה הוא סדר
    // טופולוגי תקין — אין צורך ב-Dijkstra.
    final best = <int, ({double seconds, int bytes})>{
      from: (seconds: 0, bytes: 0),
    };
    final starts = steps.map((s) => s.from).toSet().toList()..sort();
    for (final version in starts) {
      final base = best[version];
      if (base == null) continue;
      for (final step in steps) {
        if (step.from != version) continue;
        final cost =
            base.seconds + applyTime.intermediateStepSeconds(step.bytes);
        final known = best[step.to];
        if (known == null || cost < known.seconds) {
          best[step.to] = (seconds: cost, bytes: base.bytes + step.bytes);
        }
      }
    }
    final total = best[to];
    if (total == null || to == from) return total;
    // המחיר הקבוע המלא נגבה פעם אחת לשרשרת — ראו ApplyTimeEstimate.
    return (
      seconds: total.seconds + applyTime.chainStartExtraSeconds,
      bytes: total.bytes,
    );
  }

  /// הגודל הדחוס של קשת שנשארה בתוכנית, או `null` אם נכס שלה כבר אינו בה.
  int? _plannedEdgeBytes(
    MirroredEdge edge,
    Map<LibraryRelease, Map<String, ReleaseAsset>> neededByRelease,
  ) {
    final needed = neededByRelease[edge.release];
    if (needed == null) return null;
    var bytes = 0;
    for (final name in edge.assetNames) {
      final asset = needed[name];
      if (asset == null) return null;
      if (asset.size > 0) bytes += asset.size;
    }
    return bytes;
  }

  /// משאיר בתוכנית את המסד המלא של [carrier] בלבד, ומחזיר כמה נכסים ירדו
  /// ממנה. מה שיצא נמחק מהכונן ב-[_pruneStaleAssets] — כולל המסד המלא הישן,
  /// שאין בו יותר צורך.
  int _keepOnlyFullDb(
    Map<LibraryRelease, Map<String, ReleaseAsset>> neededByRelease,
    LibraryRelease carrier,
  ) {
    var dropped = 0;
    for (final needed in neededByRelease.values) {
      dropped += needed.values.where((a) => !a.isFullDbArchive).length;
      needed.clear();
    }
    final full = _fullDb(carrier)!;
    // במצב אישי הנשא כלל אינו ברשימת ה-releases שנבחרו — `personalReleases`
    // מסנן החוצה release שאין בו קובצי עדכון — ולכן הוא נוסף כאן.
    neededByRelease.putIfAbsent(carrier, () => {})[full.name] = full;
    return dropped;
  }

  /// לכל גרסה — הגרסה הגבוהה ביותר שאפשר להגיע אליה ממנה דרך [edges].
  /// רלקסציה חוזרת עד התייצבות; הגרף כאן הוא עשרות קשתות.
  Map<int, int> _maxReachByVersion(List<({int from, int to})> edges) {
    final reach = <int, int>{};
    for (final edge in edges) {
      reach[edge.from] = edge.from > (reach[edge.from] ?? 0)
          ? edge.from
          : (reach[edge.from] ?? edge.from);
      reach[edge.to] = reach[edge.to] ?? edge.to;
    }
    var changed = true;
    while (changed) {
      changed = false;
      for (final edge in edges) {
        if (edge.to <= edge.from) continue; // רק קדימה
        final candidate = reach[edge.to] ?? edge.to;
        if (candidate > (reach[edge.from] ?? edge.from)) {
          reach[edge.from] = candidate;
          changed = true;
        }
      }
    }
    return reach;
  }

  /// האם ה-DB המלא של [release] כבר יושב **שלם** במראה. גודל בלבד: אימות
  /// ה-sha256 ממילא רץ ב-[PatchDownloader], ו-1.1GB מכונן נייד לוקח דקה —
  /// יותר מדי בשביל החלטה שנופלת לפני שהורדה בכלל התחילה.
  bool _isCompleteOnDisk(String assetsRootPath, LibraryRelease release) {
    final asset = _fullDb(release);
    if (asset == null || asset.size <= 0) return false;
    final file = File(p.join(
      assetsRootPath,
      _safeDirName(release.tag),
      asset.name,
    ));
    return file.existsSync() && file.lengthSync() == asset.size;
  }

  /// האם יש מסלול patches מ-[from] ל-[to] מעל [edges]. BFS פשוט — הגרף כאן
  /// הוא עשרות edges לכל היותר, וכל מה שנדרש הוא כן/לא.
  bool _reaches(List<({int from, int to})> edges, int from, int to) {
    if (from == to) return true;
    final visited = <int>{from};
    final queue = <int>[from];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final edge in edges) {
        if (edge.from != current || edge.to <= edge.from) continue;
        if (edge.to == to) return true;
        if (visited.add(edge.to)) queue.add(edge.to);
      }
    }
    return false;
  }

  String _safeDirName(String tag) =>
      tag.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  /// התיקייה שבה יורדים חלקי נכס מפוצל, לצד [assembledPath]. היא נמחקת
  /// אחרי הרכבה מוצלחת, ושורדת כשל — כדי שהריצה הבאה תמשיך ממנה.
  static String splitPartsDir(String assembledPath) => '$assembledPath.parts';

  /// זהות הקובץ המורכב בקובץ הצד: תוכנו, לא מזהה של נכס GitHub כלשהו.
  String _assembledToken(SplitAsset manifest) => 'split:${manifest.sha256}';

  /// מפענח את מניפסט הפיצול של המסד המלא בכל release. מסד מפוצל פגום (או
  /// שנפסל בריצה קודמת) מוסר מה-release; תקין מחליף את המניפסט בנכס המפוענח.
  Future<Map<LibraryRelease, LibraryRelease>> _resolveSplitFullDbs(
    List<LibraryRelease> releases, {
    void Function(String warning)? onWarning,
  }) async {
    final messages = LibraryUpdaterMessages.current;
    final outcomes = await Future.wait([
      for (final release in releases)
        () async {
          final manifestAsset = _fullDb(release)!;
          try {
            final resolved = await _fetchWithRetry(
              manifestAsset,
              (_) => _client.resolveSplitAsset(release, manifestAsset),
            );
            final split = resolved.split!;
            if (_rejectedSplits.contains(_splitKey(split))) {
              return (asset: null, problem: 'sha256 ${split.sha256}');
            }
            return (asset: resolved, problem: null);
          } on FormatException catch (e) {
            return (asset: null, problem: e.message);
          }
        }(),
    ]);
    final replaced = <LibraryRelease, LibraryRelease>{};
    for (final (index, release) in releases.indexed) {
      final outcome = outcomes[index];
      final manifestAsset = _fullDb(release)!;
      final problem = outcome.problem;
      if (problem != null) {
        onWarning
            ?.call(messages.exportSplitFullDbSkipped(release.tag, problem));
      }
      replaced[release] = LibraryRelease(
        tag: release.tag,
        isPrerelease: release.isPrerelease,
        isDraft: release.isDraft,
        publishedAt: release.publishedAt,
        assets: [
          for (final asset in release.assets)
            if (!identical(asset, manifestAsset)) asset,
          ?outcome.asset,
        ],
      );
    }
    return replaced;
  }

  Future<bool> _assembleSplit(
    _SplitJob split, {
    required String destDir,
    void Function(String stage)? onStage,
    bool Function()? isCancelled,
  }) async {
    final strings = LibraryUpdaterMessages.current;
    final manifest = split.manifest;
    final tmp = File(p.join(split.partsDir, '${split.asset.name}.assembling'));
    final hasher = Sha256Stream();
    final corruptParts = <String>[];
    RandomAccessFile? out;
    try {
      out = await tmp.open(mode: FileMode.write);
      var written = 0;
      var lastPercent = -1;
      for (final part in manifest.parts) {
        final partHasher = Sha256Stream();
        try {
          await for (final chunk
              in File(p.join(split.partsDir, part.name)).openRead()) {
            _throwIfCancelled(isCancelled);
            hasher.add(chunk);
            partHasher.add(chunk);
            await out.writeFrom(chunk);
            written += chunk.length;
            final percent = (written * 100 ~/ manifest.size).clamp(0, 100);
            if (percent != lastPercent) {
              lastPercent = percent;
              onStage?.call(strings.exportAssembling(
                  split.release.tag, split.asset.name, percent));
            }
          }
          if (partHasher.close() != part.sha256) corruptParts.add(part.name);
        } finally {
          partHasher.dispose();
        }
      }
      await out.flush();
      await out.close();
      out = null;
      if (corruptParts.isNotEmpty) {
        _deleteQuietly(tmp.path);
        for (final name in corruptParts) {
          final path = p.join(split.partsDir, name);
          _deleteQuietly(path);
          _deleteQuietly(PatchDownloader.resumeSidecarPath(path));
        }
        throw StateError(strings.exportSplitPartCorrupted(
            split.asset.name, corruptParts.join(', ')));
      }
      if (hasher.close() != manifest.sha256) {
        await _deleteDirQuietly(split.partsDir);
        await _rejectSplit(destDir, manifest);
        return false;
      }
      _deleteQuietly(split.dest);
      try {
        await tmp.rename(split.dest);
      } on FileSystemException catch (e) {
        throw StateError(strings.exportAssembledReplaceFailed(
            split.dest, e.osError?.message ?? e.message));
      }
      _downloader.recordVerified(
        destPath: split.dest,
        resumeToken: _assembledToken(manifest),
        sha256: manifest.sha256,
      );
    } finally {
      hasher.dispose();
      try {
        await out?.close();
      } catch (_) {}
    }
    await _deleteDirQuietly(split.partsDir);
    return true;
  }

  String _splitKey(SplitAsset manifest) => [
        manifest.sha256,
        for (final part in manifest.parts) part.sha256,
      ].join(':');

  Set<String> _readRejectedSplits(String destDir) {
    final file = File(p.join(destDir, rejectedSplitsFileName));
    try {
      if (!file.existsSync()) return const {};
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is List ? decoded.whereType<String>().toSet() : const {};
    } catch (_) {
      return const {};
    }
  }

  Future<void> _rejectSplit(
    String destDir,
    SplitAsset manifest,
  ) async {
    _rejectedSplits.add(_splitKey(manifest));
    final path = p.join(destDir, rejectedSplitsFileName);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(
      jsonEncode(_rejectedSplits.toList()..sort()),
      flush: true,
    );
    await tmp.rename(path);
  }

  Future<void> _deleteDirQuietly(String path) async {
    try {
      final dir = Directory(path);
      if (dir.existsSync()) await _deletePreservingLocks(dir);
    } catch (_) {}
  }

  /// Locks keep their inode even after their asset leaves the manifest. This
  /// includes locks for split parts and locks inside obsolete tag directories.
  Future<void> _deletePreservingLocks(FileSystemEntity entity) async {
    if (entity.path.endsWith('.lock')) return;
    if (entity is Directory) {
      await for (final child in entity.list(followLinks: false)) {
        await _deletePreservingLocks(child);
      }
      // Never recursively unlink a lock created after the directory listing.
      try {
        await entity.delete();
      } catch (_) {}
    } else {
      await entity.delete();
    }
  }

  void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// ה-`digest` שמגיע מ-GitHub הוא בצורת `sha256:<hex>`; פורמט אחר (או היעדר
  /// שדה) פירושו "אין hash לאמת מולו", ולא כשל.
  String? _sha256FromDigest(String? digest) {
    const prefix = 'sha256:';
    if (digest == null || !digest.startsWith(prefix)) return null;
    return digest.substring(prefix.length);
  }

  void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled != null && isCancelled()) {
      throw StateError(LibraryUpdaterMessages.current.exportCancelled);
    }
  }

  /// סוגר משאבי HTTP פנימיים אם נוצרו על-ידי המחלקה עצמה. ה-[_downloader]
  /// אינו הבעלים של ה-client (הוא הוזרק אליו), ולכן אין לסגור אותו כאן.
  void dispose() {
    if (_ownsClient) _client.dispose();
    if (_ownsHttpClient) _httpClient.close();
  }
}

/// ה-`decompress` ש-[PatchDownloader] דורש. הייצוא מוריד בלבד ואינו מחלץ,
/// ולכן אם מישהו יקרא בעתיד ל-`downloadAndExtract` מכאן — מוטב שייכשל בקול
/// מלהחזיר `null` שיתפרש כ"חילוץ נכשל".
Future<Uint8List?> _neverDecompress(Uint8List _) => throw UnsupportedError(
      LibraryUpdaterMessages.current.exporterDoesNotExtract,
    );

/// הורדה אחת בתוכנית. חלק של מסד מפוצל אינו נספר כנכס — ההרכבה שלו כן.
typedef _DownloadJob = ({
  LibraryRelease release,
  ReleaseAsset asset,
  String dest,
  String? sha256,
  String? resumeToken,
  bool countsAsAsset,
});

typedef _ManifestFetch = ({
  DeltaManifest? manifest,
  Object? error,
  StackTrace? stack,
});

/// מסד מפוצל בתוכנית: המניפסט שלו, היעד המורכב ותיקיית החלקים.
typedef _SplitJob = ({
  LibraryRelease release,
  ReleaseAsset asset,
  SplitAsset manifest,
  String dest,
  String partsDir,
});

/// קשת שנכנסת למראה: ה-release שנושא אותה, שתי הגרסאות שהיא מחברת, ושמות
/// הנכסים שלה — ה-manifest וקובצי ה-patch. הגדלים נקראים מהתוכנית עצמה, כי
/// קשת שהוסרה ממנה אינה מסלול שקיים במראה.
typedef MirroredEdge = ({
  LibraryRelease release,
  int from,
  int to,
  List<String> assetNames,
});
