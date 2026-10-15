import 'package:equatable/equatable.dart';

import 'delta_manifest.dart';
import 'library_release.dart';
import 'patch_table_spec.dart';

/// קשת בגרף העדכונים: patch בודד מ-[fromVersion] ל-[toVersion], עם ה-manifest
/// שלו וה-URLs להורדת קבצי ה-patch.
class PatchEdge extends Equatable {
  final DeltaManifest manifest;

  /// URL להורדת כל קובץ patch, ממופה לפי שם הקובץ (`patchFiles[].file`).
  final Map<String, String> patchFileUrls;

  /// כתובת ה-manifest עצמו (לתיעוד/דיווח שגיאות).
  final String manifestUrl;

  const PatchEdge({
    required this.manifest,
    required this.patchFileUrls,
    required this.manifestUrl,
  });

  int get fromVersion => manifest.fromVersion;
  int get toVersion => manifest.toVersion;

  /// גודל ההורדה הדחוס הכולל של קשת זו.
  int get compressedSize => manifest.totalCompressedSize;

  /// גודל קבצי ה-patch אחרי פריסה — מדד לעלות ההחלה, לא להורדה.
  int get uncompressedSize =>
      manifest.patchFiles.fold<int>(0, (sum, f) => sum + f.uncompressedSize);

  /// האם שני קצות ה-patch בסכמות DB שיש להן סדר hash.
  bool get hasSupportedSchema =>
      isSupportedSchemaVersion(manifest.fromSchemaVersion) &&
      isSupportedSchemaVersion(manifest.toSchemaVersion);

  /// האם פורמט ה-`patch.db` שהמניפסט מצהיר עליו ניתן להחלה. מניפסט בלי
  /// השדה נבדק ב-preflight של `PatchApplier`.
  bool get hasSupportedPatchFormat {
    final format = manifest.patchFormatVersion;
    return format == null || isSupportedPatchFormatVersion(format);
  }

  /// האם סוג הדחיסה של קבצי ה-patch מוכר.
  bool get hasSupportedCompression => manifest.hasSupportedCompression;

  /// האם אפשר להחיל את הקשת: לא מחסום, וכל שלושת צירי היכולת נתמכים.
  bool get isApplicable =>
      !manifest.fullRebase &&
      hasSupportedSchema &&
      hasSupportedPatchFormat &&
      hasSupportedCompression;

  @override
  List<Object?> get props => [manifest, patchFileUrls, manifestUrl];
}

/// סוג תוכנית העדכון שנבחרה.
enum LibraryUpdatePlanKind {
  /// הספרייה כבר מעודכנת.
  none,

  /// קיים מסלול דלתא בטוח — רשימת patches להחלה.
  delta,

  /// אין מסלול דלתא בטוח — צריך להוריד DB מלא.
  fullDownload,

  /// מצב לא תקין שדורש פעולה ידנית.
  blocked,
}

/// תוצאת התכנון: מה צריך לעשות כדי להביא את הספרייה לגרסה האחרונה.
class LibraryUpdatePlan extends Equatable {
  final LibraryUpdatePlanKind kind;

  /// הגרסה המקומית הנוכחית (או 0 אם לא ידועה).
  final int localVersion;

  /// הגרסה היעד (latest). null אם לא נמצאה.
  final int? targetVersion;

  /// שלבי הדלתא להחלה, בסדר (עבור [LibraryUpdatePlanKind.delta]).
  final List<PatchEdge> deltaSteps;

  /// ה-DB המלא להורדה. בתוכנית fullDownload — היעד להורדה; בתוכנית delta —
  /// fallback ל-[toFullDownloadFallback] אם ההחלה נכשלת על סטיית תוכן.
  final ReleaseAsset? fullDbAsset;

  /// ה-tag של ה-release שממנו יורד ה-DB המלא.
  final String? fullDbReleaseTag;

  /// הסבר קריא — חובה ל-[LibraryUpdatePlanKind.blocked], אופציונלי לאחרים.
  final String? reason;

  /// נימוק לכך שהחלת הדלתא צפויה להיות יקרה מאוד. null בתוכנית דלתא רגילה
  /// ובכל תוכנית שאינה דלתא. הבחירה נשארת של המשתמש — ראו [isHeavyDelta].
  final String? heavyDeltaReason;

  /// תוכנית ההורדה המלאה שמאחורי מסלול דלתא — ההתאוששות כש-patch אינו מתאים
  /// למסד שעל המחשב. null כשאין DB מלא זמין.
  final LibraryUpdatePlan? fullDownloadFallback;

  /// שרשרת ה-patches שרצה מיד אחרי הורדה מלאה שנוחתת על גרסה ישנה מ-latest.
  final LibraryUpdatePlan? followUpDelta;

