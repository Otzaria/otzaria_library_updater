import 'package:equatable/equatable.dart';

import 'patch_table_spec.dart';
import 'split_asset.dart';

/// שם ה-asset של ה-DB המלא לסכמה נתונה. `seforim.db.zst` שמור לסכמה 5 ומטה
/// לתמיד — לקוחות ישנים מתאימים לשם המדויק ואסור שיקבלו סכמה חדשה מהם.
String fullDbArchiveNameForSchema(int schemaVersion) => schemaVersion <= 5
    ? _legacyFullDbArchiveName
    : 'seforim-schema$schemaVersion.db.zst';

const String _legacyFullDbArchiveName = 'seforim.db.zst';
const int _legacyFullDbSchemaCeiling = 5;
final RegExp _schemaFullDbPattern = RegExp(r'^seforim-schema(\d+)\.db\.zst$');

/// קובץ מצורף בודד ב-release של GitHub.
class ReleaseAsset extends Equatable {
  final String name;
  final String downloadUrl;
  final int size;

  /// מזהה הנכס אצל GitHub — יציב לאורך חיי הנכס ומשתנה בהעלאה מחדש.
  final int? id;

  /// חותמת עדכון הנכס (`updated_at`) — משתנה בהעלאה מחדש תחת אותו tag.
  final String? updatedAt;

  /// digest של התוכן (`sha256:<hex>`) כשה-API מספק; null כשחסר.
  final String? digest;

  /// החלקים כשהנכס מפוצל. אז [name] הוא שם הארכיון השלם, [size] ו-[digest]
  /// שלו, ו-[downloadUrl] היא כתובת מניפסט הפיצול.
  final SplitAsset? split;

  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    this.id,
    this.updatedAt,
    this.digest,
    this.split,
  });

  /// הנכס המפוצל ש-[manifestAsset] מתאר, אחרי פענוח המניפסט שלו.
  factory ReleaseAsset.fromSplit(ReleaseAsset manifestAsset, SplitAsset split) {
    return ReleaseAsset(
      name: split.archive,
      downloadUrl: manifestAsset.downloadUrl,
      size: split.size,
      id: manifestAsset.id,
      updatedAt: manifestAsset.updatedAt,
      digest: 'sha256:${split.sha256}',
      split: split,
    );
  }

  factory ReleaseAsset.fromJson(Map<String, dynamic> json) {
    return ReleaseAsset(
      name: (json['name'] as String?) ?? '',
      downloadUrl: (json['browser_download_url'] as String?) ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      id: (json['id'] as num?)?.toInt(),
      updatedAt: json['updated_at'] as String?,
      digest: json['digest'] as String?,
    );
  }

  /// שם ה-DB המלא בסכמה 5 ומטה.
  static const String fullDbArchiveName = _legacyFullDbArchiveName;

  /// פורמט המראה המקומית: מפתחות פשוטים ו-[downloadUrl] יחסי לתיקייה.
  Map<String, dynamic> toMirrorJson() => {
        'name': name,
        'downloadUrl': downloadUrl,
        'size': size,
        if (id != null) 'id': id,
        if (updatedAt != null) 'updatedAt': updatedAt,
        if (digest != null) 'digest': digest,
      };

  factory ReleaseAsset.fromMirrorJson(Map<String, dynamic> json) {
    return ReleaseAsset(
      name: (json['name'] as String?) ?? '',
      downloadUrl: (json['downloadUrl'] as String?) ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      id: (json['id'] as num?)?.toInt(),
      updatedAt: json['updatedAt'] as String?,
      digest: json['digest'] as String?,
    );
  }

  /// `true` אם זהו manifest של patch דלתאי
  /// (`patch-vX-vY.db.zst.manifest.json`).
  bool get isDeltaManifest =>
      name.startsWith('patch-') && name.endsWith('.db.zst.manifest.json');

  /// `true` אם זהו DB מלא דחוס: `seforim.db.zst` או `seforim-schema<N>.db.zst`.
  bool get isFullDbArchive => _isFullDbName(name);

  /// `true` אם זהו מניפסט פיצול של DB מלא (`<שם DB מלא>.manifest.json`),
  /// שעוד לא פוענח ל-[split].
  bool get isSplitFullDbManifest {
    final archive = splitArchiveName;
    return archive != null && _isFullDbName(archive);
  }

  /// סכמת ה-DB המלא לפי שם ה-asset: N עבור `seforim-schema<N>.db.zst`
  /// (N ≥ 6, בכתיב קנוני), null עבור `seforim.db.zst` (סכמה ≤ 5) ולכל שם אחר.
  int? get fullDbSchemaVersion => _schemaOfFullDbName(name);

  /// כמו [fullDbSchemaVersion], אבל גם למניפסט פיצול — לפי שם הארכיון שלו.
  int? get advertisedFullDbSchemaVersion =>
      _schemaOfFullDbName(splitArchiveName ?? name);

  /// שם הארכיון שמניפסט פיצול מתאר, או null כשאין זה מניפסט פיצול.
  String? get splitArchiveName => name.endsWith(kSplitManifestSuffix)
      ? name.substring(0, name.length - kSplitManifestSuffix.length)
      : null;

  /// האם [name] הוא שם של DB מלא דחוס (`seforim.db.zst` או
  /// `seforim-schema<N>.db.zst`).
  static bool isFullDbName(String name) => _isFullDbName(name);

  /// סכמת ה-DB המלא לפי השם: `seforim.db.zst` נחשב 5; שם אחר ⇒ null.
  static int? fullDbSchemaOfName(String name) =>
      name == _legacyFullDbArchiveName
          ? _legacyFullDbSchemaCeiling
          : _schemaOfFullDbName(name);

  static bool _isFullDbName(String name) =>
      name == _legacyFullDbArchiveName || _schemaOfFullDbName(name) != null;

  static int? _schemaOfFullDbName(String name) {
    final match = _schemaFullDbPattern.firstMatch(name);
    if (match == null) return null;
    final schema = int.tryParse(match.group(1)!);
    if (schema == null || schema <= _legacyFullDbSchemaCeiling) return null;
    return fullDbArchiveNameForSchema(schema) == name ? schema : null;
  }

  @override
  List<Object?> get props =>
      [name, downloadUrl, size, id, updatedAt, digest, split];
}

