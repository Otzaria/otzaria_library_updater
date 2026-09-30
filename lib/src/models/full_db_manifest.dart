import 'package:equatable/equatable.dart';

/// גרסת פורמט ה-manifest של DB מלא שהחבילה יודעת לקרוא.
const int kSupportedFullDbManifestVersion = 1;

/// פרטי מכל ה-zdb של DB מלא, כפי שהממיר רשם אותם בכותרת הקובץ.
class FullDbZdbInfo extends Equatable {
  final int formatMajor;
  final int formatMinor;

  /// מזהה הקובץ (32 תווי hex).
  final String fileUuid;

  /// xxh64 של התוכן הלוגי (16 תווי hex).
  final String contentXxh64;

  /// גודל ה-DB אחרי פריסה — הבסיס למדי התקדמות, לא הגודל הפיזי.
  final int logicalSize;
  final int pageSize;
  final String dictName;
  final int dictId;
  final int level;

  const FullDbZdbInfo({
    required this.formatMajor,
    required this.formatMinor,
    required this.fileUuid,
    required this.contentXxh64,
    required this.logicalSize,
    required this.pageSize,
    required this.dictName,
    required this.dictId,
    required this.level,
  });

  factory FullDbZdbInfo.fromJson(Map<String, dynamic> json) => FullDbZdbInfo(
        formatMajor:
            _requireInt(json, 'zdb.formatMajor', 'formatMajor', min: 0),
        formatMinor:
            _requireInt(json, 'zdb.formatMinor', 'formatMinor', min: 0),
        fileUuid: _requireHex(json, 'zdb.fileUuid', 'fileUuid', 32),
        contentXxh64: _requireHex(json, 'zdb.contentXxh64', 'contentXxh64', 16),
        logicalSize:
            _requireInt(json, 'zdb.logicalSize', 'logicalSize', min: 1),
        pageSize: _requireInt(json, 'zdb.pageSize', 'pageSize', min: 1),
        dictName: _requireString(json, 'zdb.dictName', 'dictName'),
        dictId: _requireInt(json, 'zdb.dictId', 'dictId', min: 0),
        level: _requireInt(json, 'zdb.level', 'level'),
      );

  @override
  List<Object?> get props => [
        formatMajor,
        formatMinor,
        fileUuid,
        contentXxh64,
        logicalSize,
        pageSize,
        dictName,
        dictId,
        level,
      ];
}

/// מקור ההמרה של ה-zdb (מאגר ו-commit של הממיר).
class FullDbConverterInfo extends Equatable {
  final String repository;
  final String commit;

  const FullDbConverterInfo({required this.repository, required this.commit});

  factory FullDbConverterInfo.fromJson(Map<String, dynamic> json) =>
      FullDbConverterInfo(
        repository: _requireString(json, 'converter.repository', 'repository'),
        commit: _requireString(json, 'converter.commit', 'commit'),
      );

  @override
  List<Object?> get props => [repository, commit];
}

/// manifest של DB מלא בפורמט zdb (`seforim-schema<N>.zdb.manifest.json`).
///
/// [contentHash] הוא ה-hash הלוגי של ה-DB — אותו ערך כמו `toContentHash`
/// במניפסט patch שמגיע לאותה גרסה. אימות ה-zdb עצמו נעשה באפליקציה.
class FullDbManifest extends Equatable {
  final int manifestVersion;

  /// שם ה-asset של ה-zdb.
  final String file;

  /// גודל הקובץ הפיזי בבייטים.
  final int size;

  /// sha256 של הקובץ הפיזי (64 תווי hex, באותיות קטנות).
  final String sha256;
  final FullDbZdbInfo zdb;
  final int dbVersion;
  final int dbSchemaVersion;
  final String contentHash;
  final FullDbConverterInfo converter;

  const FullDbManifest({
    required this.manifestVersion,
    required this.file,
    required this.size,
    required this.sha256,
    required this.zdb,
    required this.dbVersion,
    required this.dbSchemaVersion,
    required this.contentHash,
    required this.converter,
  });

  /// מפענח בקפדנות: [FormatException] על גרסת manifest לא מוכרת, על שדה חסר
  /// או על ערך מסוג שגוי. שדות נוספים שאינם מוכרים מתעלמים מהם.
  factory FullDbManifest.fromJson(Map<String, dynamic> json) {
    final manifestVersion =
        _requireInt(json, 'manifestVersion', 'manifestVersion');
    if (manifestVersion != kSupportedFullDbManifestVersion) {
      throw FormatException(
        'גרסת manifest של DB מלא לא נתמכת: $manifestVersion',
      );
    }
    return FullDbManifest(
      manifestVersion: manifestVersion,
      file: _requireString(json, 'file', 'file'),
      size: _requireInt(json, 'size', 'size', min: 1),
      sha256: _requireHex(json, 'sha256', 'sha256', 64),
      zdb: FullDbZdbInfo.fromJson(_requireObject(json, 'zdb')),
      dbVersion: _requireInt(json, 'dbVersion', 'dbVersion', min: 1),
      dbSchemaVersion:
          _requireInt(json, 'dbSchemaVersion', 'dbSchemaVersion', min: 1),
      contentHash: _requireString(json, 'contentHash', 'contentHash'),
      converter:
          FullDbConverterInfo.fromJson(_requireObject(json, 'converter')),
    );
  }

  @override
  List<Object?> get props => [
        manifestVersion,
        file,
        size,
        sha256,
        zdb,
        dbVersion,
        dbSchemaVersion,
        contentHash,
        converter,
      ];
}

Never _invalid(String path) => throw FormatException(
    'שדה חובה חסר או לא תקין ב-manifest של DB מלא: $path');

Map<String, dynamic> _requireObject(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! Map<String, dynamic>) _invalid(key);
  return value;
}

String _requireString(Map<String, dynamic> json, String path, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) _invalid(path);
  return value;
}

int _requireInt(
  Map<String, dynamic> json,
  String path,
  String key, {
  int? min,
}) {
  final value = json[key];
  if (value is! int || (min != null && value < min)) _invalid(path);
  return value;
}

final RegExp _hexPattern = RegExp(r'^[0-9a-fA-F]+$');

String _requireHex(
  Map<String, dynamic> json,
  String path,
  String key,
  int length,
) {
  final value = _requireString(json, path, key);
  if (value.length != length || !_hexPattern.hasMatch(value)) _invalid(path);
  return value.toLowerCase();
}
