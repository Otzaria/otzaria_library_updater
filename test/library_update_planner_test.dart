import 'package:test/test.dart';
import 'package:seforim_library_updater/src/models/delta_manifest.dart';
import 'package:seforim_library_updater/src/models/library_release.dart';
import 'package:seforim_library_updater/src/models/library_update_plan.dart';
import 'package:seforim_library_updater/src/services/library_update_planner.dart';

/// בונה PatchEdge פיקטיבי מ-[from] ל-[to] בגודל דחוס [size].
PatchEdge _edge(
  int from,
  int to, {
  int size = 1000,
  int fromSchema = 1,
  int toSchema = 1,
  int? patchFormat,
}) {
  final file = 'patch-v$from-v$to.db.zst';
  return PatchEdge(
    manifest: DeltaManifest(
      fromVersion: from,
      toVersion: to,
      fromSchemaVersion: fromSchema,
      toSchemaVersion: toSchema,
      patchFormatVersion: patchFormat,
      fromContentHash: 'hash$from',
      toContentHash: 'hash$to',
      patchFiles: [
        PatchFileEntry(
          file: file,
          compression: 'zstd',
          sha256: 'c$from$to',
          size: size,
          uncompressedSha256: 'u$from$to',
          uncompressedSize: size * 2,
        ),
      ],
    ),
    patchFileUrls: {file: 'https://x/$file'},
    manifestUrl: 'https://x/$file.manifest.json',
  );
}

const _fullAsset = ReleaseAsset(
  name: 'seforim.db.zst',
  downloadUrl: 'https://x/seforim.db.zst',
  size: 1197000000,
);

