import '../messages/library_updater_messages.dart';
import '../models/delta_manifest.dart';
import '../models/library_release.dart';
import '../models/library_update_plan.dart';
import '../models/patch_table_spec.dart';
import 'apply_time_estimate.dart';

/// מתכנן למסלול המראה (offline): אותו פלט כמו [LibraryUpdatePlanner], אבל
/// כששני המסלולים כבר על הכונן ומגיעים לאותה גרסה נבחר המהיר
/// ([ApplyTimeEstimate]), שרשרת שנעצרת מתחת ל-latest היא עדיין דלתא, ו-DB מלא
/// ישן מושלם ב-[LibraryUpdatePlan.followUpDelta].
class OfflineLibraryUpdatePlanner {
  const OfflineLibraryUpdatePlanner(
      {this.applyTime = const ApplyTimeEstimate()});

  /// אומדן זמן העדכון **על המחשב הזה**, שלפיו נבחר בין שרשרת קובצי עדכון
  /// לבין החלפת המסד המלא כששתיהן מגיעות לאותה גרסה. ניתן להזרקה לבדיקות.
  final ApplyTimeEstimate applyTime;

  /// אילו מ-[edges] (לפי מיקום) [plan] בוחר לגרסה מקומית כלשהי — כולל מחשב
  /// בלי גרסה ידועה — כשמסד מלא בגודל [fullDbBytes] בגרסה [fullDbVersion] יושב
  /// לצידן. `null` = אין מה להסיר: כולן נבחרות, או שהסרת השאר הייתה משנה את
  /// סוג התוכנית או את הגרסה שאליה היא מגיעה עבור גרסה כלשהי.
  ///
  /// מראה רגילה ממילא נושאת את המסד המלא, ולכן קשת שאינה כאן היא בייטים
  /// מתים על הכונן. המייצא והחסם שמוצג לפני ההורדה קוראים לאותה פונקציה.
  Set<int>? pickedEdges({
    required List<({int from, int to, int bytes})> edges,
    required int fullDbBytes,
    required int fullDbVersion,
  }) {
    if (edges.isEmpty || fullDbBytes <= 0) return null;
    final patchEdges = [
      for (final (i, e) in edges.indexed)
        PatchEdge(
          manifest: DeltaManifest(
            fromVersion: e.from,
            toVersion: e.to,
            fromSchemaVersion: kSupportedDbSchemaVersion,
            toSchemaVersion: kSupportedDbSchemaVersion,
            fromContentHash: '',
            toContentHash: '',
            patchFiles: [
              PatchFileEntry(
                file: '$i',
                compression: 'zstd',
                sha256: '',
                size: e.bytes,
                uncompressedSha256: '',
                uncompressedSize: 0,
              ),
            ],
          ),
          patchFileUrls: const {},
          manifestUrl: '$i',
        ),
    ];
    var latest = fullDbVersion;
    var lowest = fullDbVersion;
    for (final e in edges) {
      if (e.to > latest) latest = e.to;
      if (e.from < lowest) lowest = e.from;
    }
    // דלתא יכולה להתחיל רק בגרסת מקור של קשת. בשאר הגרסאות ההחלטה היא
    // בין מסד מלא לחסימה, לפי מיקומן ביחס ליעד המסלול המלא — גרסת המסד
    // או יעד של קשת. לכן מספיק לבדוק את הגבולות האלה ונציג בכל רווח
    // ביניהם, גם כשהמספור דליל מאוד. אין צורך בתוכנית לכל מספר גרסה.
    final firstVersion = lowest > 0 ? lowest - 1 : 0;
    final localVersions = <int>{
      firstVersion,
      fullDbVersion - 1,
      fullDbVersion,
      for (final e in edges) ...[e.from - 1, e.from, e.to - 1, e.to],
    }.where((v) => v >= firstVersion && v < latest).toList()..sort();
    final full = ReleaseAsset(name: 'full', downloadUrl: '', size: fullDbBytes);
    List<LibraryUpdatePlan> plansWith(List<PatchEdge> available) => [
          for (final v in localVersions)
            plan(
              localVersion: v,
              hasLocalVersionMeta: true,
              latestVersion: latest,
              edges: available,
              latestFullDbAsset: full,
              fullDbReleaseTag: 'full',
              latestFullDbVersion: fullDbVersion,
            ),
          plan(
            localVersion: 0,
            hasLocalVersionMeta: false,
            latestVersion: latest,
            edges: available,
            latestFullDbAsset: full,
            fullDbReleaseTag: 'full',
            latestFullDbVersion: fullDbVersion,
          ),
        ];

    final before = plansWith(patchEdges);
    final picked = <PatchEdge>{};
    void collect(LibraryUpdatePlan? p) {
      if (p == null) return;
      picked.addAll(p.deltaSteps);
      collect(p.fullDownloadFallback);
      collect(p.followUpDelta);
    }

    before.forEach(collect);
    if (picked.length == patchEdges.length) return null;

    String outcome(LibraryUpdatePlan p) => '${p.kind.name}>${p.targetVersion}'
        '+${p.followUpDelta?.targetVersion}'
        '|${p.fullDownloadFallback?.targetVersion}';
    final after = plansWith(patchEdges.where(picked.contains).toList());
    for (var i = 0; i < before.length; i++) {
      if (outcome(before[i]) != outcome(after[i])) return null;
    }
    return {
      for (final (i, e) in patchEdges.indexed)
        if (picked.contains(e)) i,
    };
  }

