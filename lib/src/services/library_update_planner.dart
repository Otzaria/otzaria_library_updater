import '../models/library_release.dart';
import '../models/library_update_plan.dart';
import '../models/patch_table_spec.dart';

/// היחס המרבי בין גודל הדלתא הפרוס לגודל ה-DB המקומי שעדיין משתלם.
/// החלת upserts על DB מאונדקס עולה פי כמה מכתיבה סדרתית של קובץ, ולכן דלתא
/// שגדולה מרבע ה-DB תיושם לאט יותר משיימשך להוריד DB מלא ולפרוס אותו.
/// חייב להישאר לפחות פי 2 קטן מגארד המחולל (PatchSizeGuard, 0.5) — כדי
/// שהלקוח תמיד יספיק לשאול את המשתמש לפני שהשרת כופה הורדה מלאה.
const double kDefaultMaxDeltaUncompressedRatio = 0.25;

/// בוחר את תוכנית העדכון: מסלול דלתא, הורדה מלאה, none, או blocked.
///
/// פונקציה טהורה — אינה ניגשת לרשת או ל-DB. מקבלת את כל המידע שכבר נאסף
/// (גרסה מקומית, edges, ו-DB מלא ל-fallback) ומחזירה [LibraryUpdatePlan].
class LibraryUpdatePlanner {
  /// סכמת ה-DB הגבוהה ביותר שהצרכן יודע לקרוא ולאמת; ברירת המחדל
  /// [kDefaultConsumerDbSchemaVersion], לכל היותר [kSupportedDbSchemaVersion].
  final int supportedDbSchemaVersion;

  /// גרסת פורמט patch.db הגבוהה ביותר שה-applier בצרכן יודע להחיל.
  final int supportedPatchFormatVersion;

  /// ראו [kDefaultMaxDeltaUncompressedRatio].
  final double maxDeltaUncompressedRatio;

  const LibraryUpdatePlanner({
    this.supportedDbSchemaVersion = kDefaultConsumerDbSchemaVersion,
    this.supportedPatchFormatVersion = kSupportedPatchFormatVersion,
    this.maxDeltaUncompressedRatio = kDefaultMaxDeltaUncompressedRatio,
  })  : assert(supportedDbSchemaVersion >= 1),
        assert(supportedDbSchemaVersion <= kSupportedDbSchemaVersion),
        assert(supportedPatchFormatVersion >= 1),
        assert(maxDeltaUncompressedRatio > 0);

