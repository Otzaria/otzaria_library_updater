import '../models/library_release.dart';
import '../models/library_update_plan.dart';
import '../models/patch_table_spec.dart';
import 'library_release_source.dart';
import 'library_update_discovery.dart';

/// תוצאת [OfflineLibraryUpdateDiscovery.discover].
class OfflineLibraryDiscoveryResult {
  final int latestVersion;

  /// רק קשתות שאפשר להחיל ([PatchEdge.isApplicable]).
  final List<PatchEdge> edges;

  /// ה-DB המלא הגבוה ביותר — **גם** כשהוא ישן מ-[latestVersion].
  final ReleaseAsset? latestFullDbAsset;

  /// ה-tag של ה-release ש-[latestFullDbAsset] יורד ממנו.
  final String? fullDbReleaseTag;

  /// ה-tag של ה-release החדש ביותר שתרם ל-[latestVersion] — מקור התוכן העדכני.
  final String? latestContentTag;

  /// הגרסה ש-[latestFullDbAsset] באמת מביא; אינה בהכרח [latestVersion].
  final int? latestFullDbVersion;

  /// סכמות שנראו ואין להן סדר hash — הקשתות שלהן סוננו מ-[edges].
  final Set<int> unsupportedSchemaVersions;

  /// פורמטי `patch.db` שנראו ואיננו יודעים להחיל.
  final Set<int> unsupportedPatchFormatVersions;

  final List<String> unreadableManifests;

  final String? newestReleaseTag;

  int? get blockingSchemaVersion => _highest(unsupportedSchemaVersions);

  int? get blockingPatchFormatVersion =>
      _highest(unsupportedPatchFormatVersions);

  static int? _highest(Set<int> versions) =>
      versions.isEmpty ? null : versions.reduce((a, b) => a > b ? a : b);

  const OfflineLibraryDiscoveryResult({
    required this.latestVersion,
    required this.edges,
    required this.latestFullDbAsset,
    required this.fullDbReleaseTag,
    required this.latestContentTag,
    this.latestFullDbVersion,
    this.unsupportedSchemaVersions = const {},
    this.unsupportedPatchFormatVersions = const {},
    this.unreadableManifests = const [],
    this.newestReleaseTag,
  });
}

/// גילוי למסלול המראה (offline): בונה את גרף ה-patches מכל [LibraryReleaseSource],
/// שומר DB מלא ישן מ-latest (להשלמה ב-patches), וסופר manifest שאינו קריא
/// ל-latest לפי שמו — כדי שגרסה חדשה לא תיראה "מעודכן".
class OfflineLibraryUpdateDiscovery {
  final LibraryReleaseSource client;

  /// הסכמה הגבוהה ביותר של DB מלא שמותר לבחור — בלי ברירת מחדל, כי זו של
  /// המסלול המקוון ([kDefaultConsumerDbSchemaVersion]) נמוכה מזו של המראה.
  final int supportedDbSchemaVersion;

  const OfflineLibraryUpdateDiscovery({
    required this.client,
    required this.supportedDbSchemaVersion,
  });

  static final RegExp _manifestVersionPattern =
      RegExp(r'^patch-v(\d+)-v(\d+)\.db\.zst\.manifest\.json$');

  static List<LibraryRelease> eligibleReleases(
    List<LibraryRelease> releases, {
    required bool allowPrerelease,
  }) =>
      LibraryUpdateDiscovery.eligibleReleases(
        releases,
        allowPrerelease: allowPrerelease,
      );

  static int? parseVersionFromTag(String tag) =>
      LibraryUpdateDiscovery.parseVersionFromTag(tag);

  static int releaseVersionOf(LibraryRelease release) =>
      LibraryUpdateDiscovery.releaseVersionOf(release);

  /// ה-release האחרון שנושא תוכן DB, לבדיקה הקלה "יש משהו חדש ברשת?".
  static ({String tag, int version})? latestOnlineRelease(
    List<LibraryRelease> releases, {
    required bool allowPrerelease,
    required int supportedDbSchemaVersion,
  }) {
    ({String tag, int version})? latest;
    for (final release
        in eligibleReleases(releases, allowPrerelease: allowPrerelease)) {
      if (release.deltaManifestAssets.isEmpty &&
          release.fullDbAssetFor(maxSchemaVersion: supportedDbSchemaVersion) ==
              null) {
        continue;
      }
      final version = releaseVersionOf(release);
      if (version > (latest?.version ?? 0)) {
        latest = (tag: release.tag, version: version);
      }
    }
    return latest;
  }

  ReleaseAsset? _fullDbOf(LibraryRelease release) =>
      release.fullDbAssetFor(maxSchemaVersion: supportedDbSchemaVersion);