  /// בונה תוכנית עדכון.
  ///
  /// [localVersion] — גרסת ה-DB המקומי.
  /// [hasLocalVersionMeta] — `false` אם `schema_meta.db_version` חסר.
  /// [latestVersion] — הגרסה הגבוהה ביותר הזמינה ב-releases.
  /// [edges] — כל ה-patches הזמינים.
  /// [latestFullDbAsset] / [fullDbReleaseTag] — ה-DB המלא ל-fallback.
  /// [latestFullDbVersion] — הגרסה ש**הנכס הזה** מביא; ראו
  /// [OfflineLibraryDiscoveryResult.latestFullDbVersion].
  /// [latestContentTag] — ה-release החדש ביותר, זה שהתוכן העדכני מגיע ממנו.
  /// [localReleaseTag] / [localReleaseTagVersion] — ה-release שממנו הגיע ה-DB
  /// המקומי והגרסה שנרשמה איתו, אם ידועים. ראו [_isContentRefresh].
  /// [blockingSchemaVersion] — סכמה שנראתה ב-releases ואיננו יודעים להחיל
  /// (`OfflineLibraryDiscoveryResult.blockingSchemaVersion`). לתוכנית עצמה אין בה
  /// צורך — ה-edges שלה כבר סוננו — אלא רק להסבר שמוצג למשתמש.
  /// [blockingPatchFormatVersion] — אותו דבר על ציר פורמט ה-`patch.db`;
  /// משמש רק כשהסכמה עצמה מוכרת.
  LibraryUpdatePlan plan({
    required int localVersion,
    required bool hasLocalVersionMeta,
    required int latestVersion,
    required List<PatchEdge> edges,
    ReleaseAsset? latestFullDbAsset,
    String? fullDbReleaseTag,
    int? latestFullDbVersion,
    String? latestContentTag,
    String? localReleaseTag,
    int? localReleaseTagVersion,
    int? blockingSchemaVersion,
    int? blockingPatchFormatVersion,
    String? localVersionUnknownReason,
  }) {
    final fullTargetVersion = latestFullDbVersion ?? latestVersion;
    final followUp = _followUpDelta(
      edges,
      fullTargetVersion,
      latestVersion,
      blockingSchemaVersion,
      blockingPatchFormatVersion,
    );

    if (!hasLocalVersionMeta) {
      return _fullOrBlocked(
        localVersion: localVersion,
        latestVersion: latestVersion,
        fullTargetVersion: fullTargetVersion,
        followUp: followUp,
        asset: latestFullDbAsset,
        tag: fullDbReleaseTag,
        reason: localVersionUnknownReason ??
            LibraryUpdaterMessages.current.planLocalVersionUnknown,
        requireProgress: false,
      );
    }

    if (localVersion >= latestVersion) {
      if (latestFullDbAsset != null &&
          fullDbReleaseTag != null &&
          fullDbReleaseTag == latestContentTag &&
          _isContentRefresh(
            localTag: localReleaseTag,
            localTagVersion: localReleaseTagVersion,
            latestTag: latestContentTag,
            localVersion: localVersion,
          ) &&
          (followUp?.targetVersion ?? fullTargetVersion) >= localVersion) {
        return LibraryUpdatePlan.fullDownload(
          localVersion: localVersion,
          targetVersion: fullTargetVersion,
          asset: latestFullDbAsset,
          releaseTag: fullDbReleaseTag,
          followUpDelta: followUp,
          reason: LibraryUpdaterMessages.current
              .planContentChangedWithoutVersionBump(fullDbReleaseTag),
        );
      }
      return LibraryUpdatePlan.none(
        localVersion: localVersion,
        targetVersion: latestVersion,
      );
    }

    final path = _bestReachablePath(edges, localVersion, latestVersion);
    final deltaTarget = path == null ? localVersion : path.last.toVersion;

    final fullAvailable = latestFullDbAsset != null && fullDbReleaseTag != null;
    final fullRouteTarget = fullAvailable
        ? (followUp?.targetVersion ?? fullTargetVersion)
        : localVersion;

    if (fullAvailable &&
        path != null &&
        path.isNotEmpty &&
        deltaTarget == fullRouteTarget &&
        fullRouteTarget > localVersion &&
        latestFullDbAsset.size > 0) {
      final deltaSeconds =
          applyTime.deltaRouteSeconds(path.map((e) => e.compressedSize));
      final fullSeconds = applyTime.fullRouteSeconds(latestFullDbAsset.size) +
          applyTime.deltaRouteSeconds(
              followUp?.deltaSteps.map((e) => e.compressedSize) ?? const []);
      if (applyTime.isOutOfRange(deltaSeconds, fullSeconds)) {
        return LibraryUpdatePlan.fullDownload(
          localVersion: localVersion,
          targetVersion: fullTargetVersion,
          asset: latestFullDbAsset,
          releaseTag: fullDbReleaseTag,
          reason: LibraryUpdaterMessages.current.planFullDbFasterThanPatches(
            path.length,
            ApplyTimeEstimate.minutesOf(deltaSeconds),
            ApplyTimeEstimate.minutesOf(fullSeconds),
          ),
          followUpDelta: followUp,
        );
      }
    }

    if (path != null && path.isNotEmpty && deltaTarget >= fullRouteTarget) {
      return LibraryUpdatePlan.delta(
        localVersion: localVersion,
        targetVersion: deltaTarget,
        steps: path,
        reason: deltaTarget >= latestVersion
            ? null
            : _partialStopReason(
                deltaTarget,
                latestVersion,
                blockingSchemaVersion,
                blockingPatchFormatVersion,
              ),
        fullDownloadFallback: latestFullDbAsset != null &&
                fullDbReleaseTag != null &&
                fullRouteTarget > localVersion
            ? LibraryUpdatePlan.fullDownload(
                localVersion: localVersion,
                targetVersion: fullTargetVersion,
                asset: latestFullDbAsset,
                releaseTag: fullDbReleaseTag,
                followUpDelta: followUp,
              )
            : null,
      );
    }

    final strings = LibraryUpdaterMessages.current;
    return _fullOrBlocked(
      localVersion: localVersion,
      latestVersion: latestVersion,
      fullTargetVersion: fullTargetVersion,
      followUp: followUp,
      asset: latestFullDbAsset,
      tag: fullDbReleaseTag,
      reason: blockingSchemaVersion != null
          ? strings.planPatchSchemaTooNew(blockingSchemaVersion, latestVersion)
          : blockingPatchFormatVersion != null
              ? strings.planPatchFormatTooNew(
                  blockingPatchFormatVersion,
                  latestVersion,
                )
              : strings.planNoDeltaRoute(localVersion, latestVersion),
      requireProgress: true,
      blockingSchemaVersion: blockingSchemaVersion,
      blockingPatchFormatVersion: blockingPatchFormatVersion,
    );
  }