/// מייצג release אחד מ-GitHub עם כל ה-assets שלו.
class LibraryRelease extends Equatable {
  final String tag;
  final bool isPrerelease;
  final bool isDraft;
  final DateTime? publishedAt;
  final List<ReleaseAsset> assets;

  const LibraryRelease({
    required this.tag,
    required this.isPrerelease,
    required this.isDraft,
    required this.publishedAt,
    required this.assets,
  });

  /// ה-`state` של נכס שהעלאתו הושלמה. GitHub מפרסם נכסים ברשימה עוד לפני
  /// שעלו (`starting`/`uploading`, בדרך כלל בגודל 0), ונכס כזה מסונן.
  static const String uploadedAssetState = 'uploaded';

  factory LibraryRelease.fromJson(Map<String, dynamic> json) {
    final assetsRaw = json['assets'];
    return LibraryRelease(
      tag: (json['tag_name'] as String?) ?? '',
      isPrerelease: (json['prerelease'] as bool?) ?? false,
      isDraft: (json['draft'] as bool?) ?? false,
      publishedAt: DateTime.tryParse((json['published_at'] as String?) ?? ''),
      assets: assetsRaw is List
          ? assetsRaw
              .whereType<Map<String, dynamic>>()
              .where(_isUploaded)
              .map(ReleaseAsset.fromJson)
              .toList(growable: false)
          : const [],
    );
  }

  // שדה חסר = API ישן או מראה מקומית; לא פוסלים על היעדרו.
  static bool _isUploaded(Map<String, dynamic> e) {
    final state = e['state'];
    return state == null || state == uploadedAssetState;
  }