  /// בונה תוכנית עדכון.
  ///
  /// [localVersion] — גרסת ה-DB המקומי.
  /// [localSchemaVersion] — חובה להעביר את `LocalDbVersion.schemaVersion`;
  /// הערך עצמו nullable כאשר `db_schema_version` חסר ב-DB ישן.
  /// [hasLocalVersionMeta] — `false` אם `schema_meta.db_version` חסר.
  /// [latestVersion] — הגרסה הגבוהה ביותר הזמינה ב-releases.
  /// [edges] — כל ה-patches הזמינים.
  /// [latestFullDbAsset] / [latestReleaseTag] — ה-DB המלא ל-fallback.
  /// [localDbSizeBytes] — גודל ה-DB המקומי; כשהוא ידוע, מסלול דלתא שעלות
  /// ההחלה שלו גבוהה מדי מסומן ב-`isHeavyDelta` (ראו
  /// [maxDeltaUncompressedRatio]) — הבחירה נשארת של המשתמש.
  LibraryUpdatePlan plan({
    required int localVersion,
    required int? localSchemaVersion,
    required bool hasLocalVersionMeta,
    required int latestVersion,
    required List<PatchEdge> edges,
    ReleaseAsset? latestFullDbAsset,
    String? latestReleaseTag,
    int? localDbSizeBytes,
  }) {
    // DB מלא בסכמה שהצרכן אינו קורא לעולם אינו fallback, גם כשהועבר לכאן.
    final schema = latestFullDbAsset?.fullDbSchemaVersion;
    final fullDbAsset = schema == null || schema <= supportedDbSchemaVersion
        ? latestFullDbAsset
        : null;
    if (!hasLocalVersionMeta) {
      return _fullOrBlocked(
        localVersion: localVersion,
        latestVersion: latestVersion,
        asset: fullDbAsset,
        tag: latestReleaseTag,
        reason: 'גרסת ה-DB המקומי אינה ידועה (חסר schema_meta.db_version)',
      );
    }

    if (localVersion >= latestVersion) {
      return LibraryUpdatePlan.none(
        localVersion: localVersion,
        targetVersion: latestVersion,
      );
    }

    // חוזה ה-DB וחוזה פורמט ה-patch נבדקים בנפרד. מניפסטים היסטוריים אינם
    // כוללים patchFormatVersion; בהם ה-applier נשאר שער ה-preflight.
    // מחסום סכמה (fullRebase) אינו patch אמיתי — לעולם לא שלב במסלול.
    final validEdges = edges.where((e) {
      if (e.manifest.fullRebase) return false;
      final fromSchema = e.manifest.fromSchemaVersion;
      final toSchema = e.manifest.toSchemaVersion;
      final patchFormat = e.manifest.patchFormatVersion;
      return fromSchema >= 1 &&
          toSchema >= fromSchema &&
          (toSchema < 4 || patchFormat != null) &&
          (patchFormat == null || patchFormat >= 1);
    }).toList();
    final supportedEdges = validEdges
        .where((e) =>
            e.manifest.fromSchemaVersion <= supportedDbSchemaVersion &&
            e.manifest.toSchemaVersion <= supportedDbSchemaVersion &&
            (e.manifest.patchFormatVersion == null ||
                e.manifest.patchFormatVersion! <= supportedPatchFormatVersion))
        .toList();

    final path = _findBestPath(
      supportedEdges,
      localVersion,
      latestVersion,
      fromSchemaVersion: localSchemaVersion,
    );
    if (path != null && path.isNotEmpty) {
      final deltaBytes =
          path.fold<int>(0, (sum, e) => sum + e.uncompressedSize);
      final dbBytes = (localDbSizeBytes != null && localDbSizeBytes > 0)
          ? localDbSizeBytes
          : null;
      final isHeavy =
          dbBytes != null && deltaBytes > dbBytes * maxDeltaUncompressedRatio;
      return LibraryUpdatePlan.delta(
        localVersion: localVersion,
        targetVersion: latestVersion,
        steps: path,
        fullDbAsset: fullDbAsset,
        fullDbReleaseTag: latestReleaseTag,
        heavyDeltaReason: isHeavy
            ? 'מסלול הדלתא פורס ${_size(deltaBytes)} לעומת DB מקומי בגודל '
                '${_size(dbBytes)}, ושלב ההחלה עלול להימשך זמן רב'
            : null,
      );
    }

    final barrier = _barrierFrom(edges, localVersion, localSchemaVersion);
    if (barrier != null) {
      final toSchema = barrier.manifest.toSchemaVersion;
      return _fullOrBlocked(
        localVersion: localVersion,
        latestVersion: latestVersion,
        asset: fullDbAsset,
        tag: latestReleaseTag,
        reason: toSchema <= supportedDbSchemaVersion
            ? 'הספרייה עברה לסכמת DB $toSchema; המעבר מחייב הורדה מלאה'
            : 'הספרייה עברה לסכמת DB $toSchema, חדשה מהנתמך '
                '(DB $supportedDbSchemaVersion) — נדרש עדכון אפליקציה',
      );
    }

    // מבחין בין "אין מסלול בכלל" ל"יש מסלול אך הוא דורש עדכון אפליקציה" —
    // ההודעה השנייה אומרת למשתמש מה יתקן את זה לצמיתות.
    final blockedByCapability = supportedEdges.length != validEdges.length &&
        _findBestPath(
              validEdges,
              localVersion,
              latestVersion,
              fromSchemaVersion: localSchemaVersion,
            ) !=
            null;
    return _fullOrBlocked(
      localVersion: localVersion,
      latestVersion: latestVersion,
      asset: fullDbAsset,
      tag: latestReleaseTag,
      reason: blockedByCapability
          ? 'מסלול הדלתא לגרסה $latestVersion דורש סכמת DB או פורמט patch '
              'חדשים מהנתמך (DB $supportedDbSchemaVersion, '
              'patch $supportedPatchFormatVersion) — נדרש עדכון אפליקציה'
          : 'אין מסלול דלתא רציף מגרסה $localVersion לגרסה $latestVersion',
    );
  }