  /// ההסבר לשרשרת שנעצרה מתחת ל-latest: מעבר סכמה, פורמט patch שאיננו
  /// מכירים, או פשוט חוסר קשתות. הסכמה קודמת — היא מה שמשתנה בפועל.
  String _partialStopReason(
    int reachedVersion,
    int latestVersion,
    int? blockingSchemaVersion,
    int? blockingPatchFormatVersion,
  ) {
    final strings = LibraryUpdaterMessages.current;
    if (blockingSchemaVersion != null) {
      return strings.planPartialDeltaSchemaStop(
        reachedVersion,
        latestVersion,
        blockingSchemaVersion,
      );
    }
    if (blockingPatchFormatVersion != null) {
      return strings.planPartialDeltaFormatStop(
        reachedVersion,
        latestVersion,
        blockingPatchFormatVersion,
      );
    }
    return strings.planNoDeltaRoute(reachedVersion, latestVersion);
  }

  /// האם המסד המקומי בגרסה האחרונה אבל מ-release **אחר** — כלומר התוכן
  /// עודכן בלי להעלות את `db_version`, מה שקורה בפועל ב-SeforimLibrary.
  ///
  /// דורש שנדע מאיזה release ה-DB המקומי הגיע: `null` פירושו DB שלא הותקן
  /// דרך הלאנצ'ר הזה, ואז אין דרך להשוות — ומוטב לדווח "מעודכן" מלהציע
  /// הורדה מלאה של ~1GB בכל פתיחה על סמך ניחוש.
  ///
  /// [localTagVersion] חייבת להתאים ל-[localVersion]: רישום שנעשה בגרסה אחרת
  /// אינו מעיד על התוכן שבמסד עכשיו (מסד שאוצריא עדכנה בעצמה, או מחשב אחר
  /// שכתב את הרישום על הכונן), והשוואה כזו הכריזה על "עדכון" מגרסה X לאותה
  /// גרסה X — ~1.4GB על לא כלום.
  bool _isContentRefresh({
    required String? localTag,
    required int? localTagVersion,
    required String? latestTag,
    required int localVersion,
  }) =>
      localTag != null &&
      latestTag != null &&
      localTagVersion == localVersion &&
      localTag != latestTag;