  /// פורמט המראה המקומית — ראו [ReleaseAsset.toMirrorJson].
  Map<String, dynamic> toMirrorJson() => {
        'tag': tag,
        'isPrerelease': isPrerelease,
        'isDraft': isDraft,
        if (publishedAt != null) 'publishedAt': publishedAt!.toIso8601String(),
        'assets': assets.map((a) => a.toMirrorJson()).toList(),
      };

  factory LibraryRelease.fromMirrorJson(Map<String, dynamic> json) {
    final assetsRaw = json['assets'];
    return LibraryRelease(
      tag: (json['tag'] as String?) ?? '',
      isPrerelease: (json['isPrerelease'] as bool?) ?? false,
      isDraft: (json['isDraft'] as bool?) ?? false,
      publishedAt: DateTime.tryParse((json['publishedAt'] as String?) ?? ''),
      assets: assetsRaw is List
          ? assetsRaw
              .whereType<Map<String, dynamic>>()
              .map(ReleaseAsset.fromMirrorJson)
              .toList(growable: false)
          : const [],
    );
  }

  /// ה-manifests של patches דלתאיים ב-release זה.
  List<ReleaseAsset> get deltaManifestAssets =>
      assets.where((a) => a.isDeltaManifest).toList(growable: false);

  /// ה-DB המלא הדחוס בסכמה [kDefaultConsumerDbSchemaVersion] ומטה, אם קיים.
  ReleaseAsset? get fullDbAsset =>
      fullDbAssetFor(maxSchemaVersion: kDefaultConsumerDbSchemaVersion);

  /// ה-DB המלא בעל הסכמה הגבוהה ביותר שאינה עולה על [maxSchemaVersion].
  /// `seforim.db.zst` נחשב סכמה 5. DB מפוצל מוחזר כמניפסט שלו (לפענוח ב-
  /// `resolveSplitAsset`); קובץ יחיד גובר בתיקו.
  ReleaseAsset? fullDbAssetFor({required int maxSchemaVersion}) {
    ReleaseAsset? best;
    var bestRank = -1;
    for (final asset in assets) {
      final single = asset.isFullDbArchive;
      if (!single && !asset.isSplitFullDbManifest) continue;
      if (asset.size <= 0) continue;
      final schema =
          asset.advertisedFullDbSchemaVersion ?? _legacyFullDbSchemaCeiling;
      if (schema > maxSchemaVersion) continue;
      final rank = schema * 2 + (single ? 1 : 0);
      if (rank <= bestRank) continue;
      best = asset;
      bestRank = rank;
    }
    return best;
  }

  /// הסכמה הגבוהה של DB מלא שה-release מפרסם מעל [maxSchemaVersion], כשאין
  /// לו DB מלא שאפשר לקרוא; אחרת null.
  int? unsupportedFullDbSchemaFor({required int maxSchemaVersion}) {
    if (fullDbAssetFor(maxSchemaVersion: maxSchemaVersion) != null) return null;
    int? highest;
    for (final asset in assets) {
      if (!asset.isFullDbArchive && !asset.isSplitFullDbManifest) continue;
      final schema =
          asset.advertisedFullDbSchemaVersion ?? _legacyFullDbSchemaCeiling;
      if (schema <= maxSchemaVersion) continue;
      if (highest == null || schema > highest) highest = schema;
    }
    return highest;
  }

  /// [unsupportedFullDbSchemaFor] מול [kSupportedDbSchemaVersion].
  int? get unsupportedFullDbSchema =>
      unsupportedFullDbSchemaFor(maxSchemaVersion: kSupportedDbSchemaVersion);

  /// כתובות החלקים וגדליהם ב-release זה, לפענוח מניפסט פיצול.
  ({Map<String, String> urls, Map<String, int> sizes}) get assetIndex => (
        urls: {for (final a in assets) a.name: a.downloadUrl},
        sizes: {for (final a in assets) a.name: a.size},
      );

  /// מאתר asset לפי שם מדויק.
  ReleaseAsset? assetByName(String name) {
    for (final asset in assets) {
      if (asset.name == name) return asset;
    }
    return null;
  }

  @override
  List<Object?> get props => [tag, isPrerelease, isDraft, publishedAt, assets];
}
