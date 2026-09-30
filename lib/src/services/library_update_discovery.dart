import '../models/full_db_manifest.dart';
import '../models/library_release.dart';
import '../models/library_update_plan.dart';
import '../models/patch_table_spec.dart';
import 'github_library_release_client.dart';

/// תוצאת סריקת ה-releases: הגרסה האחרונה, ה-edges הזמינים, וה-DB המלא
/// ל-fallback.
class LibraryDiscoveryResult {
  final int latestVersion;
  final List<PatchEdge> edges;
  final ReleaseAsset? latestFullDbAsset;
  final String? latestReleaseTag;

  /// Schema of [latestFullDbAsset], or the highest advertised full-DB schema for
  /// [latestVersion] when no compatible asset exists. Null when the latest
  /// release has no recognizable full DB; legacy archives are treated as 5.
  final int? latestDbSchemaVersion;

  /// ה-manifest של [latestFullDbAsset] כשהוא zdb, מאומת מול ה-asset ומול
  /// [latestVersion]. null עבור `seforim.db.zst` או כשאין DB מלא.
  final FullDbManifest? latestFullDbManifest;

  const LibraryDiscoveryResult({
    required this.latestVersion,
    required this.edges,
    required this.latestFullDbAsset,
    required this.latestReleaseTag,
    this.latestDbSchemaVersion,
    this.latestFullDbManifest,
  });
}

/// DB מלא בפורמט zdb נבחר, אך ה-manifest שלו חסר, לא נקרא או לא תואם.
/// zdb ללא manifest תקין אינו ניתן לאימות ולכן אסור להציעו.
class FullDbManifestException implements Exception {
  final String message;
  final Object? cause;

  const FullDbManifestException(this.message, [this.cause]);

  @override
  String toString() => cause == null
      ? 'FullDbManifestException: $message'
      : 'FullDbManifestException: $message ($cause)';
}

/// סורק את ה-releases של GitHub, בונה את גרף ה-patches ומזהה את הגרסה
/// האחרונה. ה-edges וה-DB המלא מוזנים אחר כך ל-[LibraryUpdatePlanner].
class LibraryUpdateDiscovery {
  final GithubLibraryReleaseClient client;

  /// הסכמה הגבוהה ביותר של DB מלא שמותר לבחור כ-fallback; ראו
  /// [kDefaultConsumerDbSchemaVersion].
  final int supportedDbSchemaVersion;

  const LibraryUpdateDiscovery({
    required this.client,
    this.supportedDbSchemaVersion = kDefaultConsumerDbSchemaVersion,
  });

  static final RegExp _manifestVersionPattern =
      RegExp(r'^patch-v(\d+)-v(\d+)\.db\.zst\.manifest\.json$');

  /// מסנן releases לפי הערוץ: תמיד מתעלם מ-draft; prerelease מותר רק כש-
  /// [allowPrerelease] פעיל.
  static List<LibraryRelease> eligibleReleases(
    List<LibraryRelease> releases, {
    required bool allowPrerelease,
  }) {
    return releases
        .where((r) => !r.isDraft && (allowPrerelease || !r.isPrerelease))
        .toList(growable: false);
  }