void main() {
  const planner = LibraryUpdatePlanner();

  LibraryUpdatePlan plan({
    required int local,
    required int latest,
    required List<PatchEdge> edges,
    bool hasMeta = true,
    int? localSchema = 1,
    ReleaseAsset? full = _fullAsset,
    String? tag = 'v3',
    int? localDbSize,
    LibraryUpdatePlanner? using,
  }) =>
      (using ?? planner).plan(
        localVersion: local,
        localSchemaVersion: localSchema,
        hasLocalVersionMeta: hasMeta,
        latestVersion: latest,
        edges: edges,
        latestFullDbAsset: full,
        latestReleaseTag: tag,
        localDbSizeBytes: localDbSize,
      );

  group('LibraryUpdatePlanner', () {
    test('local==latest → none', () {
      final p = plan(local: 3, latest: 3, edges: [_edge(1, 2), _edge(2, 3)]);
      expect(p.kind, LibraryUpdatePlanKind.none);
    });

    test('local>latest → none', () {
      final p = plan(local: 5, latest: 3, edges: []);
      expect(p.kind, LibraryUpdatePlanKind.none);
    });

    test('יש edge ישיר 1→3 → בוחר direct (step יחיד)', () {
      final p = plan(
        local: 1,
        latest: 3,
        edges: [_edge(1, 2), _edge(2, 3), _edge(1, 3)],
      );
      expect(p.kind, LibraryUpdatePlanKind.delta);
      expect(p.deltaSteps, hasLength(1));
      expect(p.deltaSteps.single.fromVersion, 1);
      expect(p.deltaSteps.single.toVersion, 3);
    });

    test('רק 1→2 ו-2→3 → בוחר chain בשני שלבים', () {
      final p = plan(local: 1, latest: 3, edges: [_edge(1, 2), _edge(2, 3)]);
      expect(p.kind, LibraryUpdatePlanKind.delta);
      expect(p.deltaSteps, hasLength(2));
      expect(p.deltaSteps[0].toVersion, 2);
      expect(p.deltaSteps[1].toVersion, 3);
    });

    test('חסר 2→3 (רק 1→2, latest=3) → full fallback', () {
      final p = plan(local: 1, latest: 3, edges: [_edge(1, 2)]);
      expect(p.kind, LibraryUpdatePlanKind.fullDownload);
      expect(p.fullDbAsset, _fullAsset);
      expect(p.fullDbReleaseTag, 'v3');
    });

    test('שני chains באותו אורך → בוחר את הזול', () {
      // שני מסלולים באורך 2: 1→2→4 מול 1→3→4. ה-1→3→4 זול יותר.
      final p = plan(
        local: 1,
        latest: 4,
        edges: [
          _edge(1, 2, size: 5000),
          _edge(2, 4, size: 5000),
          _edge(1, 3, size: 1000),
          _edge(3, 4, size: 1000),
        ],
      );
      expect(p.kind, LibraryUpdatePlanKind.delta);
      expect(p.deltaSteps, hasLength(2));
      expect(p.deltaSteps[0].toVersion, 3); // המסלול הזול
      expect(p.totalDownloadSize, 2000);
    });

    test('מסלול ארוך זול מול ישיר יקר → מעדיף ישיר (פחות patches)', () {
      // 1→3 ישיר (יקר) מול 1→2→3 (זול) — מספר patches קובע ראשון.
      final p = plan(
        local: 1,
        latest: 3,
        edges: [
          _edge(1, 3, size: 9000),
          _edge(1, 2, size: 100),
          _edge(2, 3, size: 100),
        ],
      );
      expect(p.deltaSteps, hasLength(1));
      expect(p.deltaSteps.single.toVersion, 3);
    });

    test('חסר schema_meta.db_version → full fallback', () {
      final p = plan(
        local: 0,
        latest: 3,
        edges: [_edge(1, 2), _edge(2, 3)],
        hasMeta: false,
      );
      expect(p.kind, LibraryUpdatePlanKind.fullDownload);
    });

    test('אין מסלול ואין DB מלא → blocked', () {
      final p = plan(
        local: 1,
        latest: 3,
        edges: [_edge(1, 2)],
        full: null,
        tag: null,
      );
      expect(p.kind, LibraryUpdatePlanKind.blocked);
      expect(p.reason, isNotNull);
    });

    test('מתעלם מ-edges אחורה ולא משתמש בהם', () {
      final p = plan(
        local: 1,
        latest: 2,
        edges: [_edge(1, 2), _edge(3, 1), _edge(2, 1)],
      );
      expect(p.kind, LibraryUpdatePlanKind.delta);
      expect(p.deltaSteps, hasLength(1));
      expect(p.deltaSteps.single.toVersion, 2);
    });
    test('תוכנית delta נושאת את ה-DB המלא כ-fallback', () {
      final p = plan(local: 1, latest: 3, edges: [_edge(1, 2), _edge(2, 3)]);
      expect(p.kind, LibraryUpdatePlanKind.delta);
      final fallback = p.toFullDownloadFallback(reason: 'סטיית תוכן');
      expect(fallback, isNotNull);
      expect(fallback!.kind, LibraryUpdatePlanKind.fullDownload);
      expect(fallback.fullDbAsset, _fullAsset);
      expect(fallback.reason, 'סטיית תוכן');
    });

    test('toFullDownloadFallback בלי DB מלא → null', () {
      final p = plan(
        local: 1,
        latest: 3,
        edges: [_edge(1, 2), _edge(2, 3)],
        full: null,
        tag: null,
      );
      expect(p.toFullDownloadFallback(), isNull);
    });
  });

  group('LibraryUpdatePlanner — מודעות לגרסת סכמת patch', () {
    // מדמה לקוח שתומך עד סכמה 3 מול releases שכבר עברו לסכמה 4.
    const oldClient = LibraryUpdatePlanner(
      supportedDbSchemaVersion: 3,
      supportedPatchFormatVersion: 3,
    );

    test('edge שדורש סכמה חדשה מהנתמכת → full fallback עם סיבת עדכון', () {
      final p = oldClient.plan(
        localVersion: 1,
        localSchemaVersion: 3,
        hasLocalVersionMeta: true,
        latestVersion: 2,
        edges: [
          _edge(1, 2, fromSchema: 3, toSchema: 4, patchFormat: 4),
        ],
        latestFullDbAsset: _fullAsset,
        latestReleaseTag: 'v2',
      );
      expect(p.kind, LibraryUpdatePlanKind.fullDownload);
      expect(p.reason, contains('עדכון אפליקציה'));
    });

    test('פורמט artifact חדש נפסל גם כשהמעבר הלוגי נשאר 2→3', () {
      final p = oldClient.plan(
        localVersion: 1,
        localSchemaVersion: 2,
        hasLocalVersionMeta: true,
        latestVersion: 2,
        edges: [
          _edge(
            1,
            2,
            fromSchema: 2,
            toSchema: 3,
            patchFormat: 4,
          ),
        ],
        latestFullDbAsset: _fullAsset,
        latestReleaseTag: 'v2',
      );
      expect(p.kind, LibraryUpdatePlanKind.fullDownload);
      expect(p.reason, contains('עדכון אפליקציה'));
    });

    test('קיים מסלול חלופי בסכמה נתמכת → נבחר delta ולא full', () {
      final p = oldClient.plan(
        localVersion: 1,
        localSchemaVersion: 3,
        hasLocalVersionMeta: true,
        latestVersion: 2,
        edges: [
          _edge(
            1,
            2,
            fromSchema: 3,
            toSchema: 4,
            patchFormat: 4,
            size: 100,
          ),
          _edge(1, 2, fromSchema: 3, toSchema: 3, size: 9000),
        ],
        latestFullDbAsset: _fullAsset,
        latestReleaseTag: 'v2',
      );
      expect(p.kind, LibraryUpdatePlanKind.delta);
      expect(p.deltaSteps.single.manifest.toSchemaVersion, 3);
    });

    test('אין מסלול גם בלי סינון הסכמה → הסיבה הרגילה, לא עדכון אפליקציה', () {
      final p = oldClient.plan(
        localVersion: 1,
        localSchemaVersion: 1,
        hasLocalVersionMeta: true,
        latestVersion: 3,
        edges: [_edge(1, 2, toSchema: 4, patchFormat: 4)],
        latestFullDbAsset: _fullAsset,
        latestReleaseTag: 'v3',
      );
      expect(p.kind, LibraryUpdatePlanKind.fullDownload);
      expect(p.reason, isNot(contains('עדכון אפליקציה')));
    });

    test('הלקוח הנוכחי מקבל edge של סכמה 4 לסכמה 5 בפורמט patch 4', () {
      final p = plan(
        local: 1,
        localSchema: 4,
        latest: 2,
        edges: [
          _edge(1, 2, fromSchema: 4, toSchema: 5, patchFormat: 4),
        ],
      );
      expect(p.kind, LibraryUpdatePlanKind.delta);
    });

    test('לקוח שתומך רק עד סכמה 4 דוחה edge לסכמה 5', () {
      const schema4Client = LibraryUpdatePlanner(
        supportedDbSchemaVersion: 4,
        supportedPatchFormatVersion: 4,
      );
      final p = schema4Client.plan(
        localVersion: 26,
        localSchemaVersion: 4,
        hasLocalVersionMeta: true,
        latestVersion: 27,
        edges: [
          _edge(26, 27, fromSchema: 4, toSchema: 5, patchFormat: 4),
        ],
        latestFullDbAsset: _fullAsset,
        latestReleaseTag: 'v27',
      );
      expect(p.kind, LibraryUpdatePlanKind.fullDownload);
      expect(p.reason, contains('עדכון אפליקציה'));
    });

    test('סכמה נדרשת ואין DB מלא → blocked עם סיבת העדכון', () {
      final p = oldClient.plan(
        localVersion: 1,
        localSchemaVersion: 1,
        hasLocalVersionMeta: true,
        latestVersion: 2,
        edges: [_edge(1, 2, toSchema: 4, patchFormat: 4)],
        latestFullDbAsset: null,
        latestReleaseTag: null,
      );
      expect(p.kind, LibraryUpdatePlanKind.blocked);
      expect(p.reason, contains('עדכון אפליקציה'));
    });

    test('סכמת המקור של ה-edge חייבת להתאים לסכמה המקומית', () {
      final p = plan(
        local: 1,
        localSchema: 4,
        latest: 2,
        edges: [
          _edge(1, 2, fromSchema: 3, toSchema: 4, patchFormat: 4),
        ],
      );
      expect(p.kind, LibraryUpdatePlanKind.fullDownload);
      expect(p.reason, contains('אין מסלול דלתא רציף'));
    });

    test('שרשרת עם מעבר schema לא רציף נפסלת', () {
      final p = plan(
        local: 1,
        localSchema: 3,
        latest: 3,
        edges: [
          _edge(1, 2, fromSchema: 3, toSchema: 4, patchFormat: 4),
          _edge(2, 3, fromSchema: 3, toSchema: 4, patchFormat: 4),
        ],
      );
      expect(p.kind, LibraryUpdatePlanKind.fullDownload);
    });

    test('שרשרת עם מעבר schema רציף נבחרת', () {
      final p = plan(
        local: 1,
        localSchema: 3,
        latest: 3,
        edges: [
          _edge(1, 2, fromSchema: 3, toSchema: 4, patchFormat: 4),
          _edge(2, 3, fromSchema: 4, toSchema: 4, patchFormat: 4),
        ],
      );
      expect(p.kind, LibraryUpdatePlanKind.delta);
      expect(p.deltaSteps, hasLength(2));
    });

    test('סכמה מקומית חסרה ב-DB ישן — הצעד הראשון מותר אך המשך השרשרת רציף',
        () {
      final p = plan(
        local: 1,
        localSchema: null,
        latest: 3,
        edges: [
          _edge(1, 2, fromSchema: 2, toSchema: 3),
          _edge(2, 3, fromSchema: 3, toSchema: 4, patchFormat: 4),
        ],
      );
      expect(p.kind, LibraryUpdatePlanKind.delta);
      expect(p.deltaSteps, hasLength(2));
    });

    test('schema אפס או downgrade אינם edges תקינים', () {
      final p = plan(
        local: 1,
        latest: 2,
        edges: [
          _edge(1, 2, fromSchema: 0, toSchema: 0),
          _edge(1, 2, fromSchema: 4, toSchema: 3),
        ],
      );
      expect(p.kind, LibraryUpdatePlanKind.fullDownload);
    });
  });

  group('עלות ההחלה מול הורדה מלאה', () {
    // _edge(1, 2, size: s) פורס s*2 בייטים.
    const dbSize = 1000000;

    test('דלתא מתחת לסף → delta רגילה, לא כבדה', () {
      final p = plan(
        local: 1,
        latest: 2,
        edges: [_edge(1, 2, size: 100000)], // פרוס 200KB = 20% מה-DB
        localDbSize: dbSize,
      );
      expect(p.kind, LibraryUpdatePlanKind.delta);
      expect(p.isHeavyDelta, isFalse);
      expect(p.heavyDeltaReason, isNull);
      expect(p.deltaUncompressedBytes, 200000);
    });

    test('דלתא מעל הסף עם DB מלא זמין → delta מסומנת ככבדה, עם נימוק', () {
      final p = plan(
        local: 1,
        latest: 2,
        edges: [_edge(1, 2, size: 300000)], // פרוס 600KB = 60% מה-DB
        localDbSize: dbSize,
      );
      expect(p.kind, LibraryUpdatePlanKind.delta);
      expect(p.isHeavyDelta, isTrue);
      expect(p.heavyDeltaReason, contains('0.6 MB'));
      expect(p.heavyDeltaReason, contains('1.0 MB'));
      expect(p.heavyDeltaReason, contains('זמן רב'));
      expect(p.deltaUncompressedBytes, 600000);
      // הצרכן יכול להחליף מסלול — הנתונים להורדה מלאה נשארים זמינים.
      expect(p.fullDbAsset, _fullAsset);
      expect(p.fullDbReleaseTag, 'v3');
    });

    test('גדלים ב-GB מוצגים עם ספרה אחרי הנקודה', () {
      final p = plan(
        local: 1,
        latest: 2,
        edges: [_edge(1, 2, size: 750 * 1024 * 1024)], // פרוס 1.5 GB
        localDbSize: 2 * 1024 * 1024 * 1024,
      );
      expect(p.isHeavyDelta, isTrue);
      expect(p.heavyDeltaReason, contains('1.5 GB'));
      expect(p.heavyDeltaReason, contains('2.0 GB'));
    });

    test('סכימת השלבים נבדקת, לא שלב בודד', () {
      final p = plan(
        local: 1,
        latest: 3,
        edges: [_edge(1, 2, size: 90000), _edge(2, 3, size: 90000)],
        localDbSize: dbSize, // סה"כ פרוס 360KB = 36%
      );
      expect(p.kind, LibraryUpdatePlanKind.delta);
      expect(p.isHeavyDelta, isTrue);
    });

    test('מעל הסף בלי DB מלא → delta כבדה (אזהרה בלבד)', () {
      final p = plan(
        local: 1,
        latest: 2,
        edges: [_edge(1, 2, size: 300000)],
        localDbSize: dbSize,
        full: null,
        tag: null,
      );
      expect(p.kind, LibraryUpdatePlanKind.delta);
      expect(p.isHeavyDelta, isTrue);
      expect(p.fullDbAsset, isNull);
      expect(p.toFullDownloadFallback(), isNull);
    });

    test('גודל DB לא ידוע (null) או 0 → התנהגות ללא שינוי', () {
      for (final size in [null, 0]) {
        final p = plan(
          local: 1,
          latest: 2,
          edges: [_edge(1, 2, size: 300000)],
          localDbSize: size,
        );
        expect(p.kind, LibraryUpdatePlanKind.delta, reason: 'size=$size');
        expect(p.isHeavyDelta, isFalse, reason: 'size=$size');
      }
    });

    test('יחס מותאם משנה את ההכרעה', () {
      final p = plan(
        local: 1,
        latest: 2,
        edges: [_edge(1, 2, size: 100000)], // 20%
        localDbSize: dbSize,
        using: const LibraryUpdatePlanner(maxDeltaUncompressedRatio: 0.1),
      );
      expect(p.kind, LibraryUpdatePlanKind.delta);
      expect(p.isHeavyDelta, isTrue);
    });

    test('תוכנית שאינה דלתא → deltaUncompressedBytes אפס, לא כבדה', () {
      final p = plan(local: 1, latest: 2, edges: []);
      expect(p.kind, LibraryUpdatePlanKind.fullDownload);
      expect(p.deltaUncompressedBytes, 0);
      expect(p.isHeavyDelta, isFalse);
    });

    test('דלתא כבדה עדיין מאפשרת מעבר להורדה מלאה', () {
      final p = plan(
        local: 1,
        latest: 2,
        edges: [_edge(1, 2, size: 300000)],
        localDbSize: dbSize,
      );
      final fb = p.toFullDownloadFallback(reason: 'x');
      expect(fb, isNotNull);
      expect(fb!.kind, LibraryUpdatePlanKind.fullDownload);
      expect(fb.isHeavyDelta, isFalse);
      expect(fb.fullDbAsset, _fullAsset);
    });
  });
}
