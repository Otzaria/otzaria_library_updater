import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../messages/library_updater_messages.dart';
import '../models/delta_manifest.dart';
import '../models/library_release.dart';
import 'library_release_source.dart';

/// נזרק כשתיקיית המראה המקומית חסרה או פגומה.
class LocalMirrorException implements Exception {
  final String message;
  const LocalMirrorException(this.message);
  @override
  String toString() => message;
}

/// [LibraryReleaseSource] שקורא מתיקייה מקומית (USB / תיקייה משותפת) שנבנתה
/// מראש על-ידי [LibraryMirrorExporter] — למחשבים בלי אינטרנט.
///
/// כל `downloadUrl` ב-`releases.json` יחסי לתיקיית המראה, ומומר כאן לנתיב
/// מוחלט ש-[PatchDownloader] מקבל כמו שהוא.
class LocalMirrorLibraryReleaseClient implements LibraryReleaseSource {
  LocalMirrorLibraryReleaseClient({required this.mirrorDir});

  final String mirrorDir;

  static const String manifestFileName = 'releases.json';

  String get _releasesJsonPath =>
      '$mirrorDir${Platform.pathSeparator}$manifestFileName';

  @override
  Future<List<LibraryRelease>> fetchReleases() async {
    final messages = LibraryUpdaterMessages.current;
    final file = File(_releasesJsonPath);
    if (!await file.exists()) {
      throw LocalMirrorException(
        messages.mirrorManifestMissing(manifestFileName, mirrorDir),
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } catch (error) {
      throw LocalMirrorException(
        messages.mirrorManifestCorrupt(manifestFileName, mirrorDir, '$error'),
      );
    }
    if (decoded is! Map<String, dynamic> || decoded['releases'] is! List) {
      throw LocalMirrorException(
        messages.mirrorManifestUnexpectedShape(manifestFileName, mirrorDir),
      );
    }

    return (decoded['releases'] as List)
        .whereType<Map<String, dynamic>>()
        .map(LibraryRelease.fromMirrorJson)
        .map(_resolveReleaseAssetPaths)
        .toList(growable: false);
  }

  LibraryRelease _resolveReleaseAssetPaths(LibraryRelease release) {
    return LibraryRelease(
      tag: release.tag,
      isPrerelease: release.isPrerelease,
      isDraft: release.isDraft,
      publishedAt: release.publishedAt,
      assets: release.assets
          .map((a) => ReleaseAsset(
                name: a.name,
                downloadUrl: _absolutePath(a.downloadUrl),
                size: a.size,
                id: a.id,
                updatedAt: a.updatedAt,
                digest: a.digest,
              ))
          .toList(growable: false),
    );
  }

  // כונן שמולא ב-Windows עשוי לשאת `\`; מפצלים לפי שניהם כדי שיעבוד גם ב-macOS.
  String _absolutePath(String relative) {
    final segments = relative.split(RegExp(r'[\\/]'))
      ..removeWhere((s) => s.isEmpty || s == '.');
    if (p.windows.isAbsolute(relative) || segments.contains('..')) {
      throw LocalMirrorException(
        LibraryUpdaterMessages.current
            .mirrorManifestUnexpectedShape(manifestFileName, mirrorDir),
      );
    }
    return p.joinAll([mirrorDir, ...segments]);
  }

  /// [url] כאן כבר נתיב מוחלט (ראו [_resolveReleaseAssetPaths]).
  @override
  Future<DeltaManifest> fetchManifest(String url) async {
    final messages = LibraryUpdaterMessages.current;
    final file = File(url);
    if (!await file.exists()) {
      throw LocalMirrorException(messages.mirrorPatchManifestMissing(url));
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } catch (error) {
      throw LocalMirrorException(
        messages.mirrorPatchManifestCorrupt(url, '$error'),
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw LocalMirrorException(messages.mirrorPatchManifestNotJson(url));
    }
    return DeltaManifest.fromJson(decoded);
  }

  @override
  void dispose() {}
}
