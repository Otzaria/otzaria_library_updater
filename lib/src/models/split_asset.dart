import 'package:equatable/equatable.dart';

/// מגבלת GitHub לנכס בודד; כל חלק חייב להיות קטן ממנה.
const int kGithubAssetLimit = 2147483648;

/// סיומת מניפסט הפיצול: `<archive>.manifest.json` לצד `<archive>.part-NNN`.
const String kSplitManifestSuffix = '.manifest.json';

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// חלק אחד של נכס מפוצל, עם כתובת ההורדה שלו ב-release.
class SplitAssetPart extends Equatable {
  final String name;
  final int size;
  final String sha256;
  final String downloadUrl;

  const SplitAssetPart({
    required this.name,
    required this.size,
    required this.sha256,
    required this.downloadUrl,
  });

  @override
  List<Object?> get props => [name, size, sha256, downloadUrl];
}

/// נכס שפוצל לחלקים מתחת למגבלת GitHub, בצורת `split_release_asset.sh`
/// (schemaVersion 1) שמשותפת ל-SeforimLibrary ול-otzaria.
class SplitAsset extends Equatable {
  /// שם הקובץ השלם אחרי חיבור החלקים.
  final String archive;
  final int size;
  final String sha256;

  /// שם נכס המניפסט ב-release.
  final String manifestName;
  final List<SplitAssetPart> parts;

  const SplitAsset({
    required this.archive,
    required this.size,
    required this.sha256,
    required this.manifestName,
    required this.parts,
  });

  /// מפענח ומאמת מניפסט מול [partUrls]/[partSizes] של ה-release; זורק
  /// [FormatException] על מניפסט פגום או על חלק חסר.
  factory SplitAsset.fromManifestJson(
    Object? json, {
    required String manifestName,
    required Map<String, String> partUrls,
    Map<String, int> partSizes = const {},
  }) {
    Never fail(String message) =>
        throw FormatException('$manifestName: $message');

    if (json is! Map) fail('אינו אובייקט JSON');
    if (json['schemaVersion'] != 1) {
      fail('schemaVersion ${json['schemaVersion']} אינו נתמך');
    }
    final archive = json['archive'];
    if (archive is! String || !_isBareName(archive)) fail('שם ארכיון לא בטוח');
    if (manifestName != '$archive$kSplitManifestSuffix') {
      fail('שם המניפסט אינו תואם לארכיון $archive');
    }
    final size = json['size'];
    final sha = json['sha256'];
    if (size is! int || size <= 0) fail('גודל ארכיון לא תקין');
    if (sha is! String || !_sha256Pattern.hasMatch(sha)) {
      fail('sha256 ארכיון לא תקין');
    }
    final rawParts = json['parts'];
    if (rawParts is! List || rawParts.isEmpty) fail('אין חלקים');

    final parts = <SplitAssetPart>[];
    final seen = <String>{};
    var total = 0;
    for (final raw in rawParts) {
      if (raw is! Map) fail('חלק אינו אובייקט');
      final name = raw['name'];
      final partSize = raw['size'];
      final partSha = raw['sha256'];
      if (name is! String || !_isBareName(name) || !seen.add(name)) {
        fail('שם חלק לא בטוח או כפול');
      }
      if (partSize is! int || partSize <= 0 || partSize >= kGithubAssetLimit) {
        fail('גודל החלק $name לא תקין');
      }
      if (partSha is! String || !_sha256Pattern.hasMatch(partSha)) {
        fail('sha256 של החלק $name לא תקין');
      }
      final url = partUrls[name];
      if (url == null || url.isEmpty) fail('החלק $name חסר ב-release');
      final published = partSizes[name];
      if (published != null && published > 0 && published != partSize) {
        fail('החלק $name שוקל $published בייטים ב-release ולא $partSize');
      }
      total += partSize;
      parts.add(SplitAssetPart(
        name: name,
        size: partSize,
        sha256: partSha,
        downloadUrl: url,
      ));
    }
    if (total != size) fail('סכום החלקים $total שונה מגודל הארכיון $size');

    return SplitAsset(
      archive: archive,
      size: size,
      sha256: sha,
      manifestName: manifestName,
      parts: List.unmodifiable(parts),
    );
  }

  static bool _isBareName(String name) =>
      name.isNotEmpty &&
      !name.contains('/') &&
      !name.contains(r'\') &&
      name != '.' &&
      name != '..';

  @override
  List<Object?> get props => [archive, size, sha256, manifestName, parts];
}