  LibraryUpdatePlan? _followUpDelta(
    List<PatchEdge> edges,
    int fullTargetVersion,
    int latestVersion,
    int? blockingSchemaVersion,
    int? blockingPatchFormatVersion,
  ) {
    if (fullTargetVersion >= latestVersion) return null;
    final path = _bestReachablePath(edges, fullTargetVersion, latestVersion);
    if (path == null) return null;
    final reached = path.last.toVersion;
    return LibraryUpdatePlan.delta(
      localVersion: fullTargetVersion,
      targetVersion: reached,
      steps: path,
      reason: reached >= latestVersion
          ? null
          : _partialStopReason(
              reached,
              latestVersion,
              blockingSchemaVersion,
              blockingPatchFormatVersion,
            ),
    );
  }

  LibraryUpdatePlan _fullOrBlocked({
    required int localVersion,
    required int latestVersion,
    required int fullTargetVersion,
    required LibraryUpdatePlan? followUp,
    required ReleaseAsset? asset,
    required String? tag,
    required String reason,
    required bool requireProgress,
    int? blockingSchemaVersion,
    int? blockingPatchFormatVersion,
  }) {
    final strings = LibraryUpdaterMessages.current;
    if (asset != null && tag != null) {
      final finalTarget = followUp?.targetVersion ?? fullTargetVersion;
      if (requireProgress && finalTarget <= localVersion) {
        return LibraryUpdatePlan.blocked(
          localVersion: localVersion,
          targetVersion: latestVersion,
          reason: blockingSchemaVersion != null
              ? strings.planPatchSchemaTooNew(
                  blockingSchemaVersion,
                  latestVersion,
                )
              : strings.planFullDbWouldNotProgress(
                  finalTarget,
                  localVersion,
                  latestVersion,
                ),
          blockReason: _blockReasonFor(
            blockingSchemaVersion,
            blockingPatchFormatVersion,
          ),
        );
      }
      return LibraryUpdatePlan.fullDownload(
        localVersion: localVersion,
        targetVersion: fullTargetVersion,
        asset: asset,
        releaseTag: tag,
        reason: followUp?.reason ??
            (blockingSchemaVersion != null
                ? strings.planNewSchemaNeedsFullDb(
                    latestVersion,
                    blockingSchemaVersion,
                  )
                : blockingPatchFormatVersion != null
                    ? strings.planPatchFormatTooNew(
                        blockingPatchFormatVersion,
                        latestVersion,
                      )
                    : reason),
        followUpDelta: followUp,
      );
    }
    return LibraryUpdatePlan.blocked(
      localVersion: localVersion,
      targetVersion: latestVersion,
      reason: strings.planNoFullDbEither(reason),
      blockReason: _blockReasonFor(
        blockingSchemaVersion,
        blockingPatchFormatVersion,
      ),
    );
  }