  /// מחסום הסכמה שיוצא מהמצב המקומי, עם סכמת היעד הגבוהה ביותר; null אם אין.
  /// מחסום מסכמה אחרת תקף כל עוד הסכמה המקומית נמוכה מסכמת היעד שלו.
  PatchEdge? _barrierFrom(
    List<PatchEdge> edges,
    int localVersion,
    int? localSchemaVersion,
  ) {
    PatchEdge? best;
    for (final edge in edges) {
      final m = edge.manifest;
      if (!m.fullRebase || m.fromVersion != localVersion) continue;
      if (m.toVersion <= localVersion) continue;
      if (localSchemaVersion != null &&
          m.fromSchemaVersion != localSchemaVersion &&
          localSchemaVersion >= m.toSchemaVersion) {
        continue;
      }
      if (best == null || m.toSchemaVersion > best.manifest.toSchemaVersion) {
        best = edge;
      }
    }
    return best;
  }

  /// גודל קריא בטקסט LTR-בטוח: GB מעל ג'יגה-בייט אחד, אחרת MB.
  String _size(int bytes) {
    const mb = 1024 * 1024;
    if (bytes >= 1024 * mb) {
      return '${(bytes / (1024 * mb)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / mb).toStringAsFixed(1)} MB';
  }

  LibraryUpdatePlan _fullOrBlocked({
    required int localVersion,
    required int latestVersion,
    required ReleaseAsset? asset,
    required String? tag,
    required String reason,
  }) {
    if (asset != null && tag != null) {
      return LibraryUpdatePlan.fullDownload(
        localVersion: localVersion,
        targetVersion: latestVersion,
        asset: asset,
        releaseTag: tag,
        reason: reason,
      );
    }
    return LibraryUpdatePlan.blocked(
      localVersion: localVersion,
      targetVersion: latestVersion,
      reason: '$reason, ואין DB מלא זמין להורדה',
    );
  }

  /// מוצא מסלול ממזער (מספר patches, ואז גודל דחוס כולל) מ-[from] ל-[to].
  /// מחזיר null אם אין מסלול. Dijkstra על גרף ה-edges (DAG עולה).
  List<PatchEdge>? _findBestPath(
    List<PatchEdge> edges,
    int from,
    int to, {
    int? fromSchemaVersion,
  }) {
    final adjacency = <int, List<PatchEdge>>{};
    for (final edge in edges) {
      if (edge.toVersion <= edge.fromVersion) continue; // רק קדימה
      adjacency.putIfAbsent(edge.fromVersion, () => []).add(edge);
    }

    final start = (version: from, schema: fromSchemaVersion);
    final best = <({int version, int? schema}), _Reach>{
      start: const _Reach(0, 0, []),
    };
    final visited = <({int version, int? schema})>{};

    while (true) {
      ({int version, int? schema})? current;
      _Reach? currentReach;
      for (final entry in best.entries) {
        if (visited.contains(entry.key)) continue;
        if (currentReach == null || entry.value.isBetterThan(currentReach)) {
          current = entry.key;
          currentReach = entry.value;
        }
      }
      if (current == null || currentReach == null) break;
      if (current.version == to) return currentReach.path;
      visited.add(current);

      for (final edge in adjacency[current.version] ?? const <PatchEdge>[]) {
        if (current.schema != null &&
            edge.manifest.fromSchemaVersion != current.schema) {
          continue;
        }
        final next = (
          version: edge.toVersion,
          schema: edge.manifest.toSchemaVersion,
        );
        if (visited.contains(next)) continue;
        final candidate = _Reach(
          currentReach.hops + 1,
          currentReach.size + edge.compressedSize,
          [...currentReach.path, edge],
        );
        final existing = best[next];
        if (existing == null || candidate.isBetterThan(existing)) {
          best[next] = candidate;
        }
      }
    }
    return null;
  }
}

/// עלות הגעה לגרסה: מספר patches (עיקרי) וגודל דחוס כולל (משני).
class _Reach {
  final int hops;
  final int size;
  final List<PatchEdge> path;
  const _Reach(this.hops, this.size, this.path);

  bool isBetterThan(_Reach other) {
    if (hops != other.hops) return hops < other.hops;
    return size < other.size;
  }
}