  /// מחלץ מספר גרסה מ-tag כמו `v3` או `3`. מחזיר null אם אין מספר.
  static int? parseVersionFromTag(String tag) {
    final match = RegExp(r'(\d+)').firstMatch(tag);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// סורק את כל ה-releases ומחזיר את ה-edges, הגרסה האחרונה וה-DB המלא.
  ///
  /// זורק [FullDbManifestException] כשה-DB המלא שנבחר הוא zdb וה-manifest
  /// שלו חסר, לא ירד או סותר את ה-asset.
  Future<LibraryDiscoveryResult> discover({
    required bool allowPrerelease,
  }) async {
    final releases = eligibleReleases(
      await client.fetchReleases(),
      allowPrerelease: allowPrerelease,
    );

    final edges = <PatchEdge>[];
    for (final release in releases) {
      for (final manifestAsset in release.deltaManifestAssets) {
        final edge = await _buildEdge(release, manifestAsset);
        if (edge != null) edges.add(edge);
      }
    }

    var maxEdgeVersion = 0;
    for (final edge in edges) {
      if (edge.toVersion > maxEdgeVersion) maxEdgeVersion = edge.toVersion;
    }

    // ה-DB המלא ל-fallback: מה-release בעל הגרסה הגבוהה ביותר שיש לו DB מלא
    // בסכמה נתמכת. סכמות חדשות מדי מזוהות כ-latest אך אינן fallback.
    ReleaseAsset? latestFull;
    LibraryRelease? latestFullRelease;
    String? latestTag;
    var bestFullVersion = -1;
    var latestVersion = maxEdgeVersion;
    int? latestDbSchemaVersion;
    for (final release in releases) {
      final advertisedFulls = release.assets.where((a) => a.isFullDbArchive);
      final hasVersionedManifest = release.deltaManifestAssets
          .any((a) => _manifestVersionPattern.hasMatch(a.name));
      if (advertisedFulls.isEmpty && !hasVersionedManifest) {
        continue;
      }
      final version = _releaseVersion(release);
      // Release visibility must not depend on consumer capabilities or on a
      // successful manifest download. Unsupported releases still require action.
      if (version > latestVersion) {
        latestVersion = version;
        latestDbSchemaVersion = null;
      }
      if (version == latestVersion) {
        for (final asset in advertisedFulls) {
          final schema = asset.fullDbSchemaVersion ?? 5;
          if (latestDbSchemaVersion == null || schema > latestDbSchemaVersion) {
            latestDbSchemaVersion = schema;
          }
        }
      }
      final full =
          release.fullDbAssetFor(maxSchemaVersion: supportedDbSchemaVersion);
      if (full == null) continue;
      if (version > bestFullVersion) {
        bestFullVersion = version;
        latestFull = full;
        latestFullRelease = release;
        latestTag = release.tag;
      }
    }

    // DB מלא ישן יותר אינו fallback חוקי ל-latest: הצרכן מאמת את הגרסה
    // שחולצה מול plan.targetVersion, ולכן צירוף asset ישן היה גורם להורדה
    // גדולה שמובטח שתיכשל באימות. במקרה כזה משאירים את ה-fallback חסר.
    final fullMatchesLatest =
        latestFull != null && bestFullVersion == latestVersion;
    final fullManifest =
        fullMatchesLatest && latestFull.fullDbContainer == FullDbContainer.zdb
            ? await _fetchFullDbManifest(
                latestFullRelease!, latestFull, latestVersion)
            : null;

    return LibraryDiscoveryResult(
      latestVersion: latestVersion,
      edges: edges,
      latestFullDbAsset: fullMatchesLatest ? latestFull : null,
      latestReleaseTag: fullMatchesLatest ? latestTag : null,
      latestDbSchemaVersion: fullMatchesLatest
          ? latestFull.fullDbSchemaVersion ?? 5
          : latestDbSchemaVersion,
      latestFullDbManifest: fullManifest,
    );
  }

  Future<FullDbManifest> _fetchFullDbManifest(
    LibraryRelease release,
    ReleaseAsset asset,
    int expectedVersion,
  ) async {
    final manifestAsset = release.fullDbManifestAsset(asset);
    if (manifestAsset == null) {
      throw FullDbManifestException(
        'ל-${asset.name} ב-${release.tag} אין '
        '${fullDbManifestNameFor(asset.name)}',
      );
    }
    final FullDbManifest manifest;
    try {
      manifest = await client.fetchFullDbManifest(manifestAsset.downloadUrl);
    } catch (e) {
      throw FullDbManifestException(
        'קריאת ${manifestAsset.name} ב-${release.tag} נכשלה',
        e,
      );
    }
    final mismatches = [
      if (manifest.file != asset.name) 'file=${manifest.file}',
      if (manifest.size != asset.size) 'size=${manifest.size}',
      if (manifest.dbVersion != expectedVersion)
        'dbVersion=${manifest.dbVersion}',
      if (manifest.dbSchemaVersion != asset.fullDbSchemaVersion)
        'dbSchemaVersion=${manifest.dbSchemaVersion}',
    ];
    if (mismatches.isNotEmpty) {
      throw FullDbManifestException(
        '${manifestAsset.name} ב-${release.tag} אינו תואם ל-${asset.name}: '
        '${mismatches.join(', ')}',
      );
    }
    return manifest;
  }

  /// בונה [PatchEdge] מ-manifest asset. מחזיר null אם ה-manifest פגום או אם
  /// קובץ patch הנדרש חסר ב-release — מתעלמים מ-edge כזה בלי להכשיל הכל.
  Future<PatchEdge?> _buildEdge(
    LibraryRelease release,
    ReleaseAsset manifestAsset,
  ) async {
    try {
      final manifest = await client.fetchManifest(manifestAsset.downloadUrl);
      final urls = <String, String>{};
      for (final patchFile in manifest.patchFiles) {
        final asset = release.assetByName(patchFile.file);
        if (asset == null) return null;
        urls[patchFile.file] = asset.downloadUrl;
      }
      return PatchEdge(
        manifest: manifest,
        patchFileUrls: urls,
        manifestUrl: manifestAsset.downloadUrl,
      );
    } catch (_) {
      return null;
    }
  }

  /// גרסת ה-release לפי שמות ה-manifest assets, או לפי ה-tag כ-fallback.
  int _releaseVersion(LibraryRelease release) {
    var version = 0;
    for (final asset in release.deltaManifestAssets) {
      final match = _manifestVersionPattern.firstMatch(asset.name);
      if (match != null) {
        final to = int.parse(match.group(2)!);
        if (to > version) version = to;
      }
    }
    if (version == 0) {
      version = parseVersionFromTag(release.tag) ?? 0;
    }
    return version;
  }
}