  const LibraryUpdatePlan._({
    required this.kind,
    required this.localVersion,
    this.targetVersion,
    this.deltaSteps = const [],
    this.fullDbAsset,
    this.fullDbReleaseTag,
    this.reason,
    this.heavyDeltaReason,
    this.fullDownloadFallback,
    this.followUpDelta,
  });

  /// האם זו תוכנית דלתא שהחלתה צפויה להיות ארוכה במיוחד.
  bool get isHeavyDelta => heavyDeltaReason != null;

  /// הספרייה מעודכנת — אין מה לעשות.
  factory LibraryUpdatePlan.none({
    required int localVersion,
    int? targetVersion,
  }) =>
      LibraryUpdatePlan._(
        kind: LibraryUpdatePlanKind.none,
        localVersion: localVersion,
        targetVersion: targetVersion ?? localVersion,
      );

  /// מסלול דלתא — סדרת patches להחלה. [fullDbAsset]/[fullDbReleaseTag]
  /// אופציונליים ומאפשרים [toFullDownloadFallback] אם ההחלה תיכשל.
  factory LibraryUpdatePlan.delta({
    required int localVersion,
    required int targetVersion,
    required List<PatchEdge> steps,
    ReleaseAsset? fullDbAsset,
    String? fullDbReleaseTag,
    String? heavyDeltaReason,
    String? reason,
    LibraryUpdatePlan? fullDownloadFallback,
  }) =>
      LibraryUpdatePlan._(
        kind: LibraryUpdatePlanKind.delta,
        localVersion: localVersion,
        targetVersion: targetVersion,
        deltaSteps: List.unmodifiable(steps),
        fullDbAsset: fullDbAsset,
        fullDbReleaseTag: fullDbReleaseTag,
        reason: reason,
        heavyDeltaReason: heavyDeltaReason,
        fullDownloadFallback: fullDownloadFallback,
      );

  /// מסלול הורדה מלאה.
  factory LibraryUpdatePlan.fullDownload({
    required int localVersion,
    int? targetVersion,
    required ReleaseAsset asset,
    required String releaseTag,
    String? reason,
    LibraryUpdatePlan? followUpDelta,
  }) =>
      LibraryUpdatePlan._(
        kind: LibraryUpdatePlanKind.fullDownload,
        localVersion: localVersion,
        targetVersion: targetVersion,
        fullDbAsset: asset,
        fullDbReleaseTag: releaseTag,
        reason: reason,
        followUpDelta: followUpDelta,
      );

  /// מצב חסום — דורש פעולה ידנית.
  factory LibraryUpdatePlan.blocked({
    required int localVersion,
    int? targetVersion,
    required String reason,
  }) =>
      LibraryUpdatePlan._(
        kind: LibraryUpdatePlanKind.blocked,
        localVersion: localVersion,
        targetVersion: targetVersion,
        reason: reason,
      );

  /// ממיר תוכנית דלתא לתוכנית הורדה מלאה — fallback כשההחלה נכשלת על סטיית
  /// תוכן. מחזיר null אם אין DB מלא זמין (ואז נשארים במסך השגיאה).
  LibraryUpdatePlan? toFullDownloadFallback({String? reason}) {
    final asset = fullDbAsset;
    final tag = fullDbReleaseTag;
    if (asset == null || tag == null) return null;
    return LibraryUpdatePlan.fullDownload(
      localVersion: localVersion,
      targetVersion: targetVersion,
      asset: asset,
      releaseTag: tag,
      reason: reason,
    );
  }

  /// הגרסה שהמסד יגיע אליה בסוף התוכנית, כולל [followUpDelta].
  int? get finalTargetVersion => followUpDelta?.targetVersion ?? targetVersion;

  /// גודל ההורדה הכולל בבייטים (דחוס) — לתצוגה למשתמש.
  int get totalDownloadSize {
    switch (kind) {
      case LibraryUpdatePlanKind.delta:
        return deltaSteps.fold<int>(0, (sum, e) => sum + e.compressedSize);
      case LibraryUpdatePlanKind.fullDownload:
        return (fullDbAsset?.size ?? 0) +
            (followUpDelta?.totalDownloadSize ?? 0);
      case LibraryUpdatePlanKind.none:
      case LibraryUpdatePlanKind.blocked:
        return 0;
    }
  }

  /// סך גודל ה-patches אחרי פריסה — הערכת עלות ההחלה. 0 בתוכנית שאינה דלתא.
  int get deltaUncompressedBytes =>
      deltaSteps.fold<int>(0, (sum, e) => sum + e.uncompressedSize);

  @override
  List<Object?> get props => [
        kind,
        localVersion,
        targetVersion,
        deltaSteps,
        fullDbAsset,
        fullDbReleaseTag,
        reason,
        heavyDeltaReason,
        fullDownloadFallback,
        followUpDelta,
      ];
}