  LibraryUpdateBlockReason _blockReasonFor(
    int? blockingSchemaVersion,
    int? blockingPatchFormatVersion,
  ) =>
      blockingSchemaVersion != null || blockingPatchFormatVersion != null
          ? LibraryUpdateBlockReason.appUpdateRequired
          : LibraryUpdateBlockReason.other;

  /// המסלול אל הגרסה הגבוהה ביותר שאפשר להגיע אליה מ-[from], עד [to] כולל.
  /// מנסה מלמעלה למטה ועוצר בהצלחה הראשונה, ולכן מחזיר תמיד את הגבוהה ביותר.
  /// `null` כשאין אף מסלול קדימה.
  ///
  /// כל יעד נגיש הוא קצה של קשת קדימה. מנסים רק קצוות כאלה, כדי שפערים
  /// במספרי הגרסאות לא יוסיפו ריצות Dijkstra שאין להן סיכוי להצליח.
  List<PatchEdge>? _bestReachablePath(
    List<PatchEdge> edges,
    int from,
    int to,
  ) {
    final targets = {
      for (final edge in edges)
        if (edge.toVersion > edge.fromVersion &&
            edge.toVersion > from &&
            edge.toVersion <= to)
          edge.toVersion,
    }.toList()..sort((a, b) => b.compareTo(a));
    for (final target in targets) {
      final path = _findBestPath(edges, from, target);
      if (path != null && path.isNotEmpty) return path;
    }
    return null;
  }

  /// מוצא מסלול ממזער (מספר patches, ואז גודל דחוס כולל) מ-[from] ל-[to].
  /// מחזיר null אם אין מסלול. Dijkstra על גרף ה-edges (DAG עולה).
  List<PatchEdge>? _findBestPath(
    List<PatchEdge> edges,
    int from,
    int to,
  ) {
    final adjacency = <int, List<PatchEdge>>{};
    for (final edge in edges) {
      if (edge.toVersion <= edge.fromVersion) continue; // רק קדימה
      adjacency.putIfAbsent(edge.fromVersion, () => []).add(edge);
    }

    final best = <int, _Reach>{from: const _Reach(0, 0, [])};
    final visited = <int>{};

    while (true) {
      int? current;
      _Reach? currentReach;
      for (final entry in best.entries) {
        if (visited.contains(entry.key)) continue;
        if (currentReach == null || entry.value.isBetterThan(currentReach)) {
          current = entry.key;
          currentReach = entry.value;
        }
      }
      if (current == null || currentReach == null) break;
      if (current == to) return currentReach.path;
      visited.add(current);

      for (final edge in adjacency[current] ?? const <PatchEdge>[]) {
        final next = edge.toVersion;
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