  Future<OfflineLibraryDiscoveryResult> discover({
    required bool allowPrerelease,
  }) async {
    final releases = eligibleReleases(
      await client.fetchReleases(),
      allowPrerelease: allowPrerelease,
    );

    final allEdges = <PatchEdge>[];
    final edgeRelease = <PatchEdge, LibraryRelease>{};
    final unreadableManifests = <String>[];
    final contributed = <LibraryRelease, int>{};
    void contribute(LibraryRelease release, int version) {
      if (version > (contributed[release] ?? -1)) {
        contributed[release] = version;
      }
    }

    var maxManifestVersion = 0;
    for (final release in releases) {
      for (final manifestAsset in release.deltaManifestAssets) {
        final PatchEdge? edge;
        try {
          edge = await _buildEdge(release, manifestAsset);
        } catch (_) {
          unreadableManifests.add(manifestAsset.name);
          final version = _manifestToVersion(manifestAsset.name) ??
              releaseVersionOf(release);
          if (version > maxManifestVersion) maxManifestVersion = version;
          continue;
        }
        if (edge == null) continue;
        allEdges.add(edge);
        edgeRelease[edge] = release;
        contribute(release, edge.toVersion);
        if (edge.toVersion > maxManifestVersion) {
          maxManifestVersion = edge.toVersion;
        }
      }
    }

    final unsupportedSchemas = <int>{};
    final unsupportedFormats = <int>{};
    final edges = <PatchEdge>[];
    for (final edge in allEdges) {
      if (edge.isApplicable) {
        edges.add(edge);
        continue;
      }
      if (edge.manifest.fullRebase) {
        final target = edge.manifest.toSchemaVersion;
        final release = edgeRelease[edge];
        if (!isSupportedSchemaVersion(target) &&
            (release == null || _fullDbOf(release) == null)) {
          unsupportedSchemas.add(target);
        }
        continue;
      }
      for (final schema in [
        edge.manifest.fromSchemaVersion,
        edge.manifest.toSchemaVersion,
      ]) {
        if (!isSupportedSchemaVersion(schema)) unsupportedSchemas.add(schema);
      }
      final format = edge.manifest.patchFormatVersion;
      if (format != null && !isSupportedPatchFormatVersion(format)) {
        unsupportedFormats.add(format);
      }
    }

    LibraryRelease? fullRelease;
    var bestFullVersion = -1;
    for (final release in releases) {
      if (_fullDbOf(release) == null) continue;
      final version = releaseVersionOf(release);
      contribute(release, version);
      if (version > bestFullVersion ||
          (version == bestFullVersion &&
              _publishedAfter(release, fullRelease))) {
        bestFullVersion = version;
        fullRelease = release;
      }
    }
    final latestFull = fullRelease == null ? null : _fullDbOf(fullRelease);
    final latestTag = fullRelease?.tag;

    var latestVersion = maxManifestVersion > bestFullVersion
        ? maxManifestVersion
        : bestFullVersion;

    for (final release in releases) {
      final schema = release.unsupportedFullDbSchemaFor(
          maxSchemaVersion: supportedDbSchemaVersion);
      if (schema == null) continue;
      final version = releaseVersionOf(release);
      if (version < latestVersion) continue;
      latestVersion = version;
      unsupportedSchemas.add(schema);
      contribute(release, version);
    }

    return OfflineLibraryDiscoveryResult(
      latestVersion: latestVersion,
      edges: edges,
      latestFullDbAsset: latestFull,
      fullDbReleaseTag: latestTag,
      latestContentTag: _newestReleaseTag(
        releases.where((r) => contributed[r] == latestVersion),
      ),
      latestFullDbVersion: latestFull == null ? null : bestFullVersion,
      unsupportedSchemaVersions: unsupportedSchemas,
      unsupportedPatchFormatVersions: unsupportedFormats,
      unreadableManifests: unreadableManifests,
      newestReleaseTag: _newestContentRelease(releases)?.tag,
    );
  }

  LibraryRelease? _newestContentRelease(List<LibraryRelease> releases) {
    LibraryRelease? newest;
    var newestVersion = -1;
    for (final release in releases) {
      if (release.deltaManifestAssets.isEmpty && _fullDbOf(release) == null) {
        continue;
      }
      final version = releaseVersionOf(release);
      if (version > newestVersion ||
          (version == newestVersion && _publishedAfter(release, newest))) {
        newestVersion = version;
        newest = release;
      }
    }
    return newest;
  }

  static String? _newestReleaseTag(Iterable<LibraryRelease> candidates) {
    LibraryRelease? newest;
    for (final release in candidates) {
      if (_publishedAfter(release, newest)) newest = release;
    }
    return newest?.tag;
  }

  static bool _publishedAfter(LibraryRelease candidate, LibraryRelease? best) {
    if (best == null) return true;
    final bestDate = best.publishedAt;
    if (bestDate == null) return true;
    final own = candidate.publishedAt;
    return own != null && own.isAfter(bestDate);
  }

  static int? _manifestToVersion(String name) {
    final match = _manifestVersionPattern.firstMatch(name);
    return match == null ? null : int.parse(match.group(2)!);
  }

  /// קשת שאפשר להחיל וחסר לה קובץ אינה נבנית; קשת שאינה ניתנת להחלה נשמרת
  /// כדי לדווח על הסכמה או הפורמט שחסמו אותה.
  Future<PatchEdge?> _buildEdge(
    LibraryRelease release,
    ReleaseAsset manifestAsset,
  ) async {
    final manifest = await client.fetchManifest(manifestAsset.downloadUrl);
    final urls = <String, String>{};
    var missingFile = false;
    for (final patchFile in manifest.patchFiles) {
      final asset = release.assetByName(patchFile.file);
      if (asset == null) {
        missingFile = true;
      } else {
        urls[patchFile.file] = asset.downloadUrl;
      }
    }
    final edge = PatchEdge(
      manifest: manifest,
      patchFileUrls: urls,
      manifestUrl: manifestAsset.downloadUrl,
    );
    if (missingFile && edge.isApplicable) return null;
    return edge;
  }
}
